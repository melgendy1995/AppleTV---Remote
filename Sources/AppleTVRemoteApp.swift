import SwiftUI
import AppKit

@main
struct AppleTVRemoteApp: App {
    @StateObject private var client = BackendClient()
    @StateObject private var backend = BackendController()
    @StateObject private var capture = CaptureCoordinator()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                .environmentObject(backend)
                .environmentObject(capture)
                .task {
                    appDelegate.backend = backend
                    appDelegate.client = client
                    appDelegate.capture = capture
                    await backend.startIfEmbedded()
                    if let url = backend.embeddedURL {
                        client.backendURLString = url.absoluteString
                    }
                    await client.refreshStatus()
                }
        }
        .defaultSize(width: 1200, height: 720)
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
    weak var client: BackendClient?
    weak var capture: CaptureCoordinator?
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.handleRemoteKey(event) else { return event }
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        backend?.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// Tracks a return-key press across keyDown/keyUp so a hold (key repeat)
    /// becomes select_hold while a quick press stays a single select.
    private var returnPressActive = false
    private var returnHoldSent = false
    /// Pending single home keypress; a second `h` within 250ms upgrades it to
    /// a double-press (tvOS app switcher).
    private var homeTapWorkItem: DispatchWorkItem?

    /// Remote keyboard shortcuts live here (not on the sidebar buttons) so
    /// they keep working when the remote sidebar is hidden. Guards: only in
    /// the main window with no sheet up, no modifiers held, and never while
    /// a text field is being edited.
    private func handleRemoteKey(_ event: NSEvent) -> Bool {
        // Finalize a return-key press on release: no repeat seen → single tap.
        if event.type == .keyUp {
            guard event.keyCode == 36, returnPressActive else { return false }
            returnPressActive = false
            if !returnHoldSent { sendRemote("select") }
            returnHoldSent = false
            return true
        }

        guard let win = NSApp.keyWindow, win === NSApp.mainWindow,
              win.attachedSheet == nil,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              !(win.firstResponder is NSTextView)
        else { return false }

        // Capture shortcuts (work with the sidebar hidden, no backend
        // connection needed): S = screenshot, R = toggle recording.
        // Saved files are revealed in Finder automatically.
        if event.keyCode == 1 {  // s
            guard !event.isARepeat else { return true }
            Task { @MainActor [weak self] in
                guard let capture = self?.capture, capture.isStreaming else { return }
                if let url = await capture.captureScreenshot() {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            return true
        }
        if event.keyCode == 15 {  // r
            guard !event.isARepeat else { return true }
            Task { @MainActor [weak self] in
                guard let capture = self?.capture, capture.isStreaming else { return }
                if capture.isRecording {
                    if let url = await capture.stopRecording() {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } else {
                    await capture.startRecording()
                }
            }
            return true
        }

        // Long-press return → select_hold. A held key arrives as repeat
        // keyDowns; the actual command fires on keyUp (single tap) or on the
        // first repeat (hold).
        if event.keyCode == 36 {
            if event.isARepeat {
                if returnPressActive, !returnHoldSent {
                    returnHoldSent = true
                    sendRemote("select_hold")
                }
            } else {
                returnPressActive = true
                returnHoldSent = false
            }
            return true
        }

        // Double-press h → app switcher. First press is delayed 250ms so a
        // second press can upgrade it to home_double.
        if event.keyCode == 4 {
            guard !event.isARepeat else { return true }
            if let pending = homeTapWorkItem {
                pending.cancel()
                homeTapWorkItem = nil
                sendRemote("home_double")
                return true
            }
            let work = DispatchWorkItem { [weak self] in
                self?.homeTapWorkItem = nil
                self?.sendRemote("home")
            }
            homeTapWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            return true
        }

        let command: String
        switch event.keyCode {
        case 123: command = "left"
        case 124: command = "right"
        case 125: command = "down"
        case 126: command = "up"
        case 49:  command = "play_pause" // space
        case 53:  command = "menu"      // escape
        case 35:  command = "previous"  // p
        case 45:  command = "next"      // n
        default: return false
        }
        sendRemote(command)
        return true
    }

    /// Remote commands need a live TV connection. Local event monitors run on
    /// the main thread; BackendClient state is MainActor-isolated.
    private func sendRemote(_ command: String) {
        guard let client, MainActor.assumeIsolated({ client.connected }) else { return }
        Task { await client.sendCommand(command) }
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
