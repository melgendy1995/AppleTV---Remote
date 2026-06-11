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

    func refreshStatus() async {
        do {
            let s: StatusResponse = try await request("GET", "api/status")
            backendReachable = true
            if s.connected, let ident = s.identifier {
                if let saved = try? await fetchSaved() {
                    savedDevices = saved
                    if let entry = saved[ident] {
                        connectedDevice = DeviceInfo(
                            identifier: ident, name: entry.name, address: "",
                            model: nil, services: Array(entry.credentials.keys), isPaired: true)
                    }
                }
                connected = true
                await refreshPlaying()
                openWebSocket()
            } else {
                connected = false
                connectedDevice = nil
                await scan()
            }
        } catch {
            backendReachable = false
            lastError = "Backend unreachable: \(error.localizedDescription)"
        }
    }

    func scan() async {
        do {
            devices = try await request("GET", "api/devices?timeout=4")
            savedDevices = try await fetchSaved()
            for (k, v) in savedDevices {
                if let idx = devices.firstIndex(where: { $0.identifier == k }) {
                    // server already returns is_paired; sync the saved name in case it differs
                    if devices[idx].name != v.name {
                        let d = devices[idx]
                        devices[idx] = DeviceInfo(identifier: d.identifier, name: v.name, address: d.address,
                                                  model: d.model, services: d.services, isPaired: true)
                    }
                }
            }
        } catch {
            lastError = "Scan failed: \(error.localizedDescription)"
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
        openWebSocket()
        await refreshPlaying()
    }

    func disconnect() async {
        try? await post("api/disconnect")
        connected = false
        connectedDevice = nil
        closeWebSocket()
    }

    func refreshPlaying() async {
        if let p: PlayingState = try? await request("GET", "api/playing") {
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

    func keyboardSet(_ text: String) async {
        do { try await post("api/keyboard", body: ["text": text]) }
        catch { lastError = "Keyboard set failed: \(error.localizedDescription)" }
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
                switch message {
                case .data(let d): handleWSData(d)
                case .string(let s): handleWSData(Data(s.utf8))
                @unknown default: break
                }
            } catch {
                if wsTask === task {
                    // Reconnect after a short delay if we're still meant to be connected.
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if wsTask === task, connected { openWebSocket() }
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
            if let s = env.state { playing = s }
        case "keyboard":
            keyboard = KeyboardEvent(
                focused: env.focused ?? false,
                focusState: env.focus_state,
                text: env.text)
        default:
            // Legacy untagged payload, treat as playing state.
            if env.title != nil || env.device_state != nil {
                if let s = try? JSONDecoder().decode(PlayingState.self, from: data) {
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
