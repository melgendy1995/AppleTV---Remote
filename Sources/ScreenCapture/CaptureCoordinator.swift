import AppKit
import AVFoundation
import Combine
import CoreImage
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import OSLog

/// Mirrors the Apple TV by opening its CMIO screen-capture device with
/// `AVCaptureSession`. QuickTime is not launched and ScreenCaptureKit is not
/// used. The same sample buffers feed the `AVSampleBufferDisplayLayer`
/// preview, PNG screenshots, and the MP4 recorder.
///
/// The device delivers about 60 fps. `VideoRecorder` timestamps each buffer
/// and drops frames when the writer is not ready, so the session keeps that
/// native rate. There is no 30 fps cap.
///
/// A hidden, minimized, or occluded window stops preview enqueue. Unless a
/// recording is in progress, delivery also drops to 2 fps via
/// `activeVideoMinFrameDuration` when that rate is in the active format's
/// supported ranges. If the device refuses the cap, the sample delegate
/// keeps frame timing and skips preview, screenshot, and recorder work.
/// Recording always restores the native duration first and is never throttled.
@MainActor
final class CaptureCoordinator: NSObject, ObservableObject {

    // MARK: - Published state (consumed by ContentView)

    @Published private(set) var permissionGranted: Bool = false
    /// `localizedName` of the capture device the session is aimed at.
    @Published private(set) var captureDeviceName: String?
    @Published private(set) var isStreaming: Bool = false
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published private(set) var recordingFileSize: UInt64 = 0
    @Published private(set) var lastCaptureURL: URL?
    @Published private(set) var lastError: String?
    /// Name of the Apple TV the app is connected to. Used to prefer a
    /// capture device whose localized name matches.
    @Published private(set) var activeDeviceName: String?

    // MARK: - Internals

    private let sampleQueue = DispatchQueue(label: "capture.samples", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "capture.session", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var captureDevice: AVCaptureDevice?
    private var currentDeviceID: String?
    /// Not published. Frames go straight to the display layer; publishing the
    /// adapter or each frame would redraw ContentView at the capture rate.
    private(set) var streamOutput: StreamOutputAdapter?
    private var recorder: VideoRecorder?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?

    private let discovery: AVCaptureDevice.DiscoverySession
    static let log = Logger(subsystem: "app.appletvremote", category: "capture")
    /// Set once the app window has been brought forward for the current
    /// healthy feed. Reset when the session stops or the device changes.
    private var didFocusOnConnect = false
    /// When the current session started. The device takes a few seconds to
    /// deliver the first frame; silence inside that window is not a failure.
    private var streamStartedAt: Date?
    /// Don't tight-loop session restarts when start fails or the feed is dead.
    private var nextSessionAttempt = Date.distantPast
    private var sessionWork: Task<Void, Never>?
    private var lastPollNote = ""

    // MARK: - Preview visibility

    /// 2 fps while the preview is off screen and nothing is recording.
    /// Far below the 45s silence restart, so the cap is not treated as a stall.
    private static let hiddenFrameInterval = CMTime(value: 1, timescale: 2)
    private static let perfLog = Logger(subsystem: "com.mahmoudelgendy.AppleTVRemote", category: "perf")

    private var lifetimeObservers: [NSObjectProtocol] = []
    private weak var previewWindow: NSWindow?
    /// Visible means not miniaturized, not app-hidden, and at least partly
    /// on screen. Unknown until a window exists — treated as visible so we
    /// don't throttle before the UI is up.
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
        Self.enableCMIOCaptureDevices()
        discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: nil,
            position: .unspecified
        )
        super.init()
        permissionGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        observeCaptureDevices()
        observeSessionFailures()
        observePreviewVisibility()
    }

    deinit {
        let center = NotificationCenter.default
        for token in lifetimeObservers {
            center.removeObserver(token)
        }
    }

    /// Prompt for camera access when the system hasn't decided yet.
    /// Returns true only when access is already granted.
    @discardableResult
    func ensurePermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionGranted = true
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.permissionGranted = granted
                    if granted { await self.startIfPossible() }
                }
            }
            return false
        default:
            permissionGranted = false
            return false
        }
    }

    /// Open the best Apple TV capture device, or leave an already-healthy
    /// session alone. Safe to call on a timer.
    func startIfPossible() async {
        await performSessionWork {
            await self.startIfPossibleNow()
        }
    }

    /// Called when the backend connection changes. A different Apple TV
    /// retargets the capture device; disconnect leaves the feed up when the
    /// same CMIO device is still the best match.
    func setActiveDevice(name: String?) {
        guard name != activeDeviceName else { return }
        activeDeviceName = name
        didFocusOnConnect = false
        Task { await startIfPossible() }
    }

    /// Refresh-button action. Restarts the capture session even if the same
    /// device is already open.
    func refreshAndRecover() async {
        await performSessionWork {
            self.nextSessionAttempt = .distantPast
            await self.stopStream()
            await self.startIfPossibleNow()
        }
    }

    func stop() async {
        await performSessionWork {
            if self.isRecording { _ = await self.stopRecording() }
            await self.stopStream()
            self.captureDeviceName = nil
        }
    }

    // MARK: - Screenshot

    /// Convert the latest received frame to a PNG on disk. Returns nil (with
    /// `lastError` populated) if no frame is available yet.
    func captureScreenshot() async -> URL? {
        guard let pixelBuffer = streamOutput?.snapshotLatestPixelBuffer() else {
            lastError = "No frame available yet — is the Apple TV screen connected?"
            return nil
        }
        do {
            let dir = try CaptureStorage.captureDirectory()
            let url = dir.appendingPathComponent(CaptureStorage.filename(kind: "screenshot", ext: "png"))
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
        // Native rate before the writer is attached. A hidden window must
        // not leave the recording on the 2 fps cap.
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
        // Window still hidden → back to 2 fps (or delegate skipping).
        // A visible window stays at the device's native rate.
        await applyPreviewDelivery()
        return url
    }

    // MARK: - Session

    private func performSessionWork(_ work: @escaping @MainActor () async -> Void) async {
        let previous = sessionWork
        let next = Task { @MainActor in
            await previous?.value
            await work()
        }
        sessionWork = next
        await next.value
    }

    private func startIfPossibleNow() async {
        guard permissionGranted else {
            pollNote("camera permission missing")
            return
        }
        guard let device = bestCaptureDevice() else {
            pollNote("no Apple TV capture device (\(self.discovery.devices.count) external)")
            captureDeviceName = nil
            if isStreaming { await stopStream() }
            return
        }
        if isStreaming, currentDeviceID == device.uniqueID, session?.isRunning == true {
            await maintainRunningSession(device: device)
            return
        }
        await reopen(device: device)
    }

    private func maintainRunningSession(device: AVCaptureDevice) async {
        let frames = streamOutput?.frameCount ?? 0
        if frames > 0 {
            if lastError != nil { lastError = nil }
            focusAppWindowIfNeeded()
            if let last = streamOutput?.lastFrameAt, Date().timeIntervalSince(last) > 45 {
                Self.log.info("feed silent — restarting capture session")
                await reopen(device: device)
            } else {
                pollNote("healthy")
            }
            return
        }
        guard let started = streamStartedAt, Date().timeIntervalSince(started) > 15 else {
            pollNote("waiting for first frame from \(device.localizedName)")
            return
        }
        pollNote("no frames — restarting")
        await reopen(device: device)
    }

    private func reopen(device: AVCaptureDevice) async {
        guard Date() >= nextSessionAttempt else { return }
        nextSessionAttempt = Date().addingTimeInterval(2)
        do {
            try await openSession(device: device)
            lastError = nil
        } catch {
            Self.log.error("capture start failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            await stopStream()
        }
    }

    private func openSession(device: AVCaptureDevice) async throws {
        captureDeviceName = device.localizedName
        await stopStream()
        captureDeviceName = device.localizedName

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA),
        ]
        let adapter = StreamOutputAdapter()
        if !previewVisible {
            adapter.setEnqueuesPreview(false)
        }
        output.setSampleBufferDelegate(adapter, queue: sampleQueue)

        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw Self.captureError("Can't open the Apple TV capture device.", code: 3)
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw Self.captureError("Can't read video from the Apple TV capture device.", code: 4)
        }
        session.addOutput(output)
        Self.lockLargestVideoFormat(device)
        session.commitConfiguration()

        let running = await runOnSessionQueue { () -> Bool in
            session.startRunning()
            return session.isRunning
        }
        guard running else {
            throw Self.captureError("Capture session did not start.", code: 5)
        }

        self.session = session
        self.videoOutput = output
        self.captureDevice = device
        self.currentDeviceID = device.uniqueID
        self.streamOutput = adapter
        self.streamStartedAt = Date()
        self.previewThrottled = false
        self.isStreaming = true
        Self.log.info("capture started \(device.localizedName, privacy: .public) model=\(device.modelID, privacy: .public)")
        await applyPreviewDelivery()
    }

    private func stopStream() async {
        let session = self.session
        let output = videoOutput
        isStreaming = false
        streamStartedAt = nil
        didFocusOnConnect = false
        previewThrottled = false
        self.session = nil
        self.videoOutput = nil
        self.captureDevice = nil
        currentDeviceID = nil
        if isRecording { _ = await stopRecording() }
        streamOutput = nil
        output?.setSampleBufferDelegate(nil, queue: nil)
        guard let session else { return }
        await runOnSessionQueue {
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Prefer the connected Apple TV's name, then any device whose name
    /// contains "apple tv", then the first `modelID` of "iOS Device".
    private func bestCaptureDevice() -> AVCaptureDevice? {
        let devices = discovery.devices
        let wanted = activeDeviceName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let wanted, !wanted.isEmpty {
            if let exact = devices.first(where: { $0.localizedName.lowercased() == wanted }) {
                return exact
            }
            if let partial = devices.first(where: { $0.localizedName.lowercased().contains(wanted) }) {
                return partial
            }
        }
        if let appleTV = devices.first(where: {
            $0.localizedName.range(of: "apple tv", options: .caseInsensitive) != nil
        }) {
            return appleTV
        }
        return devices.first {
            $0.modelID.range(of: "iOS Device", options: .caseInsensitive) != nil
        }
    }

    private func captureDeviceChanged(_ note: Notification) {
        let device = note.object as? AVCaptureDevice
        if note.name == AVCaptureDevice.wasDisconnectedNotification, device?.uniqueID == currentDeviceID {
            Self.log.info("capture device disconnected — restarting")
            Task {
                await self.performSessionWork {
                    await self.stopStream()
                    await self.startIfPossibleNow()
                }
            }
            return
        }
        Self.log.info("capture device connected \(device?.localizedName ?? "?", privacy: .public)")
        Task { await startIfPossible() }
    }

    private func sessionDidFail(_ note: Notification) {
        guard let failed = note.object as? AVCaptureSession, failed === session else { return }
        let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
            ?? "Capture session failed."
        Self.log.error("session runtime error: \(message, privacy: .public)")
        lastError = message
        Task {
            await self.performSessionWork {
                await self.stopStream()
                await self.startIfPossibleNow()
            }
        }
    }

    private func focusAppWindowIfNeeded() {
        guard !didFocusOnConnect else { return }
        didFocusOnConnect = true
        Self.log.info("screen connected — focusing app window")
        NSApp.activate(ignoringOtherApps: true)
        let win = NSApp.mainWindow ?? NSApp.windows.first
        win?.makeKeyAndOrderFront(nil)
        win?.orderFrontRegardless()
    }

    private func pollNote(_ note: String) {
        guard note != lastPollNote else { return }
        lastPollNote = note
        Self.log.info("poll: \(note, privacy: .public)")
    }

    private func runOnSessionQueue<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                continuation.resume(returning: body())
            }
        }
    }

    // MARK: - CMIO + format

    /// Same two flags QuickTime sets so wireless Apple TV devices show up
    /// in `AVCaptureDevice.DiscoverySession`.
    private static func enableCMIOCaptureDevices() {
        setCMIOFlag(
            CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            name: "AllowScreenCaptureDevices"
        )
        setCMIOFlag(
            CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices),
            name: "AllowWirelessScreenCaptureDevices"
        )
    }

    private static func setCMIOFlag(_ selector: CMIOObjectPropertySelector, name: String) {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
        if status == 0 {
            log.info("CMIO \(name, privacy: .public)=1")
        } else {
            log.error("CMIO \(name, privacy: .public) OSStatus \(status, privacy: .public)")
        }
    }

    /// Full native resolution: the largest video format the device lists.
    /// When the device only advertises muxed formats (the verified Apple TV
    /// path), leave the default — that default is the 1920×1080 feed.
    private static func lockLargestVideoFormat(_ device: AVCaptureDevice) {
        guard let format = largestVideoFormat(on: device) else {
            log.info("no video format listed — leaving the device format unchanged")
            return
        }
        do {
            try device.lockForConfiguration()
        } catch {
            log.error("format lock failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        device.activeFormat = format
        device.unlockForConfiguration()
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        log.info("capture format \(dims.width, privacy: .public)x\(dims.height, privacy: .public)")
    }

    private static func largestVideoFormat(on device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        var best: (AVCaptureDevice.Format, Int32)?
        for format in device.formats {
            let desc = format.formatDescription
            guard CMFormatDescriptionGetMediaType(desc) == kCMMediaType_Video else { continue }
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let area = dims.width * dims.height
            if area > (best?.1 ?? 0) {
                best = (format, area)
            }
        }
        return best?.0
    }

    private static func captureError(_ message: String, code: Int) -> NSError {
        NSError(domain: "CaptureCoordinator", code: code, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }

    // MARK: - Preview visibility

    private func observeCaptureDevices() {
        let names = [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification,
        ]
        let center = NotificationCenter.default
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.captureDeviceChanged(note)
                }
            }
            lifetimeObservers.append(token)
        }
    }

    private func observeSessionFailures() {
        let token = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: nil,
            queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.sessionDidFail(note)
            }
        }
        lifetimeObservers.append(token)
    }

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
            lifetimeObservers.append(token)
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
    /// start/stop, and session start can overlap across awaits.
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
        guard isStreaming, captureDevice != nil else {
            logPreviewDeliveryIfChanged()
            return
        }
        let slowDown = !visible && !isRecording && !recordingNeedsFullRate
        if slowDown {
            previewThrottled = await slowHiddenDelivery()
        } else {
            let restored = await restoreFullDelivery()
            previewThrottled = !restored
        }
        guard isStreaming else { return }
        logPreviewDeliveryIfChanged()
    }

    /// Device accepted 2 fps, or the delegate will skip work instead.
    private func slowHiddenDelivery() async -> Bool {
        guard let device = captureDevice else { return false }
        let adapter = streamOutput
        let limited = await runOnSessionQueue {
            Self.limitFrameRateForHiddenPreview(device: device)
        }
        adapter?.setSkipsProcessing(!limited)
        return true
    }

    /// `false` only when a duration was previously written and could not be cleared.
    private func restoreFullDelivery() async -> Bool {
        guard let device = captureDevice else { return true }
        let adapter = streamOutput
        let restored = await runOnSessionQueue {
            Self.restoreNativeFrameRate(device: device)
        }
        adapter?.setSkipsProcessing(false)
        return restored
    }

    private static func limitFrameRateForHiddenPreview(device: AVCaptureDevice) -> Bool {
        // Automatic frame-rate mode throws if a duration is set. The caller
        // then skips buffers in the delegate instead.
        if #available(macOS 15.0, *), device.isAutoVideoFrameRateEnabled { return false }
        guard supportsLockedFrameRate(2, device: device) else { return false }
        return setFrameDuration(hiddenFrameInterval, on: device)
    }

    private static func restoreNativeFrameRate(device: AVCaptureDevice) -> Bool {
        // Nothing to undo when the device owns its frame rate — the hidden
        // path never wrote a duration in that mode.
        if #available(macOS 15.0, *), device.isAutoVideoFrameRateEnabled { return true }
        return setFrameDuration(.invalid, on: device)
    }

    /// `kCMTimeInvalid` is the documented reset. Any other value must already
    /// have been checked against `videoSupportedFrameRateRanges`; an
    /// unsupported duration raises an Objective-C exception.
    private static func setFrameDuration(_ interval: CMTime, on device: AVCaptureDevice) -> Bool {
        do {
            try device.lockForConfiguration()
        } catch {
            log.error("frame-rate lock failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        device.activeVideoMinFrameDuration = interval
        device.activeVideoMaxFrameDuration = interval
        device.unlockForConfiguration()
        return true
    }

    private static func supportsLockedFrameRate(_ rate: Double, device: AVCaptureDevice) -> Bool {
        device.activeFormat.videoSupportedFrameRateRanges.contains { range in
            range.minFrameRate <= rate && rate <= range.maxFrameRate
        }
    }

    private func logPreviewDeliveryIfChanged() {
        guard loggedPreviewVisible != previewVisible || loggedPreviewThrottled != previewThrottled else { return }
        loggedPreviewVisible = previewVisible
        loggedPreviewThrottled = previewThrottled
        let visible = previewVisible ? "true" : "false"
        let throttled = previewThrottled ? "true" : "false"
        Self.perfLog.notice("preview visible=\(visible, privacy: .public) throttled=\(throttled, privacy: .public)")
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

// MARK: - Sample buffer adapter

/// Splits incoming camera sample buffers into the live preview layer and the
/// recorder. Retains only the latest pixel buffer for screenshots.
/// The display layer is not published; SwiftUI never sees individual frames.
/// Preview enqueue pauses while the app window is not visible. While the
/// window is hidden and nothing is recording, `skipsProcessing` drops the
/// buffer work; frame timing still advances so a stall can be detected.
final class StreamOutputAdapter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var latestPixelBuffer: CVPixelBuffer?
    private var pixelSize: CGSize?
    private let lock = NSLock()
    private weak var previewLayer: AVSampleBufferDisplayLayer?
    private var enqueuesPreview = true
    private var skipsProcessing = false

    /// Written on the main actor, read on the sample queue — guarded by `lock`.
    private var _recorder: VideoRecorder?
    var recorder: VideoRecorder? {
        get { lock.lock(); defer { lock.unlock() }; return _recorder }
        set { lock.lock(); _recorder = newValue; lock.unlock() }
    }

    /// Latest frame dimensions. Nil until a buffer has been processed.
    var currentPixelSize: CGSize? {
        lock.lock(); defer { lock.unlock() }
        return pixelSize
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

    /// Main thread, or the session queue while the preview policy is applied.
    /// Ignored while a recorder is attached so a hide can't starve the file.
    func setSkipsProcessing(_ enabled: Bool) {
        lock.lock()
        skipsProcessing = enabled
        lock.unlock()
    }

    /// Thread-safe copy of the most recent buffer for one-shot screenshots.
    func snapshotLatestPixelBuffer() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latestPixelBuffer
    }

    /// Total complete frames received since this adapter was created.
    var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _frameCount
    }
    private var _frameCount = 0
    private var perfIntervalStart = Date()
    private var perfIntervalStartCount = 0
    private static let perfLog = Logger(subsystem: "com.mahmoudelgendy.AppleTVRemote", category: "perf")

    /// When the most recent frame arrived. A feed that delivered frames and
    /// then goes silent for a long stretch is dead — the coordinator
    /// restarts the capture session then.
    var lastFrameAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return _lastFrameAt
    }
    private var _lastFrameAt: Date?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock()
        _frameCount += 1
        _lastFrameAt = Date()
        let skip = skipsProcessing && _recorder == nil
        if !skip {
            latestPixelBuffer = pixelBuffer
            pixelSize = CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        }
        let layer = (!skip && enqueuesPreview) ? previewLayer : nil
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
        guard !skip else { return }

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
