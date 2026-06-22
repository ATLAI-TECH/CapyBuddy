import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Thin wrapper around `SCStream` + `AVAssetWriter` that owns one recording
/// session end-to-end (start → optional pause/resume → stop/discard). Mic
/// capture goes through SCK's native `SCStreamOutputType.microphone`
/// (macOS 15+) so all sample buffers share the SCStream host-clock timebase
/// — no AVCaptureSession with its own clock, no cross-domain PTS arithmetic.
///
/// **PTS strategy**: writer session starts at `.zero`; every appended sample
/// has its PTS rebased to `raw - firstSamplePTS - pauseOffset`. `pauseOffset`
/// grows by the wall-time of each pause so the post-resume timeline keeps
/// going monotonically without leaving a frozen frame on the way.
///
/// **Threading**: `SCStream` delivers buffers on `sampleQueue` (same queue
/// for all three output types). State mutations from public methods are
/// serialized through that queue so pause/resume and the sample callback
/// can't race on `state`.
final class RecordingEngine: NSObject, @unchecked Sendable {

    /// Aggregated config for one capture session. Built by `RecordingManager`
    /// from `RecordingPrefs` + the chosen `RecordingTarget`.
    struct Configuration {
        var target: RecordingTarget
        var frameRate: Int
        var codec: RecordingPrefs.Codec
        var quality: RecordingPrefs.Quality
        var fileFormat: RecordingPrefs.FileFormat
        var capturesSystemAudio: Bool
        var capturesMicrophone: Bool
        var showsCursor: Bool
        var highlightCursor: Bool
        var outputURL: URL
    }

    enum EngineError: Error, LocalizedError {
        case writerCreationFailed
        case captureStartFailed(Error)
        case alreadyRunning
        case noSamplesWritten

        var errorDescription: String? {
            switch self {
            case .writerCreationFailed:    return "Couldn't create the video file."
            case .captureStartFailed(let e): return "Capture failed to start: \(e.localizedDescription)"
            case .alreadyRunning:          return "A recording is already in progress."
            case .noSamplesWritten:        return "Recording stopped before any frames arrived."
            }
        }
    }

    // MARK: - State (sampleQueue-isolated)

    fileprivate enum State {
        case idle
        case running(SessionResources)
        case paused(SessionResources, pauseStartedAt: CMTime)
        case stopping
    }

    /// Long-lived AV objects created at start and torn down at stop.
    /// Held together so we can transition between running/paused without
    /// reaching across multiple optionals.
    fileprivate final class SessionResources: @unchecked Sendable {
        let stream: SCStream
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let systemAudioInput: AVAssetWriterInput?
        let micInput: AVAssetWriterInput?
        let outputURL: URL

        /// Reference PTS the FIRST sample of any type used. All subsequent
        /// appends subtract this to produce a 0-based timeline that matches
        /// `writer.startSession(atSourceTime: .zero)`.
        var firstSamplePTS: CMTime?
        /// Cumulative offset that paused frames removed from the timeline.
        /// Each resume bumps this by `(now - pauseStartedAt)` so the writer
        /// sees a continuous monotonically-increasing PTS.
        var pauseOffset: CMTime = .zero
        var hasStartedSession = false
        var videoSampleCount: Int = 0
        var systemAudioSampleCount: Int = 0
        var micSampleCount: Int = 0
        /// Last appended adjusted PTS — used to clamp out-of-order samples
        /// (e.g. SCK occasionally re-emits a frame with an earlier PTS).
        var lastAppendedPTS: CMTime = .negativeInfinity

        init(stream: SCStream,
             writer: AVAssetWriter,
             videoInput: AVAssetWriterInput,
             systemAudioInput: AVAssetWriterInput?,
             micInput: AVAssetWriterInput?,
             outputURL: URL) {
            self.stream = stream
            self.writer = writer
            self.videoInput = videoInput
            self.systemAudioInput = systemAudioInput
            self.micInput = micInput
            self.outputURL = outputURL
        }
    }

    fileprivate var state: State = .idle
    private let sampleQueue = DispatchQueue(label: "capybuddy.recording.samples", qos: .userInitiated)

    // MARK: - Public API

    /// Called on the main queue once finalize succeeds (or fails). The URL
    /// is the file the encoder finished writing to (same as
    /// `Configuration.outputURL` on success).
    var onFinish: (@MainActor @Sendable (Result<URL, Error>) -> Void)?

    /// Starts capture and returns once `SCStream.startCapture` has resolved.
    /// Throws if the writer can't be created or the stream can't start.
    func start(configuration: Configuration) async throws {
        let alreadyRunning: Bool = await withCheckedContinuation { cont in
            sampleQueue.async {
                if case .idle = self.state {
                    cont.resume(returning: false)
                } else {
                    cont.resume(returning: true)
                }
            }
        }
        if alreadyRunning { throw EngineError.alreadyRunning }

        let filter = try await Self.makeFilter(target: configuration.target)
        let conf = Self.makeStreamConfiguration(
            target: configuration.target,
            filter: filter,
            options: configuration
        )

        let fileType: AVFileType = configuration.fileFormat == .mov ? .mov : .mp4
        guard let writer = try? AVAssetWriter(outputURL: configuration.outputURL, fileType: fileType) else {
            throw EngineError.writerCreationFailed
        }
        // We previously set `movieFragmentInterval` to defend against
        // mid-record crashes leaving an unfinalized file, but it triggers
        // AVAssetWriter -11800 with SCK's variable frame delivery (a
        // ScreenCaptureKit frame only fires when the screen changes, so
        // the effective FPS swings wildly). Disabled — losing fragmented
        // playback on crash is acceptable; corrupting every recording is
        // not. See https://nonstrict.eu/blog/2023/avassetwriter-crash-when-using-CMAF/
        // for the related Intel/CMAF bug class.

        let videoInput = Self.makeVideoInput(configuration: configuration, streamConfiguration: conf)
        videoInput.expectsMediaDataInRealTime = true
        if writer.canAdd(videoInput) { writer.add(videoInput) }

        var systemAudioInput: AVAssetWriterInput?
        if configuration.capturesSystemAudio {
            let input = Self.makeAudioInput()
            if writer.canAdd(input) {
                writer.add(input)
                systemAudioInput = input
            }
        }

        var micInput: AVAssetWriterInput?
        if configuration.capturesMicrophone {
            let input = Self.makeAudioInput()
            if writer.canAdd(input) {
                writer.add(input)
                micInput = input
            }
        }

        let stream = SCStream(filter: filter, configuration: conf, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if configuration.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if configuration.capturesMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        }

        let session = SessionResources(
            stream: stream,
            writer: writer,
            videoInput: videoInput,
            systemAudioInput: systemAudioInput,
            micInput: micInput,
            outputURL: configuration.outputURL
        )

        // Install state BEFORE startCapture so any sample buffer that lands
        // immediately finds the session and not `.idle`.
        await withCheckedContinuation { cont in
            sampleQueue.async {
                self.state = .running(session)
                cont.resume()
            }
        }

        guard writer.startWriting() else {
            await withCheckedContinuation { cont in
                sampleQueue.async { self.state = .idle; cont.resume() }
            }
            throw EngineError.writerCreationFailed
        }
        // NOTE: writer.startSession is intentionally deferred to the first
        // delivered sample. AVAssetWriter's MovieHeaderMaker errors out at
        // finalize (-11800/-16341) when the session origin doesn't match
        // the actual sample PTS domain — rebasing everything to `.zero`
        // sounds clean but blows up on muxer edit-list construction.
        // QuickRecorder takes the same approach.

        do {
            try await stream.startCapture()
        } catch {
            writer.cancelWriting()
            await withCheckedContinuation { cont in
                sampleQueue.async { self.state = .idle; cont.resume() }
            }
            throw EngineError.captureStartFailed(error)
        }
    }

    /// Pauses sample appending. The writer stays open; subsequent frames are
    /// dropped until `resume()` shifts their PTS by the pause duration.
    func pause() {
        sampleQueue.async {
            guard case .running(let session) = self.state else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            self.state = .paused(session, pauseStartedAt: now)
        }
    }

    func resume() {
        sampleQueue.async {
            guard case .paused(let session, let pauseStart) = self.state else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            let delta = CMTimeSubtract(now, pauseStart)
            session.pauseOffset = CMTimeAdd(session.pauseOffset, delta)
            self.state = .running(session)
        }
    }

    /// Stops capture, finalizes the writer, and reports success/failure
    /// through `onFinish`. Safe to call from any queue.
    func stop() {
        finishCommon(discard: false)
    }

    /// Stops capture and deletes the partial output instead of finalizing.
    /// `onFinish` is not invoked — the manager treats discard as silent.
    func discard() {
        finishCommon(discard: true)
    }

    private func finishCommon(discard: Bool) {
        sampleQueue.async {
            let session: SessionResources
            switch self.state {
            case .running(let s):       session = s
            case .paused(let s, _):     session = s
            default: return
            }
            self.state = .stopping
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await session.stream.stopCapture()
                } catch {
                    NSLog("[Recording] stopCapture error: \(error)")
                }
                if discard {
                    session.writer.cancelWriting()
                    // cancelWriting leaves an empty file behind on some
                    // OS revs — sweep it explicitly so the save folder
                    // doesn't fill up with abandoned 0-byte MP4s.
                    try? FileManager.default.removeItem(at: session.outputURL)
                    self.sampleQueue.async { self.state = .idle }
                    return
                }
                // Only mark inputs that actually saw samples. An AVAssetWriter
                // input that was added to the writer but received zero
                // samples will cause `finishWriting` to fail with -11800.
                // Most common cause: system audio enabled but SCK never
                // delivered an audio buffer (silent system + early stop).
                session.videoInput.markAsFinished()
                if session.systemAudioSampleCount > 0 {
                    session.systemAudioInput?.markAsFinished()
                } else if let input = session.systemAudioInput {
                    NSLog("[Recording] system audio input got 0 samples; marking anyway")
                    input.markAsFinished()
                }
                if session.micSampleCount > 0 {
                    session.micInput?.markAsFinished()
                } else if let input = session.micInput {
                    NSLog("[Recording] mic input got 0 samples; marking anyway")
                    input.markAsFinished()
                }
                let sawSamples = session.videoSampleCount > 0
                await session.writer.finishWriting()
                let result: Result<URL, Error>
                if !sawSamples {
                    // Writer "completes" with a 0-byte file; treat that as
                    // an error rather than confusing the user with a
                    // useless file in their save folder.
                    try? FileManager.default.removeItem(at: session.outputURL)
                    result = .failure(EngineError.noSamplesWritten)
                } else if session.writer.status == .completed {
                    result = .success(session.writer.outputURL)
                } else {
                    result = .failure(session.writer.error ?? EngineError.writerCreationFailed)
                }
                self.sampleQueue.async { self.state = .idle }
                if let onFinish = self.onFinish {
                    await MainActor.run { onFinish(result) }
                }
            }
        }
    }

    // MARK: - Filter / configuration builders

    private static func makeFilter(target: RecordingTarget) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ourBundle = Bundle.main.bundleIdentifier ?? ""
        let excludedFromOurApp = content.applications.filter { $0.bundleIdentifier == ourBundle }
        switch target {
        case .display(let display):
            return SCContentFilter(display: display, excludingApplications: excludedFromOurApp, exceptingWindows: [])
        case .application(let display, let application, _):
            // Capture only this app's windows on this display. SCK has no
            // "all displays" app filter — picker pre-chose the display with
            // the most of its windows. The toolbar excluded-application
            // list isn't passed here because `including:` is an allow-list,
            // not a deny-list; our overlay windows are implicitly omitted.
            return SCContentFilter(display: display, including: [application], exceptingWindows: [])
        case .region(let display, _):
            return SCContentFilter(display: display, excludingApplications: excludedFromOurApp, exceptingWindows: [])
        }
    }

    private static func makeStreamConfiguration(
        target: RecordingTarget,
        filter: SCContentFilter,
        options: Configuration
    ) -> SCStreamConfiguration {
        let conf = SCStreamConfiguration()
        let scale = filter.pointPixelScale
        let pixelW: Int
        let pixelH: Int

        switch target {
        case .display:
            pixelW = Int(filter.contentRect.width * CGFloat(scale))
            pixelH = Int(filter.contentRect.height * CGFloat(scale))
        case .application(_, _, let rect),
             .region(_, let rect):
            // Crop sourceRect to the app's window union (or user-dragged
            // region). Without this, application mode falls back to SCK's
            // default "whole display, app pixels on a black backdrop" output
            // which looks like junk. sourceRect is in points, top-left
            // origin inside the display — flip from AppKit bottom-left.
            pixelW = Int(rect.width * CGFloat(scale))
            pixelH = Int(rect.height * CGFloat(scale))
            let displayHeightPoints = filter.contentRect.height
            let flippedY = displayHeightPoints - rect.origin.y - rect.height
            conf.sourceRect = CGRect(x: rect.origin.x, y: flippedY,
                                     width: rect.width, height: rect.height)
        }

        conf.width = max(2, pixelW)
        conf.height = max(2, pixelH)
        conf.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
        conf.queueDepth = 8
        conf.showsCursor = options.showsCursor
        // `showMouseClicks` is new in macOS 15 — adds the click-ripple ring
        // around the cursor when the user clicks. Maps directly to our
        // "highlightCursor" pref.
        if options.highlightCursor {
            conf.showMouseClicks = true
        }
        conf.pixelFormat = kCVPixelFormatType_32BGRA
        conf.colorSpaceName = CGColorSpace.sRGB
        conf.capturesAudio = options.capturesSystemAudio
        if options.capturesSystemAudio {
            conf.sampleRate = 48_000
            conf.channelCount = 2
        }
        // Native ScreenCaptureKit microphone capture (macOS 15+) — keeps the
        // mic on the same host-clock timebase as the screen feed, which is
        // why we don't need a separate AVCaptureSession + clock-translation
        // dance anymore.
        if options.capturesMicrophone {
            conf.captureMicrophone = true
            conf.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }
        return conf
    }

    private static func makeVideoInput(
        configuration: Configuration,
        streamConfiguration conf: SCStreamConfiguration
    ) -> AVAssetWriterInput {
        let codec: AVVideoCodecType = configuration.codec == .hevc ? .hevc : .h264
        // Bitrate target: pixels-per-second × bits-per-pixel multiplier.
        // Roughly H.264 Medium ≈ 0.07 bpp; HEVC Medium ≈ 0.04 bpp.
        let baseBpp: Double = configuration.codec == .hevc ? 0.04 : 0.07
        let bpp = baseBpp * configuration.quality.multiplier
        let pixels = Double(conf.width) * Double(conf.height)
        let bitrate = max(800_000, Int(pixels * Double(configuration.frameRate) * bpp))

        let settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: conf.width,
            AVVideoHeightKey: conf.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: configuration.frameRate
            ] as [String: Any]
        ]
        return AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    }

    private static func makeAudioInput() -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 192_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }

    // MARK: - PTS handling

    /// Returns the sample buffer to actually append. Keeps SCK's host-clock
    /// timestamps untouched in the common case; only allocates a new
    /// buffer with shifted timing when we're past at least one pause.
    /// Returns nil if the buffer should be dropped.
    ///
    /// First-sample contract: the FIRST valid sample of any type sets
    /// `firstSamplePTS` AND starts the writer session at that PTS. From
    /// then on `firstSamplePTS` is the writer's t=0 reference. All later
    /// appends must have PTS >= firstSamplePTS - pauseOffset.
    private func adjustedSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        session: SessionResources
    ) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return nil }

        if !session.hasStartedSession {
            session.firstSamplePTS = pts
            session.writer.startSession(atSourceTime: pts)
            session.hasStartedSession = true
        }
        guard let basePTS = session.firstSamplePTS else { return nil }

        // Fast path — no pause has occurred yet, just verify monotonicity
        // and pass the original sample buffer through to the writer.
        if session.pauseOffset == .zero {
            if pts < basePTS { return nil }
            return sampleBuffer
        }

        // Slow path — shift PTS backward to close the gap from paused time.
        let adjustedPTS = CMTimeSubtract(pts, session.pauseOffset)
        if adjustedPTS < basePTS { return nil }

        var timing = CMSampleTimingInfo()
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 1, arrayToFill: &timing, entriesNeededOut: &count)
        timing.presentationTimeStamp = adjustedPTS

        var adjusted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &adjusted
        )
        return adjusted
    }
}

// MARK: - SCStreamOutput

extension RecordingEngine: SCStreamOutput, SCStreamDelegate {

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        guard case .running(let session) = state else { return }

        // Filter out frames the system marked invalid (e.g. status .idle —
        // SCK delivers an empty frame between scene changes).
        if type == .screen,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let info = attachments.first,
           let rawStatus = info[.status] as? Int,
           let status = SCFrameStatus(rawValue: rawStatus),
           status != .complete {
            return
        }

        // Session start happens lazily inside `adjustedSampleBuffer` —
        // the first valid sample of any type seeds firstSamplePTS and
        // calls writer.startSession at that exact host-clock time.
        guard let adjusted = adjustedSampleBuffer(sampleBuffer, session: session) else { return }

        // Drop late/duplicate samples per-track. AVAssetWriter rejects
        // non-monotonic PTSs and an error from one append marks the entire
        // input as failed.
        let target: AVAssetWriterInput?
        switch type {
        case .screen:     target = session.videoInput
        case .audio:      target = session.systemAudioInput
        case .microphone: target = session.micInput
        default:          target = nil
        }
        guard let input = target, input.isReadyForMoreMediaData else { return }
        let appendedPTS = CMSampleBufferGetPresentationTimeStamp(adjusted)
        if appendedPTS <= session.lastAppendedPTS, type == .screen {
            return
        }
        // If the writer already failed (encoder error mid-record, etc.)
        // continuing to append is a waste — bail and let stop() report
        // the underlying error cleanly.
        if session.writer.status == .failed {
            NSLog("[Recording] writer failed mid-record: \(session.writer.error?.localizedDescription ?? "unknown")")
            return
        }
        if input.append(adjusted) {
            switch type {
            case .screen:
                session.lastAppendedPTS = appendedPTS
                session.videoSampleCount &+= 1
            case .audio:
                session.systemAudioSampleCount &+= 1
            case .microphone:
                session.micSampleCount &+= 1
            default:
                break
            }
        } else {
            NSLog("[Recording] append failed for type \(type): \(session.writer.error?.localizedDescription ?? "unknown")")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Recording] stream stopped with error: \(error)")
        // The writer is finalized through stop(); just bail without crashing
        // if the stream died on its own (display disconnected, etc.).
        sampleQueue.async {
            if case .running = self.state {
                // Promote to stopping; let stop() finalize.
                self.stop()
            }
        }
    }
}
