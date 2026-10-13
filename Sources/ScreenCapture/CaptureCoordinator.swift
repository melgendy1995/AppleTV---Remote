import AppKit
import AVFoundation
import Combine
import CoreImage
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import OSLog

enum CapturePreviewMode: String {
    case previewLayer
    case sampleBuffer
}

/// Mirrors the Apple TV by opening its CMIO screen-capture device with
/// `AVCaptureSession`. QuickTime is not launched and ScreenCaptureKit is not
/// used. PNG screenshots and the MP4 recorder share the sample buffers.
/// The preview is either the sample-buffer layer (`previewMode` =
/// `sampleBuffer`, the default) or an `AVCaptureVideoPreviewLayer`
/// (`previewLayer`, optional).
///
/// CMIO screen-capture flags and the capture session stay off until
/// `BackendClient` reports a connection. Disconnect stops the session and
/// removes the device input. The next connect builds a new session and reads
/// `capturePixelFormat` and `previewMode` again.
///
/// The device delivers about 60 fps and rejects `activeVideoMinFrameDuration`
/// / `activeVideoMaxFrameDuration` (muxed-only, no frame-rate ranges). Those
/// device properties are never written. Recording decimates in the sample
/// delegate to `previewFPS` (UserDefaults, 30 or 60, default 30). In
/// `previewLayer` mode the preview connection's `videoMinFrameDuration` is
/// set only when `isVideoMinFrameDurationSupported` says so; if that is
/// unsupported or throws, the preview stays at the device rate. When
/// UserDefaults `dataOutputFrameLimit` is true (default true), the same
/// guard sets the video-data-output connection to 1/`previewFPS` after that
/// output is added. Software decimation is unchanged. The default is on
/// because an on-device A/B showed lower app CPU (about 3 points), helpers
/// unchanged, raw frames 60 to 30, applied=true, and no errors.
///
/// `previewLayer` does not run `AVCaptureVideoDataOutput` while only the
/// preview is showing. The output is added for a recording, and for one
/// frame when a screenshot is requested. A hidden window disables the
/// preview connection instead of stopping the session: `stopRunning` drops
/// the wireless device and the next picture takes seconds, while re-enabling
/// the connection shows the next frame. `sampleBuffer` mode still pauses
/// preview enqueue when hidden and, unless a recording is running, skips
/// most buffers down to about 2 fps.
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
    /// Session the preview layer attaches to. Set while `isStreaming` is true.
    private(set) var previewSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var captureDevice: AVCaptureDevice?
    private var currentDeviceID: String?
    /// Not published. Frames go straight to the display layer; publishing the
    /// adapter or each frame would redraw ContentView at the capture rate.
    private(set) var streamOutput: StreamOutputAdapter?
    private var recorder: VideoRecorder?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?

    /// Created only after the CMIO screen-capture flags are enabled, which
    /// happens on the first backend connection — not at launch.
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var cmioCaptureEnabled = false
    /// False until BackendClient reports an Apple TV connection. Gates CMIO
    /// flags and `startRunning`.
    private var backendLinkUp = false
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

    private static let perfLog = Logger(subsystem: "com.mahmoudelgendy.AppleTVRemote", category: "perf")
    static let previewFPSDefaultsKey = "previewFPS"
    static let capturePixelFormatDefaultsKey = "capturePixelFormat"
    static let previewModeDefaultsKey = "previewMode"
    /// On by default. On-device A/B: app CPU about 3 points lower, helpers
    /// unchanged, raw frames 60 to 30, applied=true, no errors. Read when the
    /// session starts and when the data output is attached. Does not change
    /// device frame durations.
    static let dataOutputFrameLimitDefaultsKey = "dataOutputFrameLimit"
    /// 30 or 60. Pushed into the live sample adapter; not a session rebuild.
    private var previewFPS = 30
    /// Latched when a session opens. `2vuy` or `420v`. `native` is stored as
    /// `2vuy` because an empty `videoSettings` delivers no sample buffers.
    private(set) var latchedPixelFormat = "2vuy"
    private(set) var latchedPreviewMode: CapturePreviewMode = .sampleBuffer
    /// True only while the video data output is in the running session.
    /// Preview-layer streaming leaves it false.
    private var sampleOutputAttached = false
    private var frameWatchBaseline = 0
    private var frameWatchStartedAt: Date?
    private weak var hostedPreviewLayer: AVCaptureVideoPreviewLayer?
    private var wantPreviewConnection = true
    private var appliedPreviewDuration: CMTime = .invalid
    private var previewRateUnavailable = false
    private var previewHeartbeat: Timer?

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
        super.init()
        permissionGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        UserDefaults.standard.register(defaults: [
            Self.previewFPSDefaultsKey: 30,
            Self.capturePixelFormatDefaultsKey: "2vuy",
            Self.previewModeDefaultsKey: CapturePreviewMode.sampleBuffer.rawValue,
            Self.dataOutputFrameLimitDefaultsKey: true,
        ])
        previewFPS = Self.clampedPreviewFPS(UserDefaults.standard.integer(forKey: Self.previewFPSDefaultsKey))
        observeCaptureDevices()
        observeSessionFailures()
        observePreviewVisibility()
        observePreviewFPS()
    }

    deinit {
        let center = NotificationCenter.default
        for token in lifetimeObservers {
            center.removeObserver(token)
        }
        previewHeartbeat?.invalidate()
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

    /// Backend connection gate. CMIO flags and the capture session start only
    /// while `connected` is true. Disconnect stops the session and drops the
    /// device input. A nil name while a link is already up is the brief clear
    /// inside `BackendClient.connect`; it is not a disconnect.
    func updateBackendLink(connected: Bool, deviceName: String?) {
        if !connected {
            guard backendLinkUp || isStreaming || session != nil else { return }
            backendLinkUp = false
            activeDeviceName = nil
            didFocusOnConnect = false
            captureDeviceName = nil
            lastError = nil
            Task { await self.performSessionWork { await self.stopStream() } }
            return
        }
        let trimmed = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty, backendLinkUp { return }
        let name = trimmed.isEmpty ? nil : trimmed
        let becameConnected = !backendLinkUp
        let nameChanged = name != activeDeviceName
        backendLinkUp = true
        activeDeviceName = name
        guard becameConnected || nameChanged else { return }
        if becameConnected { didFocusOnConnect = false }
        Task { await self.startIfPossible() }
    }

    /// True when the on-screen feed is up. Preview-layer mode has no sample
    /// buffers until a recording or screenshot asks for one.
    var feedIsHealthy: Bool {
        guard isStreaming, session?.isRunning == true else { return false }
        if latchedPreviewMode == .previewLayer, !sampleOutputAttached { return true }
        return (streamOutput?.frameCount ?? 0) > frameWatchBaseline
    }

    /// Called by the preview host when its backing layer is the capture preview.
    func notePreviewLayer(_ layer: AVCaptureVideoPreviewLayer?) {
        if hostedPreviewLayer !== layer {
            hostedPreviewLayer = layer
            appliedPreviewDuration = .invalid
        }
        applyPreviewConnectionState()
        applyPreviewLayerFrameRate()
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
    /// `lastError` populated) if no frame is available yet. Preview-layer mode
    /// adds the data output for the first new frame, then removes it.
    func captureScreenshot() async -> URL? {
        if latchedPreviewMode == .previewLayer, !sampleOutputAttached {
            return await captureScreenshotFromTemporaryOutput()
        }
        if streamOutput?.snapshotLatestPixelBuffer() == nil {
            let baseline = streamOutput?.processedCount ?? 0
            _ = await waitForProcessedFrame(after: baseline, timeout: 5)
        }
        guard let pixelBuffer = streamOutput?.snapshotLatestPixelBuffer() else {
            lastError = Self.noFrameMessage
            return nil
        }
        return await writeScreenshot(pixelBuffer)
    }

    private func captureScreenshotFromTemporaryOutput() async -> URL? {
        let baseline = streamOutput?.processedCount ?? 0
        guard await attachSampleOutput() else {
            lastError = Self.noFrameMessage
            return nil
        }
        let arrived = await waitForProcessedFrame(after: baseline, timeout: 5)
        let pixelBuffer = arrived ? streamOutput?.snapshotLatestPixelBuffer() : nil
        // Encode while the output still owns the buffer. Removing the output
        // first can recycle the IOSurface out from under the PNG write.
        let saved: URL?
        if let pixelBuffer {
            saved = await writeScreenshot(pixelBuffer)
        } else {
            lastError = Self.noFrameMessage
            saved = nil
        }
        if !isRecording { await detachSampleOutput() }
        return saved
    }

    private func writeScreenshot(_ pixelBuffer: CVPixelBuffer) async -> URL? {
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
        // Clear the hidden-window skip before the writer is attached. A hide
        // must not leave the recording on the 2 fps cap. Kept frames still
        // follow previewFPS.
        recordingNeedsFullRate = true
        await applyPreviewDelivery()
        guard !previewThrottled else {
            recordingNeedsFullRate = false
            lastError = "Couldn't restore full frame rate for recording."
            return
        }
        if latchedPreviewMode == .previewLayer, !sampleOutputAttached {
            guard await attachSampleOutputForRecording() else { return }
        }
        guard isStreaming, backendLinkUp, let size = streamOutput?.currentPixelSize else {
            lastError = "Recording needs at least one frame first."
            if latchedPreviewMode == .previewLayer { await detachSampleOutput() }
            await endFullRateHold()
            return
        }
        do {
            let dir = try CaptureStorage.captureDirectory()
            let url = dir.appendingPathComponent(CaptureStorage.filename(kind: "recording", ext: "mp4"))
            let recorder = try VideoRecorder(
                url: url,
                pixelSize: size,
                framesPerSecond: previewFPS,
                sourceFormatHint: streamOutput?.sourceFormatHint()
            )
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
            if latchedPreviewMode == .previewLayer { await detachSampleOutput() }
            await endFullRateHold()
        }
    }

    private func attachSampleOutputForRecording() async -> Bool {
        let baseline = streamOutput?.processedCount ?? 0
        guard await attachSampleOutput() else {
            lastError = "Couldn't read frames for recording."
            await endFullRateHold()
            return false
        }
        guard await waitForProcessedFrame(after: baseline, timeout: 5),
              isStreaming, backendLinkUp else {
            lastError = "Recording needs at least one frame first."
            await detachSampleOutput()
            await endFullRateHold()
            return false
        }
        return true
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
        // Preview-layer mode has no sample stream except while recording
        // or grabbing a screenshot. Sample-buffer mode keeps the session's
        // output and only changes the software cap below.
        if latchedPreviewMode == .previewLayer {
            await detachSampleOutput()
        }
        // Window still hidden → software ~2 fps for preview work.
        // A visible window keeps the selected previewFPS.
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
        guard backendLinkUp else {
            pollNote("waiting for Apple TV connection")
            if isStreaming || session != nil { await stopStream() }
            return
        }
        guard permissionGranted else {
            pollNote("camera permission missing")
            return
        }
        prepareDiscoveryIfNeeded()
        guard let device = bestCaptureDevice() else {
            let count = discovery?.devices.count ?? 0
            pollNote("no Apple TV capture device (\(count) external)")
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
        if latchedPreviewMode == .previewLayer, !sampleOutputAttached {
            if lastError != nil { lastError = nil }
            focusAppWindowIfNeeded()
            pollNote("healthy")
            return
        }
        let frames = (streamOutput?.frameCount ?? 0) - frameWatchBaseline
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
        let started = frameWatchStartedAt ?? streamStartedAt
        guard let started, Date().timeIntervalSince(started) > 15 else {
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
        guard backendLinkUp else {
            captureDeviceName = nil
            return
        }
        captureDeviceName = device.localizedName
        latchSessionDefaults()

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        let adapter = StreamOutputAdapter()
        adapter.setPreviewFPS(previewFPS)
        if !previewVisible || latchedPreviewMode == .previewLayer {
            adapter.setEnqueuesPreview(false)
        }
        output.setSampleBufferDelegate(adapter, queue: sampleQueue)
        Self.applyRequestedPixelFormat(output, choice: latchedPixelFormat)

        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw Self.captureError("Can't open the Apple TV capture device.", code: 3)
        }
        session.addInput(input)
        if latchedPreviewMode == .sampleBuffer {
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                throw Self.captureError("Can't read video from the Apple TV capture device.", code: 4)
            }
            session.addOutput(output)
            applyDataOutputFrameLimit(output)
        }
        Self.lockLargestVideoFormat(device)
        session.commitConfiguration()

        let running = await runOnSessionQueue { () -> Bool in
            session.startRunning()
            return session.isRunning
        }
        guard running else {
            throw Self.captureError("Capture session did not start.", code: 5)
        }

        let started = Date()
        self.session = session
        self.previewSession = session
        self.videoOutput = output
        self.captureDevice = device
        self.currentDeviceID = device.uniqueID
        self.streamOutput = adapter
        self.streamStartedAt = started
        self.frameWatchStartedAt = started
        self.frameWatchBaseline = 0
        self.sampleOutputAttached = latchedPreviewMode == .sampleBuffer
        self.previewThrottled = false
        self.isStreaming = true
        Self.log.info("capture started \(device.localizedName, privacy: .public) model=\(device.modelID, privacy: .public) preview=\(self.latchedPreviewMode.rawValue, privacy: .public) pixels=\(self.latchedPixelFormat, privacy: .public)")
        await applyPreviewDelivery()
        updatePreviewHeartbeat()
        if latchedPreviewMode == .previewLayer {
            focusAppWindowIfNeeded()
        }
    }

    /// `capturePixelFormat` and `previewMode` are read here, when the session
    /// is built, so a defaults change applies on the next connect without a rebuild.
    private func latchSessionDefaults() {
        latchedPixelFormat = Self.resolvedPixelFormat(
            UserDefaults.standard.string(forKey: Self.capturePixelFormatDefaultsKey)
        )
        latchedPreviewMode = Self.resolvedPreviewMode(
            UserDefaults.standard.string(forKey: Self.previewModeDefaultsKey)
        )
        previewRateUnavailable = false
        appliedPreviewDuration = .invalid
    }

    private func stopStream() async {
        let session = self.session
        let output = videoOutput
        isStreaming = false
        previewSession = nil
        streamStartedAt = nil
        frameWatchStartedAt = nil
        didFocusOnConnect = false
        previewThrottled = false
        sampleOutputAttached = false
        self.session = nil
        self.videoOutput = nil
        self.captureDevice = nil
        currentDeviceID = nil
        updatePreviewHeartbeat()
        if isRecording { _ = await stopRecording() }
        streamOutput?.attachPreviewLayer(nil)
        streamOutput = nil
        output?.setSampleBufferDelegate(nil, queue: nil)
        hostedPreviewLayer?.session = nil
        guard let session else { return }
        await runOnSessionQueue {
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            for output in session.outputs {
                session.removeOutput(output)
            }
            session.commitConfiguration()
        }
        if !backendLinkUp { captureDeviceName = nil }
    }

    private func prepareDiscoveryIfNeeded() {
        if !cmioCaptureEnabled {
            Self.enableCMIOCaptureDevices()
            cmioCaptureEnabled = true
        }
        guard discovery == nil else { return }
        discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: nil,
            position: .unspecified
        )
    }

    /// Preview-layer mode keeps the data output out of the session until a
    /// recording or screenshot needs frames. Adding it (instead of leaving a
    /// disabled connection in the graph) keeps the preview on the device format.
    private func attachSampleOutput() async -> Bool {
        guard latchedPreviewMode == .previewLayer else { return false }
        guard let session, let output = videoOutput else { return false }
        if sampleOutputAttached { return true }
        let format = latchedPixelFormat
        let attached = await runOnSessionQueue { () -> Bool in
            session.beginConfiguration()
            let already = session.outputs.contains { $0 === output }
            if !already {
                Self.applyRequestedPixelFormat(output, choice: format)
                guard session.canAddOutput(output) else {
                    session.commitConfiguration()
                    return false
                }
                session.addOutput(output)
            }
            session.commitConfiguration()
            return true
        }
        guard attached else {
            Self.log.error("video data output was refused")
            return false
        }
        applyDataOutputFrameLimit(output)
        sampleOutputAttached = true
        frameWatchBaseline = streamOutput?.frameCount ?? 0
        frameWatchStartedAt = Date()
        updatePreviewHeartbeat()
        return true
    }

    private func detachSampleOutput() async {
        guard latchedPreviewMode == .previewLayer, sampleOutputAttached,
              let session, let output = videoOutput else { return }
        await runOnSessionQueue {
            session.beginConfiguration()
            if session.outputs.contains(where: { $0 === output }) {
                session.removeOutput(output)
            }
            session.commitConfiguration()
        }
        sampleOutputAttached = false
        updatePreviewHeartbeat()
    }

    private func waitForProcessedFrame(after baseline: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (streamOutput?.processedCount ?? 0) > baseline,
               streamOutput?.snapshotLatestPixelBuffer() != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return (streamOutput?.processedCount ?? 0) > baseline
            && streamOutput?.snapshotLatestPixelBuffer() != nil
    }

    private func applyPreviewConnectionState() {
        guard latchedPreviewMode == .previewLayer,
              let connection = hostedPreviewLayer?.connection,
              connection.isEnabled != wantPreviewConnection else { return }
        connection.isEnabled = wantPreviewConnection
    }

    /// Device `activeVideoMinFrameDuration` throws on this muxed CMIO device.
    /// The preview connection is attempted only inside the ObjC guard.
    private func applyPreviewLayerFrameRate() {
        guard latchedPreviewMode == .previewLayer, !previewRateUnavailable,
              let connection = hostedPreviewLayer?.connection else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(previewFPS))
        if appliedPreviewDuration.isValid, CMTimeCompare(appliedPreviewDuration, duration) == 0 { return }
        var failure: NSString?
        switch CaptureSetVideoMinFrameDuration(connection, duration, &failure) {
        case .applied:
            appliedPreviewDuration = duration
            Self.perfLog.notice("preview layer frame duration \(self.previewFPS, privacy: .public) fps")
        case .unsupported, .exception:
            previewRateUnavailable = true
            let why = (failure as String?) ?? "unsupported"
            Self.log.info("preview videoMinFrameDuration unavailable (\(why, privacy: .public)) — preview stays at the device native rate; recording still decimates to \(self.previewFPS, privacy: .public) fps")
        @unknown default:
            previewRateUnavailable = true
        }
    }

    /// `dataOutputFrameLimit` is read here, at session start or when the data
    /// output is attached. The device's active min/max frame durations are
    /// never written. Software decimation in the sample delegate stays as it is.
    private func applyDataOutputFrameLimit(_ output: AVCaptureVideoDataOutput) {
        guard UserDefaults.standard.bool(forKey: Self.dataOutputFrameLimitDefaultsKey) else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(previewFPS))
        var failure: NSString?
        let result = CaptureSetVideoMinFrameDuration(
            output.connection(with: .video),
            duration,
            &failure
        )
        let applied = result == .applied
        let error = (failure as String?) ?? (applied ? "" : "unsupported")
        Self.perfLog.notice("data output frame limit applied=\(applied ? "true" : "false", privacy: .public) fps=\(self.previewFPS, privacy: .public) error=\(error, privacy: .public)")
    }

    private func updatePreviewHeartbeat() {
        let want = isStreaming && latchedPreviewMode == .previewLayer && !sampleOutputAttached
        if want {
            guard previewHeartbeat == nil else { return }
            let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.logPreviewLayerActive() }
            }
            RunLoop.main.add(timer, forMode: .common)
            previewHeartbeat = timer
            return
        }
        previewHeartbeat?.invalidate()
        previewHeartbeat = nil
    }

    private func logPreviewLayerActive() {
        guard isStreaming, latchedPreviewMode == .previewLayer, !sampleOutputAttached else { return }
        Self.perfLog.notice("preview layer active")
    }

    /// Prefer the connected Apple TV's name, then any device whose name
    /// contains "apple tv", then the first `modelID` of "iOS Device".
    private func bestCaptureDevice() -> AVCaptureDevice? {
        let devices = discovery?.devices ?? []
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
        guard backendLinkUp else { return }
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

    /// `2vuy` and `420v` are explicit requests. `native` and anything else
    /// are `2vuy`: an empty `videoSettings` dictionary delivers no frames to
    /// `AVCaptureVideoDataOutput` on this Apple TV (measured on device).
    /// BGRA is never requested — it is not a device capture format.
    private static func applyRequestedPixelFormat(_ output: AVCaptureVideoDataOutput, choice: String) {
        switch choice {
        case "420v":
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            ]
        default:
            // "native" (empty videoSettings) yields no sample buffers.
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_422YpCbCr8),
            ]
        }
    }

    nonisolated static func resolvedPixelFormat(_ raw: String?) -> String {
        switch raw {
        case "420v": return "420v"
        // "native" used to mean an empty videoSettings dictionary. That path
        // delivers no frames to AVCaptureVideoDataOutput, so it is 2vuy.
        case "2vuy", "native": return "2vuy"
        default: return "2vuy"
        }
    }

    nonisolated static func resolvedPreviewMode(_ raw: String?) -> CapturePreviewMode {
        raw == CapturePreviewMode.previewLayer.rawValue ? .previewLayer : .sampleBuffer
    }

    private static let noFrameMessage = "No frame available yet — is the Apple TV screen connected?"

    nonisolated fileprivate static func fourCC(_ code: OSType) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }

    /// 60 stays 60. Any other stored value, including a missing key (0), is 30.
    nonisolated static func clampedPreviewFPS(_ raw: Int) -> Int {
        raw == 60 ? 60 : 30
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

    private func observePreviewFPS() {
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyPreviewFPSFromDefaults()
            }
        }
        lifetimeObservers.append(token)
    }

    /// Reads `previewFPS` and pushes it to the live adapter. Does not rebuild
    /// the capture session; the next sample buffer uses the new interval.
    private func applyPreviewFPSFromDefaults() {
        let fps = Self.clampedPreviewFPS(UserDefaults.standard.integer(forKey: Self.previewFPSDefaultsKey))
        guard fps != previewFPS else { return }
        previewFPS = fps
        streamOutput?.setPreviewFPS(fps)
        appliedPreviewDuration = .invalid
        previewRateUnavailable = false
        applyPreviewLayerFrameRate()
        Self.perfLog.notice("preview fps \(fps, privacy: .public)")
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
        if latchedPreviewMode == .previewLayer {
            // Disabling the preview connection keeps the wireless device open.
            // stopRunning would drop it, and the next frame would take seconds.
            streamOutput?.setEnqueuesPreview(false)
            let pausePreview = !visible && !isRecording && !recordingNeedsFullRate
            wantPreviewConnection = visible
            applyPreviewConnectionState()
            streamOutput?.setSkipsProcessing(pausePreview)
            previewThrottled = pausePreview
            logPreviewDeliveryIfChanged()
            return
        }
        streamOutput?.setEnqueuesPreview(visible)
        guard isStreaming, captureDevice != nil else {
            logPreviewDeliveryIfChanged()
            return
        }
        let slowDown = !visible && !isRecording && !recordingNeedsFullRate
        if slowDown {
            previewThrottled = slowHiddenDelivery()
        } else {
            let restored = restoreFullDelivery()
            previewThrottled = !restored
        }
        guard isStreaming else { return }
        logPreviewDeliveryIfChanged()
    }

    /// Software cap while the window is hidden. The DAL device throws if a
    /// frame duration is written, so the delegate throttles instead.
    private func slowHiddenDelivery() -> Bool {
        guard captureDevice != nil else { return false }
        streamOutput?.setSkipsProcessing(true)
        return true
    }

    /// Clears the software cap. Nothing was written on the device.
    private func restoreFullDelivery() -> Bool {
        guard captureDevice != nil else { return true }
        streamOutput?.setSkipsProcessing(false)
        return true
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

    /// CIImage accepts the device format, including 2vuy and 420v, so the PNG
    /// path does not convert the buffer before this call.
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
/// recorder. Retains only a reference to the latest pixel buffer; screenshots
/// convert that buffer when asked. The display layer is not published.
///
/// Buffers are decimated by presentation timestamp to `previewFPS`. Recording
/// gets the same kept buffers. Preview enqueue pauses while the app window is
/// not visible. While the window is hidden and nothing is recording,
/// `skipsProcessing` keeps about two frames of preview and screenshot work
/// each second. Every buffer still advances frame timing so a stall can be
/// detected. The hidden skip does not drop kept frames from a recording.
final class StreamOutputAdapter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var latestPixelBuffer: CVPixelBuffer?
    private var pixelSize: CGSize?
    private let lock = NSLock()
    private weak var previewLayer: AVSampleBufferDisplayLayer?
    private var enqueuesPreview = true
    private var skipsProcessing = false
    /// Spacing that yields about two processed frames per second while hidden.
    /// Far below the 45s silence restart, so the cap is not treated as a stall.
    private static let hiddenProcessInterval: TimeInterval = 0.5
    private var lastProcessedAt: Date?
    private var targetFPS = 30
    private var lastKeptPTS: CMTime = .invalid
    /// 2ms. A 60 fps step is ~16.7ms, so `1/30 - 2ms` still rejects the frame
    /// that sits between two kept frames. A 60 fps target keeps every step,
    /// because each step is greater than `1/60 - 2ms`.
    private static let keepTolerance = CMTime(value: 2, timescale: 1000)

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

    /// Main thread. The sample queue reads the target under `lock`.
    /// Resets the cadence so the next buffer is kept immediately.
    func setPreviewFPS(_ fps: Int) {
        let clamped = CaptureCoordinator.clampedPreviewFPS(fps)
        lock.lock()
        if targetFPS != clamped {
            targetFPS = clamped
            lastKeptPTS = .invalid
        }
        lock.unlock()
    }

    /// Main thread. The sample queue reads the flag under `lock`.
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

    /// Frames whose pixel buffer was retained. Screenshot and recording wait
    /// on this, not on raw `frameCount`, so a skipped buffer cannot satisfy them.
    var processedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _processedCount
    }
    private var _processedCount = 0
    private var formatDescription: CMFormatDescription?

    func sourceFormatHint() -> CMFormatDescription? {
        lock.lock(); defer { lock.unlock() }
        return formatDescription
    }
    private var perfIntervalStart = Date()
    private var rawInInterval = 0
    private var keptInInterval = 0
    private var didLogPixelFormat = false
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
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        lock.lock()
        let now = Date()
        _frameCount += 1
        _lastFrameAt = now
        rawInInterval += 1
        let formatToLog: OSType? = didLogPixelFormat ? nil : CVPixelBufferGetPixelFormatType(pixelBuffer)
        if formatToLog != nil { didLogPixelFormat = true }
        let keep = shouldKeep(pts)
        if keep {
            lastKeptPTS = pts
            keptInInterval += 1
        }
        let throttled = skipsProcessing && _recorder == nil
        let withinHiddenInterval = lastProcessedAt.map {
            now.timeIntervalSince($0) < Self.hiddenProcessInterval
        } ?? false
        let skipWork = !keep || (throttled && withinHiddenInterval)
        if !skipWork {
            if throttled { lastProcessedAt = now }
            latestPixelBuffer = pixelBuffer
            _processedCount += 1
            if let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
                formatDescription = description
            }
            pixelSize = CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        }
        let layer = (!skipWork && enqueuesPreview) ? previewLayer : nil
        let perfDue = now.timeIntervalSince(perfIntervalStart) >= 10
        let keptLog = perfDue ? keptInInterval : 0
        let rawLog = perfDue ? rawInInterval : 0
        if perfDue {
            keptInInterval = 0
            rawInInterval = 0
            perfIntervalStart = now
        }
        lock.unlock()
        if let formatToLog {
            Self.perfLog.notice("pixel format \(CaptureCoordinator.fourCC(formatToLog), privacy: .public)")
        }
        if perfDue {
            Self.perfLog.notice("frames \(keptLog, privacy: .public) in 10s raw \(rawLog, privacy: .public)")
        }
        guard !skipWork else { return }

        recorder?.append(sampleBuffer: sampleBuffer)
        enqueuePreview(sampleBuffer, on: layer)
    }

    /// Lock held. First valid timestamp is kept. A backwards timestamp starts
    /// a new cadence. An equal timestamp is a duplicate and is dropped.
    private func shouldKeep(_ pts: CMTime) -> Bool {
        guard pts.isValid else { return false }
        guard lastKeptPTS.isValid else { return true }
        let delta = CMTimeSubtract(pts, lastKeptPTS)
        guard delta.isValid else { return true }
        let order = CMTimeCompare(delta, .zero)
        if order < 0 { return true }
        if order == 0 { return false }
        let interval = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        let threshold = CMTimeSubtract(interval, Self.keepTolerance)
        return CMTimeCompare(delta, threshold) >= 0
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
