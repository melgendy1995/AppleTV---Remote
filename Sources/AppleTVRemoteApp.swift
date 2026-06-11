import SwiftUI
import AppKit

@main
struct AppleTVRemoteApp: App {
    @StateObject private var client = BackendClient()
    @StateObject private var backend = BackendController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .environmentObject(backend)
                .task {
                    appDelegate.backend = backend
                    await backend.startIfEmbedded()
                    if let url = backend.embeddedURL {
                        client.backendURLString = url.absoluteString
                    }
                    await client.refreshStatus()
                }
        }
        .defaultSize(width: 380, height: 680)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Settings…") { NotificationCenter.default.post(name: .openSettings, object: nil) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var backend: BackendController?
    func applicationWillTerminate(_ notification: Notification) {
        backend?.stop()
    }
}

struct RootView: View {
    @EnvironmentObject private var backend: BackendController
    var body: some View {
        switch backend.state {
        case .running, .external, .idle:
            ContentView()
        case .starting:
            BackendBootView(status: "Starting bundled backend…", showRetry: false)
        case .failed(let message):
            BackendBootView(status: "Backend failed:\n\n\(message)", showRetry: true)
        }
    }
}

struct BackendBootView: View {
    @EnvironmentObject private var backend: BackendController
    @EnvironmentObject private var client: BackendClient
    let status: String
    let showRetry: Bool

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                if !showRetry {
                    ProgressView().tint(Theme.accent)
                }
                Text(status)
                    .font(.system(size: 13).monospaced())
                    .foregroundColor(showRetry ? Theme.danger : Theme.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .frame(maxWidth: 400)
                if showRetry {
                    HStack(spacing: 8) {
                        Button("Retry") {
                            Task {
                                await backend.start()
                                if let url = backend.embeddedURL { client.backendURLString = url.absoluteString }
                                await client.refreshStatus()
                            }
                        }
                        .buttonStyle(PrimaryButton())
                        Button("Quit") { NSApp.terminate(nil) }
                            .buttonStyle(SurfaceButton())
                    }
                    .frame(maxWidth: 240)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 340, minHeight: 240)
        .preferredColorScheme(.dark)
    }
}

extension Notification.Name {
    static let openSettings = Notification.Name("ATV.openSettings")
}
