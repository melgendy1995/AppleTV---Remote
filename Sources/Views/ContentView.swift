import AppKit
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
    @State private var savedURL: URL?
    @State private var savedKind: String = ""
    @State private var capturePollTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            HStack(spacing: 0) {
                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(Theme.border)
                sidebar
                    .frame(width: 340)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { startCapturePolling() }
        .onDisappear { stopCapturePolling() }
        .onChange(of: client.keyboard) { _, new in handleKeyboardChange(new) }
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
            KeyboardView(autoOpened: $keyboardAutoOpened)
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
            if let image = capture.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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
                Text("Waiting for QuickTime")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text("Open QuickTime → File → New Movie Recording → pick your Apple TV. The live preview will appear here.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Open QuickTime") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/QuickTime Player.app"))
                }
                .buttonStyle(SurfaceButton())
                .frame(width: 180)
            } else {
                ProgressView().controlSize(.small).tint(Theme.muted)
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
                            .shadow(color: Theme.danger.opacity(0.7), radius: 4)
                        Text(formatElapsed(capture.recordingElapsed))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
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
                .opacity(client.connected ? 1 : 0.4)
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
                    .shadow(color: client.connected ? Theme.good.opacity(0.6) : .clear, radius: 4)
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

            Button { Task { await client.refreshPlaying(); await client.scan() } } label: { Text("↻") }
                .buttonStyle(IconButton())
                .help("Rescan")

            Button { showSettings = true } label: { Text("⚙") }
                .buttonStyle(IconButton())
                .help("Settings")
        }
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
        .background(Theme.danger.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.danger.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .background(Theme.good.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Helpers

    private func startCapturePolling() {
        capture.ensurePermission()
        stopCapturePolling()
        capturePollTask = Task {
            while !Task.isCancelled {
                await capture.startIfPossible()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
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

    private func handleKeyboardChange(_ kb: KeyboardEvent) {
        if kb.focused {
            if !showKeyboard {
                keyboardAutoOpened = true
                showKeyboard = true
            }
        } else if keyboardAutoOpened {
            showKeyboard = false
            keyboardAutoOpened = false
        }
    }
}

// MARK: - Danger button + type-erased style (used by capture actions)

private struct DangerButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.danger.opacity(configuration.isPressed ? 0.7 : 1.0))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
