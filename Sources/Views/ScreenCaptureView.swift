import AppKit
import SwiftUI

struct ScreenCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coord = CaptureCoordinator()
    @State private var pollTask: Task<Void, Never>?
    @State private var savedURL: URL?
    @State private var savedKind: String = ""

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 12) {
                header
                if !coord.permissionGranted {
                    permissionBanner
                } else if coord.quicktimeWindow == nil {
                    quickTimeBanner
                }
                preview
                controls
                if let url = savedURL { savedToast(url: url) }
                if let err = coord.lastError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(minWidth: 460, minHeight: 520)
        }
        .preferredColorScheme(.dark)
        .onAppear { start() }
        .onDisappear { stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Apple TV Capture")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Theme.text)
            Spacer()
            if coord.isStreaming {
                HStack(spacing: 6) {
                    Circle().fill(Theme.good).frame(width: 8, height: 8)
                    Text("Live")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.muted)
                }
            }
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .foregroundColor(Theme.muted)
        }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
            Group {
                if let image = coord.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else if coord.quicktimeWindow == nil {
                    VStack(spacing: 6) {
                        Text("No QuickTime window detected")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.muted)
                        Text("Open QuickTime → New Movie Recording → pick your Apple TV.")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.muted)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .aspectRatio(16.0/9.0, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            if coord.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Theme.danger).frame(width: 8, height: 8)
                        .shadow(color: Theme.danger.opacity(0.6), radius: 3)
                    Text(formatElapsed(coord.recordingElapsed))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.black.opacity(0.55))
                .clipShape(Capsule())
                .padding(8)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    if let url = await coord.captureScreenshot() { announceSave(url, kind: "Screenshot") }
                }
            } label: {
                Text("📸 Screenshot")
            }
            .buttonStyle(SurfaceButton())
            .disabled(!coord.isStreaming)

            Button {
                Task {
                    if coord.isRecording {
                        if let url = await coord.stopRecording() { announceSave(url, kind: "Recording") }
                    } else {
                        await coord.startRecording()
                    }
                }
            } label: {
                Text(coord.isRecording ? "⏹ Stop" : "⏺ Record")
            }
            .buttonStyle(coord.isRecording ? AnyButtonStyle(DangerButton()) : AnyButtonStyle(PrimaryButton()))
            .disabled(!coord.isStreaming)
        }
    }

    // MARK: - Banners / toasts

    private var permissionBanner: some View {
        HStack {
            Text("Screen Recording permission is required. Grant access in System Settings → Privacy & Security → Screen & System Audio Recording, then restart the app.")
                .font(.system(size: 11))
                .foregroundColor(Theme.danger)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
                coord.ensurePermission()
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundColor(Theme.accent)
        }
        .padding(10)
        .background(Theme.danger.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var quickTimeBanner: some View {
        HStack {
            Text("Open QuickTime → File → New Movie Recording → pick your Apple TV.")
                .font(.system(size: 11))
                .foregroundColor(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open QuickTime") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/QuickTime Player.app"))
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundColor(Theme.accent)
        }
        .padding(10)
        .background(Theme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
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

    private func start() {
        coord.ensurePermission()
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await coord.startIfPossible()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stop() {
        pollTask?.cancel()
        pollTask = nil
        Task { await coord.stop() }
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
}

// MARK: - Danger button + type-erased style

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
