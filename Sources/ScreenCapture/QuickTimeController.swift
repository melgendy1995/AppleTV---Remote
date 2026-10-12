import AppKit
import ApplicationServices
import OSLog

/// Drives QuickTime Player's "Movie Recording" window on behalf of the app:
/// opens it on demand, selects the right Apple TV source via the
/// accessibility tree, detects error dialogs, and quits it for clean
/// restarts. The Apple TV screen is invisible to public capture APIs —
/// QuickTime's wireless screen-share is the only free software path — so we
/// automate it instead of asking the user to click through it.
///
/// Deliberately uses NO Apple Events (TCC automation consent is unreliable
/// for ad-hoc signed apps): the only permission needed is Accessibility,
/// prompted once and then retried automatically by the capture poll.
@MainActor
final class QuickTimeController {

    enum QuickTimeError: LocalizedError {
        case accessibilityNotGranted
        case noRecordingWindow
        case noSourceButton
        case sourceNotFound(String)

        var errorDescription: String? {
            switch self {
            case .accessibilityNotGranted:
                return "Accessibility permission needed to drive QuickTime. Grant it in System Settings → Privacy & Security → Accessibility, then retry."
            case .noRecordingWindow:
                return "QuickTime opened but no Movie Recording window appeared."
            case .noSourceButton:
                return "Couldn't find QuickTime's capture-source menu."
            case .sourceNotFound(let name):
                return "QuickTime doesn't list \"\(name)\" as a source — is the Apple TV awake and on this network?"
            }
        }
    }

    private static let bundleID = "com.apple.QuickTimePlayerX"
    private static let recordingWindowTitle = "Movie Recording"
    private static let log = Logger(subsystem: "app.appletvremote", category: "quicktime")
    /// Section headers inside the capture-source menu. Apple TVs live under
    /// "Screen"; the same names repeat under "Speaker" (audio out).
    private static let menuSections: Set<String> = ["Camera", "Microphone", "Screen", "Speaker", "Quality"]
    /// Points of the window left on the desktop. Zero overlap stalls capture.
    private static let parkedOverlap: CGFloat = 8
    private static let parkedOriginKey = "parkedQuickTimeWindowOrigin"

    // MARK: - App lifecycle

    private var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
    }

    var isRunning: Bool { runningApp != nil }

    func quit() {
        runningApp?.terminate()
    }

    /// Open a Movie Recording window if none exists. Everything goes through
    /// NSWorkspace + the accessibility tree — deliberately no Apple Events,
    /// so the app only ever needs ONE TCC grant (Accessibility).
    func openMovieRecording() async throws {
        if hasRecordingWindow() { return }
        try ensureAccessibility()
        if !isRunning {
            let url = URL(fileURLWithPath: "/System/Applications/QuickTime Player.app")
            try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
            for _ in 0..<12 where !isRunning {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        // File → New Movie Recording, pressed via the AX menu bar. QuickTime
        // rejects AX messages while it's still launching (CannotComplete),
        // so retry the menu bar lookup for a few seconds before failing.
        var menuBar: AXUIElement?
        var fileItem: AXUIElement?
        for _ in 0..<16 {
            if let mb = menuBarElement() {
                menuBar = mb
                fileItem = children(of: mb).first(where: { title(of: $0) == "File" })
                if fileItem != nil { break }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard menuBar != nil, let fileItem else {
            Self.log.error("open: no File menu bar item after waiting")
            throw QuickTimeError.noRecordingWindow
        }
        press(fileItem)
        var fileMenu: AXUIElement?
        for _ in 0..<10 {
            try await Task.sleep(nanoseconds: 100_000_000)
            fileMenu = firstChild(of: fileItem, role: kAXMenuRole)
            if fileMenu != nil { break }
        }
        guard let fileMenu else {
            Self.log.error("open: File menu did not appear")
            throw QuickTimeError.noRecordingWindow
        }
        guard let newRecording = children(of: fileMenu).first(where: {
            role(of: $0) == kAXMenuItemRole && (title(of: $0) ?? "").hasPrefix("New Movie Recording")
        }) else {
            let names = children(of: fileMenu).compactMap { title(of: $0) }
            Self.log.error("open: no New Movie Recording item (have: \(names, privacy: .public))")
            throw QuickTimeError.noRecordingWindow
        }
        press(newRecording)
        for _ in 0..<20 where !hasRecordingWindow() {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        if !hasRecordingWindow() {
            let names = axWindows().compactMap { title(of: $0) }
            Self.log.error("open: window never appeared (windows: \(names, privacy: .public))")
        }
        guard hasRecordingWindow() else { throw QuickTimeError.noRecordingWindow }
    }

    /// Throws when Accessibility hasn't been granted yet; the system prompt
    /// is raised on the way out so the user gets sent to System Settings.
    /// The next poll (2s) retries automatically once granted.
    private func ensureAccessibility() throws {
        guard !AXIsProcessTrusted() else { return }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        throw QuickTimeError.accessibilityNotGranted
    }

    private func menuBarElement() -> AXUIElement? {
        guard let appElement else { return nil }
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &value)
        guard err == .success, value != nil else {
            Self.log.error("menuBar failed: \(err.rawValue)")
            return nil
        }
        return (value as! AXUIElement)
    }

    // MARK: - Window / dialog inspection

    enum WindowProbe { case present, missing, unknown }

    /// Three-state probe. AX messaging to QuickTime fails transiently while
    /// QuickTime is busy (kAXErrorCannotComplete) — treating that as
    /// "missing" caused pointless close/reopen churn, so AX errors map to
    /// `.unknown` ("don't touch anything this cycle").
    func probeRecordingWindow() -> WindowProbe {
        guard let appElement else { return .missing } // QuickTime not running
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement] else { return .unknown }
        return windows.contains(where: { title(of: $0) == Self.recordingWindowTitle }) ? .present : .missing
    }

    private var appElement: AXUIElement? {
        guard let pid = runningApp?.processIdentifier else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    private func axWindows() -> [AXUIElement] {
        guard let appElement else { return [] }
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let windows = value as? [AXUIElement] else {
            Self.log.error("axWindows failed: \(err.rawValue)")
            return []
        }
        return windows
    }

    private func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    func hasRecordingWindow() -> Bool {
        axWindows().contains { title(of: $0) == Self.recordingWindowTitle }
    }

    /// Slide the Movie Recording window just past the left edge of the whole
    /// desktop. Minimizing, hiding, or detaching it fully stops
    /// `SCContentFilter(desktopIndependentWindow:)`. An 8pt overlap keeps the
    /// backing store live; that sliver is all WindowServer still composites.
    func parkRecordingWindowMostlyOffscreen() {
        guard parkedOrigin == nil else { return }
        guard let placed = recordingWindowPlacement() else { return }
        let visible = onScreenWidth(placed.frame)
        if visible > 0, visible <= Self.parkedOverlap + 2 {
            parkedOrigin = rememberedOrigin() ?? placed.origin
            return
        }
        guard let parked = parkedPosition(current: placed.origin, size: placed.size),
              setPosition(placed.window, parked) else { return }
        let restorePoint = rememberedOrigin() ?? placed.origin
        parkedOrigin = restorePoint
        rememberOrigin(restorePoint)
        Self.log.info("parked Movie Recording window")
    }

    /// Put the window back where it was before parking. No-op until a park
    /// has saved an origin. Keeps the saved point if QuickTime is up but the
    /// recording window is not readable yet.
    func restoreRecordingWindow() {
        let origin = parkedOrigin ?? rememberedOrigin()
        guard let origin else { return }
        guard isRunning else {
            clearParkedOrigin()
            return
        }
        guard let window = recordingWindow() else { return }
        guard setPosition(window, origin) else { return }
        clearParkedOrigin()
        Self.log.info("restored Movie Recording window")
    }

    /// True when QuickTime is showing an error (alert sheet or dialog) —
    /// e.g. "Apple TV is not available". The caller's recovery path quits and
    /// reopens QuickTime in this state.
    func hasErrorDialog() -> Bool {
        for window in axWindows() {
            var sheets: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, "AXSheets" as CFString, &sheets) == .success,
               let list = sheets as? [AXUIElement], !list.isEmpty { return true }
            var subrole: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success,
               let s = subrole as? String,
               s == kAXSystemDialogSubrole || s == "AXDialog" { return true }
        }
        return false
    }

    // MARK: - Source selection

    /// Select `name` in the capture-source menu's "Screen" section. Verifies
    /// the checkmark landed; throws `sourceNotFound` when the Apple TV isn't
    /// listed (asleep/off-network) so the caller can back off instead of
    /// bouncing QuickTime in a loop.
    func selectScreenSource(named name: String) async throws {
        try ensureAccessibility()
        guard let window = axWindows().first(where: { title(of: $0) == Self.recordingWindowTitle }) else {
            throw QuickTimeError.noRecordingWindow
        }
        guard let button = findSourceButton(in: window) else { throw QuickTimeError.noSourceButton }

        press(button)
        // The menu materializes lazily after the press.
        var menu: AXUIElement?
        for _ in 0..<12 {
            try await Task.sleep(nanoseconds: 100_000_000)
            menu = firstChild(of: button, role: kAXMenuRole)
            if menu != nil { break }
        }
        guard let menu else { throw QuickTimeError.noSourceButton }

        defer { cancel(menu) }

        var inScreenSection = false
        var target: AXUIElement?
        for case let item as AXUIElement in children(of: menu) {
            guard role(of: item) == kAXMenuItemRole else { continue }
            let itemTitle = title(of: item) ?? ""
            if Self.menuSections.contains(itemTitle) {
                inScreenSection = itemTitle == "Screen"
                continue
            }
            guard inScreenSection, itemTitle == name else { continue }
            if markChar(of: item) != nil { cancel(menu); return } // already selected
            target = item
            break
        }
        guard let target else { throw QuickTimeError.sourceNotFound(name) }
        press(target) // menu closes itself
    }

    // MARK: - AX helpers

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return [] }
        return children
    }

    private func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func firstChild(of element: AXUIElement, role: String) -> AXUIElement? {
        children(of: element).first { self.role(of: $0) == role }
    }

    private func markChar(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXMenuItemMarkChar" as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// On-screen top-left (AX coordinates) captured before the window was parked.
    private var parkedOrigin: CGPoint?

    private struct WindowPlacement {
        let window: AXUIElement
        let origin: CGPoint
        let size: CGSize
        let frame: CGRect
    }

    private func recordingWindow() -> AXUIElement? {
        axWindows().first { title(of: $0) == Self.recordingWindowTitle }
    }

    private func recordingWindowPlacement() -> WindowPlacement? {
        guard let window = recordingWindow(),
              let origin = copyAXValue(window, kAXPositionAttribute, .cgPoint, CGPoint.zero),
              let size = copyAXValue(window, kAXSizeAttribute, .cgSize, CGSize.zero),
              let frame = appKitFrame(axOrigin: origin, size: size) else { return nil }
        return WindowPlacement(window: window, origin: origin, size: size, frame: frame)
    }

    /// AX positions are top-left, Y down. AppKit frames are bottom-left, Y up.
    /// Flip against the menu-bar screen (`NSScreen.screens` is ordered that way).
    private func appKitFrame(axOrigin: CGPoint, size: CGSize) -> CGRect? {
        guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1,
              axOrigin.x.isFinite, axOrigin.y.isFinite,
              let primary = NSScreen.screens.first else { return nil }
        let bottom = NSMaxY(primary.frame) - axOrigin.y - size.height
        return CGRect(x: axOrigin.x, y: bottom, width: size.width, height: size.height)
    }

    private func desktopBounds() -> CGRect? {
        let screens = NSScreen.screens
        guard let first = screens.first else { return nil }
        return screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }

    private func onScreenWidth(_ windowFrame: CGRect) -> CGFloat {
        NSScreen.screens.reduce(0) { total, screen in
            let hit = screen.frame.intersection(windowFrame)
            guard !hit.isNull, !hit.isEmpty else { return total }
            return total + hit.width
        }
    }

    /// Left of every display, so a neighbor screen cannot still show the window.
    private func parkedPosition(current: CGPoint, size: CGSize) -> CGPoint? {
        guard let desktop = desktopBounds() else { return nil }
        return CGPoint(x: desktop.minX - size.width + Self.parkedOverlap, y: current.y)
    }

    private func copyAXValue<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType, _ initial: T) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var decoded = initial
        guard AXValueGetValue(raw as! AXValue, type, &decoded) else { return nil }
        return decoded
    }

    private func setPosition(_ element: AXUIElement, _ point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        let err = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        if err != .success {
            Self.log.error("set position failed: \(err.rawValue)")
            return false
        }
        return true
    }

    private func rememberOrigin(_ point: CGPoint) {
        UserDefaults.standard.set("\(point.x) \(point.y)", forKey: Self.parkedOriginKey)
    }

    private func rememberedOrigin() -> CGPoint? {
        guard let text = UserDefaults.standard.string(forKey: Self.parkedOriginKey) else { return nil }
        let parts = text.split(separator: " ")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]),
              x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func clearParkedOrigin() {
        parkedOrigin = nil
        UserDefaults.standard.removeObject(forKey: Self.parkedOriginKey)
    }

    private func press(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    private func cancel(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXCancelAction as CFString)
    }

    /// Depth-first search for the chevron button that opens the capture
    /// device selection menu (identified by its AX description).
    private func findSourceButton(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 8 else { return nil }
        if role(of: element) == kAXButtonRole {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &value) == .success,
               (value as? String) == "show capture device selection menu" {
                return element
            }
        }
        for child in children(of: element) {
            if let found = findSourceButton(in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}
