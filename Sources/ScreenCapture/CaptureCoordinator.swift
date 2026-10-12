import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CoreImage
import Foundation
import OSLog
import ScreenCaptureKit

/// Drives the ScreenCaptureKit pipeline that mirrors QuickTime Player's
/// wireless Apple TV window into the app: a full-rate preview on an
/// `AVSampleBufferDisplayLayer`, one-shot PNG screenshots, and MP4 recordings
/// — all derived from the same `SCStream`.
///
/// A hidden, minimized, or occluded app window stops preview enqueue and,
/// unless a recording is in progress, drops the same stream to 2 fps. The
/// stream is not stopped or restarted; showing the window restores the
/// original 30 fps configuration.
///
/// The Apple TV is invisible to public capture APIs, but the QuickTime window
/// that displays it isn't; grabbing that window is our only realistic path.
@MainActor
final class CaptureCoordinator: NSObject, ObservableObject {

    // MARK: - Published state (consumed by ContentView)

    @Published private(set) var permissionGranted: Bool = false
    @Published private(set) var quicktimeWindow: DetectedWindow?
    @Published private(set) var isStreaming: Bool = false
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published private(set) var recordingFileSize: UInt64 = 0
    @Published private(set) var lastCaptureURL: URL?
    @Published private(set) var lastError: String?
    /// Name of the Apple TV the app is connected to. When set, the
    /// coordinator owns the QuickTime lifecycle: it opens the Movie
    /// Recording window, selects this device as the source, and restarts
    /// QuickTime when the feed errors out.
    @Published private(set) var activeDeviceName: String?

    struct DetectedWindow: Equatable {
        let windowID: CGWindowID
        let title: String
        let pixelSize: CGSize
    }

    // MARK: - Internals

    private let sampleQueue = DispatchQueue(label: "capture.samples", qos: .userInitiated)
    private var stream: SCStream?
    /// The configuration object passed to the running stream. Hidden-window
    /// throttling changes only `minimumFrameInterval` on this instance.
    private var streamConfig: SCStreamConfiguration?
    /// Not published. Frames go straight to the display layer; publishing the
    /// adapter or each frame would redraw ContentView at the capture rate.
    private(set) var streamOutput: StreamOutputAdapter?
    private var recorder: VideoRecorder?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?

    // MARK: - QuickTime automation state

    private let qt = QuickTimeController()
    static let log = Logger(subsystem: "app.appletvremote", category: "capture")
    /// Source we last selected in QuickTime's menu — avoids reopening the
    /// menu (visible flicker) when it's already right.
    private var lastSelectedSource: String?
    /// After a sourceNotFound, wait this long before re-reading the menu.
    private var nextSourceAttempt = Date.distantPast
    /// Consecutive QuickTime restarts; capped at 2, then the coordinator
    /// gives up until the device changes or the user hits refresh. Reset on
    /// the first healthy frame.
    private var recoveryAttempts = 0
    private var gaveUp = false
    /// Consecutive polls reporting the recording window missing — opening
    /// QuickTime only happens after 2 confirmations, so a transient AX
    /// hiccup never triggers a close/reopen cycle.
    private var windowMissingPolls = 0
    /// Consecutive openMovieRecording failures — capped at 2, then give up
    /// (WITHOUT quitting QuickTime; a launch-in-progress AX hiccup is not a
    /// reason to close the user's window).
    private var openFailures = 0
    /// Set once the app window has been brought to focus for the current
    /// healthy feed; reset when the stream drops or the device changes so a
    /// reconnect re-focuses.
    private var didFocusOnConnect = false
    /// When the current stream started — frames must arrive within a grace
    /// period or the attempt counts as failed (static screens legitimately
    /// produce no NEW frames, so staleness after the first frame is fine).
    private var streamStartedAt: Date?

    // MARK: - Preview visibility

    /// Original capture rate. Restored verbatim when the window is shown or
    /// a recording needs frames; width, height, and pixel format stay put.
    private static let liveFrameInterval = CMTime(value: 1, timescale: 30)
    /// 2 fps. Keeps the stream alive (and `lastFrameAt` moving) while the
    /// preview is not on screen, without a stop/restart cycle.
    private static let hiddenFrameInterval = CMTime(value: 1, timescale: 2)
    private static let perfLog = Logger(subsystem: "com.mahmoudelgendy.AppleTVRemote", category: "perf")

    private var previewObservers: [NSObjectProtocol] = []
    private weak var previewWindow: NSWindow?
    /// Visible means not miniaturized, not app-hidden, and at least partly
    /// on screen. Unknown until a window exists — treated as visible so we
    /// don't throttle the stream before the UI is up.
    private var previewVisible = true
    private var previewThrottled = false
    private var loggedPreviewVisible = true
    private var loggedPreviewThrottled = false
    /// Set for the whole recording-start attempt. Otherwise a hide that
    /// lands while `isRecording` is still false would pin the file at 2 fps.
    private var recordingNeedsFullRate = false
    private var previewDeliveryChain: Task<Void, Never>?

    // MARK: - Lifecycle

    override init() {
        super.init()
        permissionGranted = CGPreflightScreenCaptureAccess()
        qt.restoreRecordingWindow()
        observePreviewVisibility()
    }

    deinit {
        let center = NotificationCenter.default
        for token in previewObservers {
            center.removeObserver(token)
        }
    }

    /// Trigger the system prompt if we haven't been granted permission yet.
    /// Returns true only after the user actually grants access.
    @discardableResult
    func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            permissionGranted = true
            return true
        }
        // This call prompts on first launch and returns immediately; the user
        // grants in System Settings and must restart the app for it to stick.
        _ = CGRequestScreenCaptureAccess()
        permissionGranted = CGPreflightScreenCaptureAccess()
        return permissionGranted
    }

    /// Find the best QuickTime window that looks like an Apple TV capture and
    /// start streaming from it. No-op if already streaming from the right one.
    func startIfPossible() async {
        guard permissionGranted else {
            Self.log.info("poll: screen-capture permission missing")
            return
        }
        if let deviceName = activeDeviceName, !deviceName.isEmpty {
            await startManaged(deviceName: deviceName)
        } else {
            Self.log.info("poll: unmanaged (no active device)")
            await startUnmanaged()
        }
    }

    /// Last state summary logged — poll logs only on CHANGE to stay quiet
    /// in steady state while still explaining what it's (not) doing.
    private var lastPollNote = ""

    fileprivate func pollNote(_ note: String) {
        guard note != lastPollNote else { return }
        lastPollNote = note
        Self.log.info("poll: \(note, privacy: .public)")
    }

    /// Called when the backend connection changes: the screen must follow
    /// the selected Apple TV. Resets recovery state so a device switch gets
    /// a fresh set of attempts.
    /// Called when the backend connection changes: the screen must follow
    /// the selected Apple TV. A transition to nil means the connection was
    /// lost — close QuickTime so the reconnect gets a completely fresh
    /// screen-share session instead of a stale one.
    func setActiveDevice(name: String?) {
        guard name != activeDeviceName else { return }
        let wasConnected = activeDeviceName != nil
        activeDeviceName = name
        lastSelectedSource = nil
        nextSourceAttempt = .distantPast
        recoveryAttempts = 0
        openFailures = 0
        gaveUp = false
        if name == nil && wasConnected {
            Self.log.info("connection lost — closing QuickTime")
            qt.quit()
            quicktimeWindow = nil
            Task { await stopStream() }
        } else {
            Task { await startIfPossible() }
        }
    }

    /// Refresh-button action: resets the give-up flag and re-checks the
    /// feed; the managed flow reopens/restarts only what's actually broken.
    func refreshAndRecover() async {
        recoveryAttempts = 0
        openFailures = 0
        gaveUp = false
        await startIfPossible()
    }

    /// Legacy behavior when no device is connected: capture whatever
    /// QuickTime window exists (manual QuickTime usage still works).
    private func startUnmanaged() async {
        do {
            guard let window = try await findQuickTimeCaptureWindow() else {
                quicktimeWindow = nil
                await stopStream()
                return
            }
            if let current = quicktimeWindow,
               current.windowID == window.windowID,
               isStreaming {
                if (streamOutput?.frameCount ?? 0) > 0 {
                    qt.parkRecordingWindowMostlyOffscreen()
                }
                return
            }
            Self.log.info("unmanaged: starting stream for window \(window.windowID)")
            quicktimeWindow = DetectedWindow(
                windowID: window.windowID,
                title: window.title ?? "QuickTime",
                pixelSize: CGSize(width: window.frame.width, height: window.frame.height)
            )
            try await startStream(for: window)
        } catch {
            lastError = "Capture setup failed: \(error.localizedDescription)"
            await stopStream()
        }
    }

    /// Connected-device flow: the app owns QuickTime. Opens the Movie
    /// Recording window, selects the connected Apple TV as the source, and
    /// restarts QuickTime when the feed errors or never delivers frames.
    private func startManaged(deviceName: String) async {
        if gaveUp { return }
        do {
            // Already healthy? Leave QuickTime completely alone.
            if isStreaming, (streamOutput?.frameCount ?? 0) > 0 {
                pollNote("healthy")
                recoveryAttempts = 0
                if lastError != nil { lastError = nil }
                // Frames are flowing, so the desktop-independent filter is
                // live. Park after that — moving sooner would make a frozen
                // feed look like QuickTime never connected.
                qt.parkRecordingWindowMostlyOffscreen()
                // The screen just came up — bring the remote forward so the
                // user sees it (once per connect, not every poll).
                if !didFocusOnConnect {
                    didFocusOnConnect = true
                    Self.log.info("screen connected — focusing app window")
                    NSApp.activate(ignoringOtherApps: true)
                    let win = NSApp.mainWindow ?? NSApp.windows.first
                    win?.makeKeyAndOrderFront(nil)
                    // Stays visible even if another app grabs focus right after.
                    win?.orderFrontRegardless()
                }
                return
            }
            if qt.hasErrorDialog() {
                await recoverQuickTime(reason: "QuickTime reported an error")
                return
            }
            // Probe before acting: AX hiccups (`.unknown`) must not trigger
            // open/close; only a window confirmed missing twice does.
            switch qt.probeRecordingWindow() {
            case .unknown:
                pollNote("QuickTime probe failed (AX busy) — waiting")
                return
            case .present:
                windowMissingPolls = 0
                openFailures = 0
            case .missing:
                pollNote("recording window missing (\(self.windowMissingPolls + 1))")
                windowMissingPolls += 1
                guard windowMissingPolls >= 2 else { return }
                windowMissingPolls = 0
                Self.log.info("opening QuickTime movie recording for \(deviceName, privacy: .public)")
                do {
                    try await qt.openMovieRecording()
                    openFailures = 0
                } catch {
                    // Opening can fail while QuickTime is still launching —
                    // DON'T quit it (that's the open/close churn). Count
                    // failures and give up after 2, leaving QuickTime alone.
                    openFailures += 1
                    Self.log.error("open failed (\(self.openFailures)/2): \(error.localizedDescription, privacy: .public)")
                    if openFailures >= 2 {
                        gaveUp = true
                        lastError = "Couldn't open the Apple TV screen (\(error.localizedDescription)). Press ↻ to try again."
                    } else {
                        lastError = "Opening QuickTime failed — retrying…"
                    }
                    return
                }
            }
            guard let window = try await findQuickTimeCaptureWindow() else {
                Self.log.info("no QuickTime capture window yet")
                quicktimeWindow = nil
                await stopStream()
                return
            }
            // Check what's currently selected (the menu reports the
            // checkmark) and only press anything when it's the wrong device.
            if lastSelectedSource != deviceName, Date() >= nextSourceAttempt {
                nextSourceAttempt = Date().addingTimeInterval(30)
                do {
                    try await qt.selectScreenSource(named: deviceName)
                    Self.log.info("selected source \(deviceName, privacy: .public)")
                    lastSelectedSource = deviceName
                } catch QuickTimeController.QuickTimeError.sourceNotFound {
                    // TV not in the menu (asleep/off-network) — retry after
                    // the cooldown, but never bounce QuickTime for this.
                    Self.log.info("source \(deviceName, privacy: .public) not in QuickTime menu yet")
                    lastError = QuickTimeController.QuickTimeError.sourceNotFound(deviceName).errorDescription
                }
            }
            if !(quicktimeWindow?.windowID == window.windowID && isStreaming) {
                quicktimeWindow = DetectedWindow(
                    windowID: window.windowID,
                    title: window.title ?? "QuickTime",
                    pixelSize: CGSize(width: window.frame.width, height: window.frame.height)
                )
                Self.log.info("starting stream for window \(window.windowID)")
                try await startStream(for: window)
            }
            // Health: a fresh stream must deliver a first frame within 15s.
            // After that, no new frames just means a static screen.
            if isStreaming, let started = streamStartedAt,
               Date().timeIntervalSince(started) > 15,
               (streamOutput?.frameCount ?? 0) == 0 {
                await recoverQuickTime(reason: "no video from QuickTime")
                return
            }
            // Freeze: the feed WAS delivering frames and then went silent
            // for 45s (share session died, TV slept). Close QuickTime so the
            // next poll opens a fresh session — a static-but-alive screen
            // still emits frames from focus glow/screensaver, so 45s of
            // total silence means the feed is dead.
            // The hidden-window throttle is 2 fps, so lastFrameAt still
            // advances about twice a second. 45s is far above that cadence
            // and does not treat the throttle as a freeze.
            if isStreaming, let lastFrame = streamOutput?.lastFrameAt,
               Date().timeIntervalSince(lastFrame) > 45 {
                Self.log.info("feed frozen — closing QuickTime for a fresh start")
                lastSelectedSource = nil
                qt.quit()
                await stopStream()
                return
            }
        } catch {
            Self.log.error("managed capture failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            await stopStream()
        }
    }

    /// Recovery: close QuickTime and let the next poll reopen it — but only
    /// 2 attempts per device/refresh, then stop and wait for the user.
    private func recoverQuickTime(reason: String) async {
        recoveryAttempts += 1
        Self.log.info("recovering QuickTime (attempt \(self.recoveryAttempts)/2): \(reason, privacy: .public)")
        lastSelectedSource = nil
        if recoveryAttempts >= 2 {
            gaveUp = true
            lastError = "Couldn't get the Apple TV screen (\(reason)). Press ↻ to try again."
        } else {
            lastError = "Restarting QuickTime (\(reason))…"
        }
        qt.quit()
        await stopStream()
    }

    func stop() async {
        if isRecording { _ = await stopRecording() }
        await stopStream()
        quicktimeWindow = nil
    }

    /// Called on stream stop and on quit. Safe to call more than once.
    func restoreParkedQuickTimeWindow() {
        qt.restoreRecordingWindow()
    }

    // MARK: - Screenshot

    /// Convert the latest received frame to a PNG on disk. Returns nil (with
    /// `lastError` populated) if no frame is available yet.
    func captureScreenshot() async -> URL? {
        guard let pixelBuffer = streamOutput?.snapshotLatestPixelBuffer() else {
            lastError = "No frame available yet — is QuickTime showing the Apple TV?"
            return nil
        }
        do {
            let dir = try CaptureStorage.captureDirectory()
            let url = dir.appendingPathComponent(CaptureStorage.filename(kind: "screenshot", ext: "png"))
            // PNG encode + CI render off the main actor.
            try await Task.detached(priority: .userInitiated) {
                try Self.writePNG(pixelBuffer: pixelBuffer, to: url)
            }.value
            lastCaptureURL = url
            return url
        } catch {
            lastError = "Screenshot save failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Recording

    func startRecording() async {
        guard isStreaming, !isRecording else { return }
        // Full rate before the writer is attached. A hidden window must not
        // leave the recording on the 2 fps throttle.
        recordingNeedsFullRate = true
        await applyPreviewDelivery()
        guard !previewThrottled else {
            recordingNeedsFullRate = false
            lastError = "Couldn't restore full frame rate for recording."
            return
        }
        guard let size = streamOutput?.currentPixelSize else {
            lastError = "Recording needs at least one frame first."
            await endFullRateHold()
            return
        }
        do {
            let dir = try CaptureStorage.captureDirectory()
            let url = dir.appendingPathComponent(CaptureStorage.filename(kind: "recording", ext: "mp4"))
            let recorder = try VideoRecorder(url: url, pixelSize: size)
            self.recorder = recorder
            streamOutput?.recorder = recorder
            isRecording = true
            recordingNeedsFullRate = false
            recordingElapsed = 0
            recordingFileSize = 0
            startRecordingTimer()
            // Must be set AFTER startRecordingTimer(): that helper calls
            // stopRecordingTimer() first, which clears recordingStartedAt —
            // setting it before left the elapsed timer stuck at 0.
            recordingStartedAt = Date()
        } catch {
            lastError = "Recording start failed: \(error.localizedDescription)"
            await endFullRateHold()
        }
    }

    @discardableResult
    func stopRecording() async -> URL? {
        guard isRecording, let recorder else { return nil }
        streamOutput?.recorder = nil
        stopRecordingTimer()
        isRecording = false
        let url: URL?
        do {
            url = try await recorder.finish()
            self.recorder = nil
            lastCaptureURL = url
        } catch {
            lastError = "Recording finalize failed: \(error.localizedDescription)"
            self.recorder = nil
            url = nil
        }
        // Window still hidden → back to 2 fps. A visible window stays at
        // the original configuration.
        await applyPreviewDelivery()
        return url
    }

    // MARK: - Stream management

    private func startStream(for window: SCWindow) async throws {
        await stopStream()

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelWidth  = max(Int(window.frame.width  * scale), 640)
        let pixelHeight = max(Int(window.frame.height * scale), 360)

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = Self.liveFrameInterval
        config.showsCursor = false
        config.queueDepth = 5

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = StreamOutputAdapter(pixelSize: CGSize(width: pixelWidth, height: pixelHeight))
        if !previewVisible {
            output.setEnqueuesPreview(false)
        }
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()

        self.stream = stream
        self.streamConfig = config
        self.streamOutput = output
        self.previewThrottled = false
        self.streamStartedAt = Date()
        self.isStreaming = true
        await applyPreviewDelivery()
    }

    private func stopStream() async {
        isStreaming = false
        streamStartedAt = nil
        didFocusOnConnect = false
        restoreParkedQuickTimeWindow()
        if isRecording { _ = await stopRecording() }
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamConfig = nil
        streamOutput = nil
        // Next startStream builds a fresh 30 fps config. Don't leave the
        // flag set or the new stream would skip its first throttle update.
        previewThrottled = false
    }

    // MARK: - Preview visibility

    private func observePreviewVisibility() {
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ]
        let center = NotificationCenter.default
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.previewVisibilityChanged(note)
                }
            }
            previewObservers.append(token)
        }
    }

    private func previewVisibilityChanged(_ note: Notification) {
        if let window = note.object as? NSWindow {
            guard adoptPreviewWindow(window) else { return }
        }
        if previewWindow == nil {
            previewWindow = NSApp.mainWindow
        }
        let visible = currentPreviewVisibility()
        guard visible != previewVisible else { return }
        previewVisible = visible
        Task { await applyPreviewDelivery() }
    }

    /// Latches the app's content window. Later notifications from sheets
    /// or panels must not retarget it.
    private func adoptPreviewWindow(_ window: NSWindow) -> Bool {
        if let previewWindow {
            return window === previewWindow
        }
        if window.isSheet || !window.canBecomeMain { return false }
        if let main = NSApp.mainWindow, window !== main { return false }
        previewWindow = window
        return true
    }

    private func currentPreviewVisibility() -> Bool {
        if NSApp.isHidden { return false }
        guard let window = previewWindow else { return true }
        return !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    private func endFullRateHold() async {
        recordingNeedsFullRate = false
        await applyPreviewDelivery()
    }

    /// Serializes interval updates. Visibility notifications, recording
    /// start/stop, and stream start can overlap across awaits.
    private func applyPreviewDelivery() async {
        let previous = previewDeliveryChain
        let next = Task { @MainActor in
            await previous?.value
            await self.deliverPreviewPolicy()
        }
        previewDeliveryChain = next
        await next.value
    }

    private func deliverPreviewPolicy() async {
        let visible = previewVisible
        streamOutput?.setEnqueuesPreview(visible)
        guard isStreaming, let stream, let streamConfig else {
            logPreviewDeliveryIfChanged()
            return
        }
        let throttle = !visible && !isRecording && !recordingNeedsFullRate
        guard throttle != previewThrottled else {
            logPreviewDeliveryIfChanged()
            return
        }
        // Same configuration object the stream was started with. Only the
        // frame interval changes; width, height, and pixel format stay.
        streamConfig.minimumFrameInterval = throttle ? Self.hiddenFrameInterval : Self.liveFrameInterval
        do {
            try await stream.updateConfiguration(streamConfig)
        } catch {
            Self.log.error("preview frame interval update failed: \(error.localizedDescription, privacy: .public)")
            logPreviewDeliveryIfChanged()
            return
        }
        guard self.stream === stream else { return }
        previewThrottled = throttle
        logPreviewDeliveryIfChanged()
    }

    private func logPreviewDeliveryIfChanged() {
        guard loggedPreviewVisible != previewVisible || loggedPreviewThrottled != previewThrottled else { return }
        loggedPreviewVisible = previewVisible
        loggedPreviewThrottled = previewThrottled
        let visible = previewVisible ? "true" : "false"
        let throttled = previewThrottled ? "true" : "false"
        Self.perfLog.notice("preview visible=\(visible, privacy: .public) throttled=\(throttled, privacy: .public)")
    }

    // MARK: - Discovery

    /// The QuickTime "Movie Recording" window is the largest window owned by
    /// QuickTime Player that isn't a toolbar or inspector. We prefer a window
    /// actually titled "Movie Recording" (so a stray movie-playback window
    /// isn't grabbed), then fall back to the largest plausible candidate.
    private func findQuickTimeCaptureWindow() async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let qtWindows = content.windows.filter { w in
            guard let bundle = w.owningApplication?.bundleIdentifier else { return false }
            return bundle == "com.apple.QuickTimePlayerX"
        }
        // Prefer sensibly-sized recording windows (16:9 area heuristic)
        // over floating palettes/inspectors that QuickTime spawns.
        let candidates = qtWindows.filter { $0.frame.width >= 320 && $0.frame.height >= 180 }
        if let recording = candidates.first(where: { $0.title == "Movie Recording" }) {
            return recording
        }
        return candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }

    // MARK: - Recording timer

    private func startRecordingTimer() {
        stopRecordingTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartedAt else { return }
                self.recordingElapsed = Date().timeIntervalSince(start)
                if let url = self.recorder?.outputURL,
                   let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = (attrs[.size] as? NSNumber)?.uint64Value {
                    self.recordingFileSize = size
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartedAt = nil
    }

    // MARK: - PNG encoding

    private static nonisolated func writePNG(pixelBuffer: CVPixelBuffer, to url: URL) throws {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        // One-shot context — this runs on a background thread (Task.detached).
        guard let cg = CIContext(options: [.useSoftwareRenderer: false])
            .createCGImage(ciImage, from: ciImage.extent) else {
            throw NSError(domain: "CaptureCoordinator", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to render frame"])
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CaptureCoordinator", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
        }
        try data.write(to: url)
    }
}

// MARK: - SCStreamDelegate

extension CaptureCoordinator: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Don't let a recording dangle after the stream dies.
            if self.isRecording { _ = await self.stopRecording() }
            self.isStreaming = false
            self.lastError = "Stream stopped: \(error.localizedDescription)"
        }
    }
}

// MARK: - Stream output adapter (background queue → coordinator)

/// Splits incoming sample buffers into the live preview layer and the
/// recorder. Retains only the latest pixel buffer for screenshots.
/// The display layer is not published; SwiftUI never sees individual frames.
/// Preview enqueue pauses while the app window is not visible; frame
/// accounting, the screenshot buffer, and the recorder do not.
final class StreamOutputAdapter: NSObject, SCStreamOutput {
    private(set) var currentPixelSize: CGSize
    private var latestPixelBuffer: CVPixelBuffer?
    private let lock = NSLock()
    private weak var previewLayer: AVSampleBufferDisplayLayer?
    private var enqueuesPreview = true

    /// Written on the main actor, read on the sample queue — guarded by `lock`.
    private var _recorder: VideoRecorder?
    var recorder: VideoRecorder? {
        get { lock.lock(); defer { lock.unlock() }; return _recorder }
        set { lock.lock(); _recorder = newValue; lock.unlock() }
    }

    /// Main-thread only. The sample queue reads the layer under `lock`.
    func attachPreviewLayer(_ layer: AVSampleBufferDisplayLayer?) {
        lock.lock()
        previewLayer = layer
        lock.unlock()
    }

    /// Main thread. Turning enqueue back on flushes first so a renderer that
    /// failed while frames were dropped doesn't stay stuck.
    func setEnqueuesPreview(_ enabled: Bool) {
        lock.lock()
        let turningOn = enabled && !enqueuesPreview
        let layer = previewLayer
        if !enabled {
            enqueuesPreview = false
        }
        lock.unlock()
        guard turningOn else { return }
        layer?.sampleBufferRenderer.flush()
        lock.lock()
        enqueuesPreview = true
        lock.unlock()
    }

    init(pixelSize: CGSize) {
        self.currentPixelSize = pixelSize
    }

    /// Thread-safe copy of the most recent buffer for one-shot screenshots.
    func snapshotLatestPixelBuffer() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latestPixelBuffer
    }

    /// Total complete frames received since this adapter was created (i.e.
    /// since the current stream started). Zero after a grace period means the
    /// capture attempt failed — a static screen later on is NOT a failure.
    var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _frameCount
    }
    private var _frameCount = 0
    private var perfIntervalStart = Date()
    private var perfIntervalStartCount = 0
    private static let perfLog = Logger(subsystem: "com.mahmoudelgendy.AppleTVRemote", category: "perf")

    /// When the most recent complete frame arrived. A feed that delivered
    /// frames and then goes silent for a long stretch is frozen (share
    /// session died, TV slept) — the coordinator restarts QuickTime then.
    var lastFrameAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return _lastFrameAt
    }
    private var _lastFrameAt: Date?

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              let statusRaw = first[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock()
        latestPixelBuffer = pixelBuffer
        _frameCount += 1
        _lastFrameAt = Date()
        let layer = enqueuesPreview ? previewLayer : nil
        let perfDue = Date().timeIntervalSince(perfIntervalStart) >= 10
        let framesInInterval: Int
        if perfDue {
            framesInInterval = _frameCount - perfIntervalStartCount
            perfIntervalStartCount = _frameCount
            perfIntervalStart = Date()
        } else {
            framesInInterval = 0
        }
        lock.unlock()
        if perfDue {
            Self.perfLog.notice("frames \(framesInInterval, privacy: .public) in 10s")
        }

        // Recorder sees the original ScreenCaptureKit buffer, unmodified.
        recorder?.append(sampleBuffer: sampleBuffer)
        enqueuePreview(sampleBuffer, on: layer)
    }

    /// The renderer retains the sample buffer and composites its IOSurface;
    /// no CPU readback. A nil layer is the suspended preview — nothing is
    /// enqueued, and the caller has already counted the frame.
    private func enqueuePreview(_ sampleBuffer: CMSampleBuffer, on layer: AVSampleBufferDisplayLayer?) {
        guard let layer else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)
    }
}

// MARK: - File layout

enum CaptureStorage {
    static func captureDirectory() throws -> URL {
        let downloads = try FileManager.default.url(
            for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let dir = downloads.appendingPathComponent("AppleTV Captures", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func filename(kind: String, ext: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "\(kind)-\(f.string(from: Date())).\(ext)"
    }
}
