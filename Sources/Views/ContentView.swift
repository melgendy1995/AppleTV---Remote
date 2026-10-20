import AppKit
import AVFoundation
import SwiftUI

/// Cinema layout: the Apple TV capture feed fills the left stage; a compact
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
            capture.updateBackendLink(connected: client.connected, deviceName: client.connectedDevice?.name)
        }
        .onDisappear { stopCapturePolling() }
        .onChange(of: client.keyboard) { _, new in handleKeyboardChange(new) }
        // The screen follows the Apple TV connection. CMIO and the capture
        // session stay down until the backend reports connected.
        .onChange(of: client.connected) { _, connected in
            capture.updateBackendLink(connected: connected, deviceName: client.connectedDevice?.name)
        }
        .onChange(of: client.connectedDevice?.name) { _, name in
            capture.updateBackendLink(connected: client.connected, deviceName: name)
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
                .environmentObject(capture)
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
            if capture.isStreaming {
                capturePreview
            } else {
                stagePlaceholder
            }
            // Only while recording. A full-size clear overlay would sit on the
            // video for the whole session and force WindowServer to blend it.
            if capture.isRecording {
                recordingOverlay
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var capturePreview: some View {
        if capture.latchedPreviewMode == .sampleBuffer, let adapter = capture.streamOutput {
            SampleBufferPreview(adapter: adapter)
        } else if let session = capture.previewSession {
            PreviewLayerHost(session: session) { layer in
                capture.notePreviewLayer(layer)
            }
        }
    }

    private var stagePlaceholder: some View {
        VStack(spacing: 10) {
            if !capture.streamEnabled {
                Text("Screen stream is off")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text("The Apple TV screen is not being acquired. Turn the stream on in Settings, or connect again to start it.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Settings") { showSettings = true }
                    .buttonStyle(SurfaceButton())
                    .frame(width: 180)
            } else if !capture.permissionGranted {
                Text("Camera permission required")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text("The Apple TV screen arrives as a capture device. Grant access in System Settings → Privacy & Security → Camera, then retry.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Allow Camera") {
                    if AVCaptureDevice.authorizationStatus(for: .video) != .notDetermined,
                       let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                    capture.ensurePermission()
                }
                .buttonStyle(SurfaceButton())
                .frame(width: 180)
            } else if capture.captureDeviceName == nil {
                Text("Waiting for the Apple TV screen")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text(client.connected
                     ? "Looking for \(client.connectedDevice?.name ?? "your Apple TV") as a capture device…"
                     : "Connect to an Apple TV (⋮ menu) and its screen will appear here automatically.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            } else {
                Text("Connecting to \(capture.captureDeviceName ?? "Apple TV")…")
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
    /// window. This does not enter macOS fullscreen.
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
                // poll is what opens the capture device and starts the session.
                let streamingHealthy = capture.feedIsHealthy
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

/// Hosts `AVCaptureVideoPreviewLayer` as the view's backing layer. The session
/// pushes frames; SwiftUI does not re-render per frame. No filters, mask, or
/// corner radius — those force an offscreen pass.
private struct PreviewLayerHost: NSViewRepresentable {
    let session: AVCaptureSession
    let onLayer: (AVCaptureVideoPreviewLayer) -> Void

    func makeNSView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        view.attach(session: session, onLayer: onLayer)
        return view
    }

    func updateNSView(_ nsView: PreviewLayerView, context: Context) {
        nsView.attach(session: session, onLayer: onLayer)
    }

    static func dismantleNSView(_ nsView: PreviewLayerView, coordinator: ()) {
        nsView.detach()
    }
}

private final class PreviewLayerView: NSView {
    private var onLayer: ((AVCaptureVideoPreviewLayer) -> Void)?

    override var isOpaque: Bool { true }

    func attach(session: AVCaptureSession, onLayer: @escaping (AVCaptureVideoPreviewLayer) -> Void) {
        self.onLayer = onLayer
        wantsLayer = true
        clipsToBounds = false
        let preview = (layer as? AVCaptureVideoPreviewLayer) ?? AVCaptureVideoPreviewLayer(session: session)
        if layer !== preview {
            layer = preview
            prepare(preview)
        }
        if preview.session !== session {
            preview.session = session
        }
        syncGeometry(preview)
        onLayer(preview)
    }

    func detach() {
        onLayer = nil
        (layer as? AVCaptureVideoPreviewLayer)?.session = nil
    }

    override func layout() {
        super.layout()
        guard let preview = layer as? AVCaptureVideoPreviewLayer else { return }
        syncGeometry(preview)
        onLayer?(preview)
        makeWindowOpaque()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        makeWindowOpaque()
        guard let preview = layer as? AVCaptureVideoPreviewLayer else { return }
        syncGeometry(preview)
        onLayer?(preview)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let preview = layer as? AVCaptureVideoPreviewLayer else { return }
        syncGeometry(preview)
    }

    private func prepare(_ preview: AVCaptureVideoPreviewLayer) {
        preview.videoGravity = .resizeAspect
        preview.backgroundColor = NSColor.black.cgColor
        preview.isOpaque = true
        preview.cornerRadius = 0
        preview.masksToBounds = false
        preview.shadowOpacity = 0
        syncGeometry(preview)
    }

    private func syncGeometry(_ preview: AVCaptureVideoPreviewLayer) {
        preview.frame = bounds
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if preview.contentsScale != scale {
            preview.contentsScale = scale
        }
    }

    private func makeWindowOpaque() {
        guard let window else { return }
        let clear = window.backgroundColor == nil || window.backgroundColor == .clear
        guard !window.isOpaque || clear else { return }
        window.isOpaque = true
        window.backgroundColor = .black
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

    override var isOpaque: Bool { true }

    func attach(_ adapter: StreamOutputAdapter?) {
        if self.adapter !== adapter {
            self.adapter?.attachPreviewLayer(nil)
            self.adapter = adapter
        }
        wantsLayer = true
        clipsToBounds = false
        let display = (layer as? AVSampleBufferDisplayLayer) ?? AVSampleBufferDisplayLayer()
        if layer !== display {
            layer = display
            prepareDisplay(display)
        }
        syncGeometry(display)
        adapter?.attachPreviewLayer(display)
    }

    func detach() {
        adapter?.attachPreviewLayer(nil)
        adapter = nil
        (layer as? AVSampleBufferDisplayLayer)?.sampleBufferRenderer.flush()
    }

    override func layout() {
        super.layout()
        if let display = layer as? AVSampleBufferDisplayLayer {
            syncGeometry(display)
        }
        makeWindowOpaque()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        makeWindowOpaque()
        if let display = layer as? AVSampleBufferDisplayLayer {
            syncGeometry(display)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let display = layer as? AVSampleBufferDisplayLayer {
            syncGeometry(display)
        }
    }

    /// No mask, shadow, or corner radius — those force an offscreen pass.
    private func prepareDisplay(_ display: AVSampleBufferDisplayLayer) {
        display.videoGravity = .resizeAspect
        display.backgroundColor = NSColor.black.cgColor
        display.isOpaque = true
        display.cornerRadius = 0
        display.masksToBounds = false
        display.shadowOpacity = 0
        syncGeometry(display)
    }

    /// Backing layer fills the view. `contentsScale` matches the window so
    /// WindowServer does not rescale a 1x layer on a Retina backing store.
    private func syncGeometry(_ display: AVSampleBufferDisplayLayer) {
        display.frame = bounds
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if display.contentsScale != scale {
            display.contentsScale = scale
        }
    }

    private func makeWindowOpaque() {
        guard let window else { return }
        let clear = window.backgroundColor == nil || window.backgroundColor == .clear
        guard !window.isOpaque || clear else { return }
        window.isOpaque = true
        window.backgroundColor = .black
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
