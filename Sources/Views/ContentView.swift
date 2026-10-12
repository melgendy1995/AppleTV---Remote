import AppKit
import AVFoundation
import SwiftUI

/// Cinema layout: the QuickTime capture stream fills the left stage; a compact
/// sidebar on the right holds status, the remote controls, and capture actions.
struct ContentView: View {
    @EnvironmentObject private var client: BackendClient
    @EnvironmentObject private var capture: CaptureCoordinator
    @State private var showDevicePicker = false
    @State private var showSettings = false
    @State private var showKeyboard = false
    @State private var keyboardAutoOpened = false
    @State private var pairingDevice: DeviceInfo?
    @State private var sidebarHidden = false
    @State private var savedURL: URL?
    @State private var savedKind: String = ""
    @State private var capturePollTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            HStack(spacing: 0) {
                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !sidebarHidden {
                    Divider().overlay(Theme.border)
                    sidebar
                        .frame(width: 340)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            // Floating way back when the remote is hidden (fullscreen mode).
            if sidebarHidden {
                Button { setRemoteHidden(false) } label: { Text("«") }
                    .buttonStyle(IconButton())
                    .help("Show remote")
                    .padding(16)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            startCapturePolling()
            capture.setActiveDevice(name: client.connectedDevice?.name)
        }
        .onDisappear { stopCapturePolling() }
        .onChange(of: client.keyboard) { _, new in handleKeyboardChange(new) }
        // The screen follows the selected Apple TV: connecting (or switching)
        // a device retargets the QuickTime source automatically.
        .onChange(of: client.connectedDevice) { _, device in
            capture.setActiveDevice(name: device?.name)
        }
        // When another sheet blocked the auto-open, retry once it dismisses.
        .onChange(of: showDevicePicker) { _, shown in if !shown { retryKeyboardAutoOpen() } }
        .onChange(of: showSettings) { _, shown in if !shown { retryKeyboardAutoOpen() } }
        .onChange(of: pairingDevice) { _, device in if device == nil { retryKeyboardAutoOpen() } }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
        .sheet(isPresented: $showDevicePicker) {
            DevicePickerView(onPair: { device in
                showDevicePicker = false
                pairingDevice = device
            })
            .environmentObject(client)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(client)
        }
        .sheet(isPresented: $showKeyboard) {
            KeyboardView()
                .environmentObject(client)
        }
        .sheet(item: $pairingDevice) { device in
            PairingView(device: device)
                .environmentObject(client)
        }
    }

    // MARK: - Stage (left: capture stream)

    private var stage: some View {
        ZStack {
            Color.black
            if capture.isStreaming, let adapter = capture.streamOutput {
                SampleBufferPreview(adapter: adapter)
            } else {
                stagePlaceholder
            }
            recordingOverlay
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(12)
    }

    private var stagePlaceholder: some View {
        VStack(spacing: 10) {
            if !capture.permissionGranted {
                Text("Screen Recording permission required")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text("Grant access in System Settings → Privacy & Security → Screen & System Audio Recording, then restart the app.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                    capture.ensurePermission()
                }
                .buttonStyle(SurfaceButton())
                .frame(width: 180)
            } else if capture.quicktimeWindow == nil {
                Text("Waiting for the Apple TV screen")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text(client.connected
                     ? "QuickTime is being opened and pointed at \(client.connectedDevice?.name ?? "your Apple TV") automatically…"
                     : "Connect to an Apple TV (⋮ menu) and its screen will appear here automatically.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Open QuickTime Manually") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/QuickTime Player.app"))
                }
                .buttonStyle(SurfaceButton())
                .frame(width: 200)
            } else {
                Text("Connecting to \(capture.quicktimeWindow?.title ?? "QuickTime")…")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
            }
        }
    }

    private var recordingOverlay: some View {
        VStack {
            HStack {
                if capture.isRecording {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.danger).frame(width: 10, height: 10)
                        Text("\(formatElapsed(capture.recordingElapsed)) · \(formatBytes(capture.recordingFileSize))")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .glassCapsule()
                }
                Spacer()
            }
            Spacer()
        }
        .padding(14)
    }

    // MARK: - Sidebar (right: controls + capture actions)

    private var sidebar: some View {
        VStack(spacing: 12) {
            topbar
            if !client.backendReachable { backendBanner }
            NowPlayingCard()
            RemoteControlsView()
                .disabled(!client.connected)
            Divider().overlay(Theme.border)
            captureActions
            if let url = savedURL { savedToast(url: url) }
            if let err = capture.lastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity)
        .background(Theme.bg)
    }

    private var topbar: some View {
        HStack(spacing: 8) {
            Button { showDevicePicker = true } label: { Text("⋮") }
                .buttonStyle(IconButton())
                .help("Devices")

            HStack(spacing: 8) {
                Circle()
                    .fill(client.connected ? Theme.good : Theme.muted)
                    .frame(width: 9, height: 9)
                Text(client.connected ? (client.connectedDevice?.name ?? "Connected") : "Not connected")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { showKeyboard = true } label: { Text("⌨") }
                .buttonStyle(IconButton())
                .help("Keyboard")
                .disabled(!client.connected)

            Button { Task {
                await client.refreshAndReconnect()
                await capture.refreshAndRecover()
            } } label: { Text("↻") }
                .buttonStyle(IconButton())
                .help("Refresh connections and screen")

            Button { showSettings = true } label: { Text("⚙") }
                .buttonStyle(IconButton())
                .help("Settings")

            Button { setRemoteHidden(true) } label: { Text("»") }
                .buttonStyle(IconButton())
                .help("Hide remote")
        }
    }

    /// Collapse the remote sidebar so the capture stream fills the whole
    /// window. Deliberately does NOT enter real fullscreen: fullscreen moves
    /// the app to its own Space, which occludes the QuickTime window being
    /// captured and freezes the stream.
    private func setRemoteHidden(_ hidden: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) { sidebarHidden = hidden }
    }

    private var captureActions: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    if let url = await capture.captureScreenshot() { announceSave(url, kind: "Screenshot") }
                }
            } label: {
                Text("📸 Snap")
            }
            .buttonStyle(SurfaceButton())
            .disabled(!capture.isStreaming)
            .help("Screenshot (S)")

            Button {
                Task {
                    if capture.isRecording {
                        if let url = await capture.stopRecording() { announceSave(url, kind: "Recording") }
                    } else {
                        await capture.startRecording()
                    }
                }
            } label: {
                Text(capture.isRecording ? "⏹ Stop" : "⏺ Rec")
            }
            .buttonStyle(capture.isRecording ? AnyButtonStyle(DangerButton()) : AnyButtonStyle(PrimaryButton()))
            .disabled(!capture.isStreaming)
            .help("Toggle recording (R)")
        }
    }

    private var backendBanner: some View {
        HStack {
            Text("Can't reach backend at \(client.backendURLString)")
                .font(.system(size: 12))
                .foregroundColor(Theme.danger)
            Spacer()
            Button("Settings") { showSettings = true }
                .font(.system(size: 12))
                .foregroundColor(Theme.danger)
                .buttonStyle(.plain)
        }
        .padding(10)
        .glassCard(cornerRadius: 10, tint: Theme.danger)
    }

    private func savedToast(url: URL) -> some View {
        HStack {
            Text("\(savedKind) saved: \(url.lastPathComponent)")
                .font(.system(size: 11))
                .foregroundColor(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundColor(Theme.accent)
        }
        .padding(10)
        .glassCard(cornerRadius: 10, tint: Theme.good)
    }

    // MARK: - Helpers

    private func startCapturePolling() {
        capture.ensurePermission()
        stopCapturePolling()
        capturePollTask = Task {
            while !Task.isCancelled {
                await capture.startIfPossible()
                // Healthy means a frame has already arrived. Until then the
                // poll is what opens QuickTime and starts the stream.
                let streamingHealthy = capture.isStreaming && (capture.streamOutput?.frameCount ?? 0) > 0
                let pauseNs: UInt64 = streamingHealthy ? 5_000_000_000 : 2_000_000_000
                try? await Task.sleep(nanoseconds: pauseNs)
            }
        }
    }

    private func stopCapturePolling() {
        capturePollTask?.cancel()
        capturePollTask = nil
    }

    private func announceSave(_ url: URL, kind: String) {
        savedURL = url
        savedKind = kind
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// True while any sheet other than the keyboard is up — SwiftUI silently
    /// drops a second .sheet presentation, so auto-open must wait.
    private var anySheetPresented: Bool {
        showDevicePicker || showSettings || pairingDevice != nil
    }

    private func retryKeyboardAutoOpen() {
        if client.keyboard.focused, !showKeyboard, !anySheetPresented {
            keyboardAutoOpened = true
            showKeyboard = true
        }
    }

    private func handleKeyboardChange(_ kb: KeyboardEvent) {
        if kb.focused {
            if !showKeyboard && !anySheetPresented {
                keyboardAutoOpened = true
                showKeyboard = true
            }
        } else if keyboardAutoOpened {
            showKeyboard = false
            keyboardAutoOpened = false
        }
    }
}

/// Hosts the capture preview. The layer is updated from the sample queue,
/// so SwiftUI does not re-render the window for each frame.
private struct SampleBufferPreview: NSViewRepresentable {
    let adapter: StreamOutputAdapter

    func makeNSView(context: Context) -> SampleBufferHostView {
        let view = SampleBufferHostView()
        view.attach(adapter)
        return view
    }

    func updateNSView(_ nsView: SampleBufferHostView, context: Context) {
        nsView.attach(adapter)
    }

    static func dismantleNSView(_ nsView: SampleBufferHostView, coordinator: ()) {
        nsView.detach()
    }
}

private final class SampleBufferHostView: NSView {
    private var adapter: StreamOutputAdapter?

    func attach(_ adapter: StreamOutputAdapter?) {
        if self.adapter !== adapter {
            self.adapter?.attachPreviewLayer(nil)
            self.adapter = adapter
        }
        wantsLayer = true
        let display = (layer as? AVSampleBufferDisplayLayer) ?? AVSampleBufferDisplayLayer()
        if layer !== display {
            display.videoGravity = .resizeAspect
            display.backgroundColor = NSColor.black.cgColor
            layer = display
        }
        display.frame = bounds
        adapter?.attachPreviewLayer(display)
    }

    func detach() {
        adapter?.attachPreviewLayer(nil)
        adapter = nil
        (layer as? AVSampleBufferDisplayLayer)?.sampleBufferRenderer.flush()
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
    }
}

// MARK: - Danger button + type-erased style (used by capture actions)

private struct DangerButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundColor(.white)
            .contentShape(Rectangle())
            .glassButton(tint: Theme.danger, isPressed: configuration.isPressed)
    }
}

private struct AnyButtonStyle: ButtonStyle {
    private let _makeBody: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) {
        self._makeBody = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View {
        _makeBody(configuration)
    }
}
