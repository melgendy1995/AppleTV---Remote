import AVFoundation
import CoreMedia
import Foundation

/// Wraps `AVAssetWriter` to turn a stream of `CMSampleBuffer` frames into
/// an MP4 on disk. Callers push frames from any queue
/// (the internal serial queue linearises appends and lifecycle transitions).
/// Presentation timestamps may be variable — the capture device runs at its
/// native rate, and the writer drops buffers it cannot accept in time.
final class VideoRecorder: @unchecked Sendable {

    private enum State { case ready, writing, finishing, finished }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "video.recorder", qos: .userInitiated)
    private var state: State = .ready
    private var sessionStartPTS: CMTime = .invalid
    private var lastAcceptedPTS: CMTime = .invalid
    let outputURL: URL

    init(url: URL, pixelSize: CGSize) throws {
        self.outputURL = url
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieTimeScale = 600

        let width = max(2, Int(pixelSize.width))
        let height = max(2, Int(pixelSize.height))
        let bitrate = Self.suggestedBitrate(width: width, height: height)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw NSError(domain: "VideoRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter refused input"])
        }
        writer.add(input)
        self.writer = writer
        self.input = input
    }

    /// Feed one sample buffer. Safe to call from any thread.
    func append(sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            switch self.state {
            case .finishing, .finished: return
            case .ready:
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                guard pts.isValid else { return }
                if !self.writer.startWriting() {
                    self.state = .finished
                    return
                }
                self.writer.startSession(atSourceTime: pts)
                self.sessionStartPTS = pts
                self.state = .writing
                fallthrough
            case .writing:
                guard self.input.isReadyForMoreMediaData else { return }
                // Drop out-of-order buffers; AVAssetWriter refuses non-monotonic PTS.
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if self.lastAcceptedPTS.isValid, pts <= self.lastAcceptedPTS { return }
                if self.input.append(sampleBuffer) {
                    self.lastAcceptedPTS = pts
                }
            }
        }
    }

    /// Flush pending frames and finalize the MP4. Returns the file URL.
    func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: NSError(domain: "VideoRecorder", code: 2))
                    return
                }
                switch self.state {
                case .finished:
                    cont.resume(returning: self.outputURL)
                    return
                case .ready:
                    // Never received a frame — nothing to write.
                    self.state = .finished
                    cont.resume(throwing: NSError(
                        domain: "VideoRecorder", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "No frames were captured."]))
                    return
                case .finishing:
                    cont.resume(throwing: NSError(domain: "VideoRecorder", code: 4))
                    return
                case .writing:
                    self.state = .finishing
                    self.input.markAsFinished()
                    self.writer.finishWriting { [weak self] in
                        guard let self else {
                            cont.resume(throwing: NSError(domain: "VideoRecorder", code: 5))
                            return
                        }
                        self.state = .finished
                        if self.writer.status == .completed {
                            cont.resume(returning: self.outputURL)
                        } else {
                            let err = self.writer.error ?? NSError(
                                domain: "VideoRecorder", code: 6,
                                userInfo: [NSLocalizedDescriptionKey: "AVAssetWriter did not complete."])
                            cont.resume(throwing: err)
                        }
                    }
                }
            }
        }
    }

    /// Rough H.264 bitrate for a given resolution. Errs on the readable side.
    private static func suggestedBitrate(width: Int, height: Int) -> Int {
        let pixels = width * height
        switch pixels {
        case ..<(1280 * 720):   return 3_000_000
        case ..<(1920 * 1080):  return 6_000_000
        case ..<(2560 * 1440):  return 10_000_000
        default:                return 16_000_000
        }
    }
}
