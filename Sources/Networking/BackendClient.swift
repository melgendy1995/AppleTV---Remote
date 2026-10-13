import Foundation
import SwiftUI

@MainActor
final class BackendClient: ObservableObject {
    @AppStorage("backendURL") var backendURLString: String = "http://localhost:8000"

    @Published var connected: Bool = false
    @Published var connectedDevice: DeviceInfo?
    @Published var devices: [DeviceInfo] = []
    @Published var savedDevices: [String: SavedDeviceEntry] = [:]
    @Published var playing: PlayingState = .init()
    @Published var keyboard: KeyboardEvent = .init(focused: false, focusState: "Unfocused", text: nil)
    @Published var backendReachable: Bool = true
    @Published var lastError: String?

    private var wsTask: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    /// Exponential backoff for WebSocket reconnects; reset on a healthy receive.
    private var wsReconnectDelay: TimeInterval = 1.5
    /// Last device we were connected to — used to re-establish the connection
    /// after a network drop (the backend tears its side down and reports
    /// disconnected; only the client knows to try again).
    private var lastConnectedIdentifier: String?
    /// Manual disconnect opts out of auto-connect until the user connects
    /// something again; failures back off briefly so a broken setup doesn't
    /// retry on every scan.
    private var autoConnectSuppressed = false
    private var autoConnectInFlight = false
    private var autoConnectCooldownUntil: Date?
    /// Watches `/api/status` because a manual disconnect does not broadcast
    /// a websocket `disconnected` frame (that type is only emitted when pyatv
    /// reports the link lost). Without this, `connected` stays true and the
    /// capture session keeps the device open.
    private var statusWatch: Task<Void, Never>?

    init() {
        ensureStatusWatch()
    }

    /// True when this device-row represents the Apple TV we're currently
    /// connected to. `connectedDevice` can be nil (a restored status only
    /// yields an identifier), so fall back to the last-connected identifier.
    func isConnectedDevice(_ device: DeviceInfo) -> Bool {
        connected && device.identifier == (connectedDevice?.identifier ?? lastConnectedIdentifier)
    }

    /// Connect automatically when a paired device shows up in scan results.
    /// Called after every scan; no-ops when already connected, suppressed by
    /// a manual disconnect, or cooling down after a failed attempt.
    private func autoConnectIfPossible() async {
        guard !connected, !autoConnectSuppressed, !autoConnectInFlight else { return }
        if let until = autoConnectCooldownUntil, Date() < until { return }
        let candidates = devices.filter { $0.isPaired && !$0.address.isEmpty && $0.address != "not detected yet" }
        // Prefer the device we were last connected to over whatever the
        // scan happened to list first.
        guard let device = candidates.first(where: { $0.identifier == lastConnectedIdentifier }) ?? candidates.first else { return }
        autoConnectInFlight = true
        defer { autoConnectInFlight = false }
        do {
            try await connect(to: device)
            autoConnectCooldownUntil = nil
        } catch {
            autoConnectCooldownUntil = Date().addingTimeInterval(60)
        }
    }

    var backendURL: URL? { URL(string: backendURLString) }
    var wsURL: URL? {
        guard let u = backendURL,
              var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = (c.scheme == "https") ? "wss" : "ws"
        c.path = "/ws/state"
        return c.url
    }

    // MARK: - REST helpers

    private func request<T: Decodable>(_ method: String,
                                       _ path: String,
                                       body: Encodable? = nil) async throws -> T {
        guard let url = buildURL(path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.httpBody = try JSONEncoder().encode(AnyEncodable(body))
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw BackendError.httpError(http.statusCode, detail)
        }
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    private func post(_ path: String, body: Encodable? = nil) async throws -> EmptyResponse {
        let r: EmptyResponse = try await request("POST", path, body: body)
        return r
    }

    // MARK: - Top-level operations

    func refreshStatus(scanIfDisconnected: Bool = true) async {
        do {
            let s: StatusResponse = try await request("GET", "api/status")
            backendReachable = true
            if s.connected, let ident = s.identifier {
                lastConnectedIdentifier = ident
                await assignConnectedDevice(ident)
                connected = true
                await refreshPlaying()
                openWebSocket()
            } else {
                connected = false
                connectedDevice = nil
                if scanIfDisconnected { await scan() }
            }
        } catch {
            backendReachable = false
            lastError = "Backend unreachable: \(error.localizedDescription)"
        }
    }

    func scan(timeout: Int = 12) async {
        do {
            devices = try await request("GET", "api/devices?timeout=\(timeout)")
            savedDevices = try await fetchSaved()
            mergeSavedNames()
        } catch {
            lastError = "Scan failed: \(error.localizedDescription)"
        }
        await autoConnectIfPossible()
    }

    /// Populate `devices` from saved credentials so the picker has content
    /// immediately instead of staring at an empty list until a scan finishes.
    /// The real scan result replaces this placeholder list when it lands.
    func seedDevicesFromSaved() {
        guard devices.isEmpty else { return }
        devices = dedupedSavedDevices(address: "")
    }

    /// The saved-credentials file often holds the SAME physical Apple TV
    /// under several identifier formats (UUID, MAC with/without colons) —
    /// pairing over different protocols stores different keys. The third
    /// field of each pyatv credential is the hex-encoded real device UUID,
    /// identical across every entry for the same TV, so group on it and
    /// emit one row per physical device.
    private func dedupedSavedDevices(address: String) -> [DeviceInfo] {
        var best: [String: (id: String, entry: SavedDeviceEntry)] = [:]
        for (id, entry) in savedDevices {
            let key = physicalKey(for: id, entry: entry)
            if let existing = best[key] {
                // Prefer the saved key equal to the real device UUID.
                if existing.id != key && id == key { best[key] = (id, entry) }
            } else {
                best[key] = (id, entry)
            }
        }
        return best.values
            .map { DeviceInfo(identifier: $0.id, name: $0.entry.name, address: address,
                              model: nil, services: Array($0.entry.credentials.keys), isPaired: true) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func physicalKey(for identifier: String, entry: SavedDeviceEntry) -> String {
        for cred in entry.credentials.values {
            let parts = cred.split(separator: ":")
            if parts.count >= 3, let decoded = String(hexEncoded: String(parts[2])), !decoded.isEmpty {
                return decoded
            }
        }
        return identifier
    }

    /// Unicast-scan a single host (IP or `.local`) and merge any found Apple
    /// TVs into ``devices``. Use when broad mDNS scan misses a device — e.g.
    /// on networks where a VPN tunnel captures the multicast route or the
    /// Apple TV sits on a different subnet.
    func addDeviceByHost(_ host: String) async throws -> [DeviceInfo] {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let found: [DeviceInfo] = try await request("POST", "api/devices/by-host",
                                                    body: ["host": trimmed])
        for d in found {
            if let idx = devices.firstIndex(where: { $0.identifier == d.identifier }) {
                devices[idx] = d
            } else {
                devices.append(d)
            }
        }
        mergeSavedNames()
        return found
    }

    private func mergeSavedNames() {
        for (k, v) in savedDevices {
            if let idx = devices.firstIndex(where: { $0.identifier == k }),
               devices[idx].name != v.name {
                let d = devices[idx]
                devices[idx] = DeviceInfo(identifier: d.identifier, name: v.name, address: d.address,
                                          model: d.model, services: d.services, isPaired: true)
            }
        }
    }

    private func fetchSaved() async throws -> [String: SavedDeviceEntry] {
        try await request("GET", "api/devices/saved")
    }

    func forget(identifier: String) async throws {
        guard let url = buildURL("api/devices/\(escape(identifier))") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if connectedDevice?.identifier == identifier {
            connected = false
            connectedDevice = nil
        }
        await scan()
    }

    func connect(to device: DeviceInfo) async throws {
        connectedDevice = nil
        let info: DeviceInfo = try await request("POST", "api/connect/\(escape(device.identifier))")
        connectedDevice = info
        connected = true
        lastConnectedIdentifier = device.identifier
        autoConnectSuppressed = false
        openWebSocket()
        await refreshPlaying()
    }

    /// Refresh-button action: re-check backend status and, if the Apple TV
    /// connection was lost (network drop/change etc.), re-establish it to the
    /// LAST connected device using the saved credentials. Falls back to a
    /// device scan when reconnect isn't possible (e.g. never connected, or
    /// credentials forgotten).
    func refreshAndReconnect() async {
        await refreshStatus(scanIfDisconnected: false)
        if connected {
            // A dead connection is only detected server-side when an RPC
            // fails — poke it, then re-read the (possibly updated) status.
            await refreshPlaying()
            await refreshStatus(scanIfDisconnected: false)
        }
        if !connected {
            // Try the last connected device first; a scan's auto-connect
            // could otherwise latch onto a different paired Apple TV.
            await tryReconnect()
        }
        if !connected {
            await scan()
        }
        if connected {
            await refreshPlaying()
        }
    }

    private func tryReconnect() async {
        guard let id = lastConnectedIdentifier else { return }
        if savedDevices[id] == nil, let saved = try? await fetchSaved() {
            savedDevices = saved
        }
        guard let entry = savedDevices[id] else { return }
        let device = DeviceInfo(identifier: id, name: entry.name, address: "",
                                model: nil, services: Array(entry.credentials.keys), isPaired: true)
        do {
            try await connect(to: device)
        } catch {
            lastError = "Reconnect failed: \(error.localizedDescription)"
        }
    }

    func disconnect() async {
        autoConnectSuppressed = true
        try? await post("api/disconnect")
        connected = false
        connectedDevice = nil
        closeWebSocket()
    }

    func refreshPlaying() async {
        if let p: PlayingState = try? await request("GET", "api/playing"), p != playing {
            playing = p
        }
    }

    func sendCommand(_ name: String) async {
        do {
            try await post("api/command/\(escape(name))", body: [String: String]())
        } catch {
            lastError = "Command \(name) failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Pairing

    func pairStart(identifier: String) async throws -> PairStartResponse {
        try await request("POST", "api/pair/start", body: ["identifier": identifier])
    }

    func pairSubmit(sessionId: String, pin: String) async throws -> PairStartResponse {
        try await request("POST", "api/pair/\(escape(sessionId))/pin", body: ["pin": pin])
    }

    func pairCancel(sessionId: String) async {
        try? await post("api/pair/\(escape(sessionId))/cancel")
    }

    // MARK: - Keyboard

    /// Returns true when the POST succeeded (callers track last-sent state).
    @discardableResult
    func keyboardSet(_ text: String) async -> Bool {
        do {
            try await post("api/keyboard", body: ["text": text])
            return true
        } catch {
            lastError = "Keyboard set failed: \(error.localizedDescription)"
            return false
        }
    }

    func keyboardAppend(_ text: String) async {
        try? await post("api/keyboard/append", body: ["text": text])
    }

    func keyboardClear() async {
        try? await post("api/keyboard/clear")
    }

    func keyboardSnapshot() async -> KeyboardEvent? {
        try? await request("GET", "api/keyboard")
    }

    // MARK: - Out-of-band link watch

    private func ensureStatusWatch() {
        guard statusWatch == nil else { return }
        statusWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.syncLinkFromStatus()
            }
        }
    }

    /// A failed or timed-out read is skipped. The backend being unreachable
    /// is not an Apple TV disconnect, and this loop has to keep running.
    private func syncLinkFromStatus() async {
        let status: StatusResponse
        do {
            status = try await fetchLinkStatus()
        } catch {
            return
        }
        backendReachable = true
        if status.connected, let identifier = status.identifier {
            await noteBackendConnected(identifier)
        } else if connected {
            connected = false
            connectedDevice = nil
        }
    }

    private func fetchLinkStatus() async throws -> StatusResponse {
        guard let url = buildURL("api/status") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(StatusResponse.self, from: data)
    }

    private func noteBackendConnected(_ identifier: String) async {
        let wasConnected = connected
        lastConnectedIdentifier = identifier
        if connectedDevice?.identifier != identifier {
            await assignConnectedDevice(identifier)
        }
        guard !wasConnected else { return }
        connected = true
        if wsTask == nil { openWebSocket() }
        await refreshPlaying()
    }

    /// A failed saved-device read leaves `connectedDevice` as it was. The link
    /// can still be up; capture then matches any Apple TV device.
    private func assignConnectedDevice(_ identifier: String) async {
        let saved: [String: SavedDeviceEntry]
        do {
            saved = try await fetchSaved()
        } catch {
            return
        }
        savedDevices = saved
        guard let entry = saved[identifier] else { return }
        connectedDevice = DeviceInfo(
            identifier: identifier, name: entry.name, address: "",
            model: nil, services: Array(entry.credentials.keys), isPaired: true)
    }

    // MARK: - WebSocket

    func openWebSocket() {
        closeWebSocket()
        guard let url = wsURL else { return }
        let task = session.webSocketTask(with: url)
        wsTask = task
        task.resume()
        Task { await self.receiveLoop(task) }
    }

    func closeWebSocket() {
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while wsTask === task {
            do {
                let message = try await task.receive()
                // Healthy stream — reset the backoff.
                wsReconnectDelay = 1.5
                switch message {
                case .data(let d): handleWSData(d)
                case .string(let s): handleWSData(Data(s.utf8))
                @unknown default: break
                }
            } catch {
                if wsTask === task, connected {
                    // Reconnect with exponential backoff (1.5s → 30s cap) while
                    // we're still meant to be connected; restores updates when
                    // the backend comes back.
                    try? await Task.sleep(nanoseconds: UInt64(wsReconnectDelay * 1_000_000_000))
                    wsReconnectDelay = min(wsReconnectDelay * 2, 30)
                    if wsTask === task, connected {
                        openWebSocket()
                        await refreshPlaying()
                    }
                }
                return
            }
        }
    }

    private func handleWSData(_ data: Data) {
        struct Envelope: Decodable {
            let type: String?
            let state: PlayingState?
            let focused: Bool?
            let focus_state: String?
            let text: String?
            // Fallback fields when server omits type.
            let title: String?
            let device_state: String?
        }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { return }
        switch env.type {
        case "playing":
            if let s = env.state, s != playing { playing = s }
        case "disconnected":
            // Backend detected the Apple TV connection died (network drop,
            // TV reboot). Reflect it; refreshAndReconnect() can recover.
            connected = false
            connectedDevice = nil
        case "keyboard":
            keyboard = KeyboardEvent(
                focused: env.focused ?? false,
                focusState: env.focus_state,
                text: env.text)
        default:
            // Legacy untagged payload, treat as playing state.
            if env.title != nil || env.device_state != nil {
                if let s = try? JSONDecoder().decode(PlayingState.self, from: data), s != playing {
                    playing = s
                }
            }
        }
    }

    // MARK: - Helpers

    private func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    /// Build a URL by appending `path` (which may contain a `?queryString`) to
    /// the configured backend base. Foundation's `appendingPathComponent`
    /// percent-encodes `?` so we route through `URLComponents` instead.
    private func buildURL(_ path: String) -> URL? {
        guard let base = backendURL else { return nil }
        let baseStr = base.absoluteString.hasSuffix("/")
            ? String(base.absoluteString.dropLast())
            : base.absoluteString
        let normalized = path.hasPrefix("/") ? path : "/" + path
        return URL(string: baseStr + normalized)
    }
}

struct EmptyResponse: Decodable { init() {} }

enum BackendError: LocalizedError {
    case httpError(Int, String)
    var errorDescription: String? {
        switch self {
        case .httpError(let code, let detail): return "[\(code)] \(detail)"
        }
    }
}

/// Generic Encodable wrapper for heterogeneous bodies (dictionaries, structs, etc.).
struct AnyEncodable: Encodable {
    let _encode: (Encoder) throws -> Void
    init<T: Encodable>(_ value: T) { _encode = value.encode(to:) }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }
}

extension String {
    /// Decode a hex string into UTF-8 text (pyatv credentials hex-encode the
    /// device UUID). Returns nil on malformed input.
    init?(hexEncoded hex: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        guard let s = String(bytes: bytes, encoding: .utf8) else { return nil }
        self = s
    }
}
