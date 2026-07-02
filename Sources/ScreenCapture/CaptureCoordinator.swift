import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ScreenCaptureKit
import SwiftUI

/// Drives the ScreenCaptureKit pipeline that mirrors QuickTime Player's
/// wireless Apple TV window into the app: a low-rate preview stream, one-shot
/// PNG screenshots, and MP4 recordings — all derived from the same `SCStream`.
///
/// The Apple TV is invisible to public capture APIs, but the QuickTime window
/// that displays it isn't; grabbing that window is our only realistic path.
@MainActor
final class CaptureCoordinator: NSObject, ObservableObject {

    // MARK: - Published state (consumed by ScreenCaptureView)

    @Published private(set) var permissionGranted: Bool = false
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var quicktimeWindow: DetectedWindow?
    @Published private(set) var isStreaming: Bool = false
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published private(set) var lastCaptureURL: URL?
    @Published private(set) var lastError: String?

    struct DetectedWindow: Equatable {
        let windowID: CGWindowID
        let title: String
        let pixelSize: CGSize
    }

    // MARK: - Internals

    private let sampleQueue = DispatchQueue(label: "capture.samples", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var stream: SCStream?
    private var streamOutput: StreamOutputAdapter?
    private var recorder: VideoRecorder?
    private var recordingTimer: Timer?
    private var recordingStartedAt: Date?

    /// Previews only need ~10fps to look live. Full stream fps still feeds the
    /// recorder — we just throttle the CGImage conversion that drives SwiftUI.
    private let previewInterval: TimeInterval = 0.1
    private var lastPreviewUpdate: Date = .distantPast

    // MARK: - Lifecycle

    override init() {
        super.init()
        permissionGranted = CGPreflightScreenCaptureAccess()
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
        guard permissionGranted else { return }
        do {
            guard let window = try await findQuickTimeCaptureWindow() else {
                quicktimeWindow = nil
                await stopStream()
                return
            }
            if let current = quicktimeWindow,
               current.windowID == window.windowID,
               isStreaming { return }
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

    func stop() async {
        if isRecording { _ = await stopRecording() }
        await stopStream()
        quicktimeWindow = nil
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
            try writePNG(pixelBuffer: pixelBuffer, to: url)
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
        guard let size = streamOutput?.currentPixelSize else {
            lastError = "Recording needs at least one frame first."
            return
        }
        do {
            let dir = try CaptureStorage.captureDirectory()
            let url = dir.appendingPathComponent(CaptureStorage.filename(kind: "recording", ext: "mp4"))
            let recorder = try VideoRecorder(url: url, pixelSize: size)
            self.recorder = recorder
            streamOutput?.recorder = recorder
            isRecording = true
            recordingStartedAt = Date()
            recordingElapsed = 0
            startRecordingTimer()
        } catch {
            lastError = "Recording start failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func stopRecording() async -> URL? {
        guard isRecording, let recorder else { return nil }
        streamOutput?.recorder = nil
        stopRecordingTimer()
        isRecording = false
        do {
            let url = try await recorder.finish()
            self.recorder = nil
            lastCaptureURL = url
            return url
        } catch {
            lastError = "Recording finalize failed: \(error.localizedDescription)"
            self.recorder = nil
            return nil
        }
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
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        config.queueDepth = 5

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = StreamOutputAdapter(owner: self, pixelSize: CGSize(width: pixelWidth, height: pixelHeight))
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()

        self.stream = stream
        self.streamOutput = output
        self.isStreaming = true
    }

    private func stopStream() async {
        isStreaming = false
        previewImage = nil
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil
    }

    // MARK: - Discovery

    /// The QuickTime "Movie Recording" window is the largest window owned by
    /// QuickTime Player that isn't a toolbar or inspector. We pick by area.
    private func findQuickTimeCaptureWindow() async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let qtWindows = content.windows.filter { w in
            guard let bundle = w.owningApplication?.bundleIdentifier else { return false }
            return bundle == "com.apple.QuickTimePlayerX"
        }
        // Prefer sensibly-sized recording windows (16:9 area heuristic)
        // over floating palettes/inspectors that QuickTime spawns.
        let candidates = qtWindows.filter { $0.frame.width >= 320 && $0.frame.height >= 180 }
        return candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    }

    // MARK: - Preview / frame handling (called from adapter)

    fileprivate func handlePreviewFrame(_ pixelBuffer: CVPixelBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastPreviewUpdate) >= previewInterval else { return }
        lastPreviewUpdate = now
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        previewImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: - Recording timer

    private func startRecordingTimer() {
        stopRecordingTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartedAt else { return }
                self.recordingElapsed = Date().timeIntervalSince(start)
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

    private func writePNG(pixelBuffer: CVPixelBuffer, to url: URL) throws {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
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
            self?.isStreaming = false
            self?.previewImage = nil
            self?.lastError = "Stream stopped: \(error.localizedDescription)"
        }
    }
}

// MARK: - Stream output adapter (background queue → coordinator)

/// Splits incoming sample buffers into (a) throttled preview updates for the UI
/// and (b) full-rate frames for the recorder. Retains only the latest pixel
/// buffer for the screenshot path so we don't accumulate memory.
private final class StreamOutputAdapter: NSObject, SCStreamOutput {
    weak var owner: CaptureCoordinator?
    var recorder: VideoRecorder?
    private(set) var currentPixelSize: CGSize
    private var latestPixelBuffer: CVPixelBuffer?
    private let lock = NSLock()

    init(owner: CaptureCoordinator, pixelSize: CGSize) {
        self.owner = owner
        self.currentPixelSize = pixelSize
    }

    /// Thread-safe copy of the most recent buffer for one-shot screenshots.
    func snapshotLatestPixelBuffer() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latestPixelBuffer
    }

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

        lock.lock(); latestPixelBuffer = pixelBuffer; lock.unlock()

        recorder?.append(sampleBuffer: sampleBuffer)

        Task { @MainActor [weak owner] in
            owner?.handlePreviewFrame(pixelBuffer)
        }
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
