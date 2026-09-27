// take. Capture and writing. Made with Claude Code.
import AVFoundation
import CoreImage

// MARK: - Engine

final class Engine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    enum Failure: LocalizedError {
        case writer
        var errorDescription: String? { "The recording could not be written." }
    }

    let session = AVCaptureSession()
    let q = DispatchQueue(label: "take.capture", qos: .userInteractive)
    let display: AVSampleBufferDisplayLayer

    var onLevel: ((Float, Float) -> Void)?
    var onFrame: ((CGSize) -> Void)?
    var onLive: (() -> Void)?
    var onSaved: ((URL?, Error?, Bool) -> Void)?
    /// The frame rate the camera actually delivers after a format change, on the main queue.
    var onFps: ((Int) -> Void)?
    /// Every audio buffer, on the capture queue. Feeds the speech recogniser.
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onLog: ((String) -> Void)?

    private let videoOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private var vIn: AVCaptureDeviceInput?
    private var aIn: AVCaptureDeviceInput?
    private let ci = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var turns = 0

    private enum Rec { case idle, armed(URL), live, finishing }
    private var rec = Rec.idle
    private var writer: AVAssetWriter?
    private var wv: AVAssetWriterInput?
    private var wa: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var writerSize = CGSize.zero
    private var start = CMTime.invalid
    private var audioFormat: CMFormatDescription?
    private var levelTick = 0

    init(display: AVSampleBufferDisplayLayer) {
        self.display = display
        super.init()
        videoOut.alwaysDiscardsLateVideoFrames = true
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOut.setSampleBufferDelegate(self, queue: q)
        audioOut.setSampleBufferDelegate(self, queue: q)
    }

    static var videoDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    static var audioDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified).devices
    }

    func setTurns(_ n: Int) { q.async { self.turns = ((n % 4) + 4) % 4 } }

    /// Output shape, width over height: 9:16, 4:5, 1:1 or 16:9. The largest centred crop of the camera frame.
    private var aspect = CGSize(width: 9, height: 16)
    func setAspect(_ a: CGSize) { q.async { self.aspect = a } }

    func use(video: AVCaptureDevice?, audio: AVCaptureDevice?, fps: Int) {
        q.async { [self] in
            session.beginConfiguration()
            if let i = vIn { session.removeInput(i); vIn = nil }
            if let i = aIn { session.removeInput(i); aIn = nil }
            if let d = video {
                do {
                    let i = try AVCaptureDeviceInput(device: d)
                    if session.canAddInput(i) { session.addInput(i); vIn = i } else { onLog?("camera \(d.localizedName): cannot add input") }
                } catch {
                    onLog?("camera \(d.localizedName): \(error.localizedDescription)")
                }
            }
            if let d = audio, let i = try? AVCaptureDeviceInput(device: d), session.canAddInput(i) {
                session.addInput(i)
                aIn = i
            }
            if !session.outputs.contains(videoOut), session.canAddOutput(videoOut) { session.addOutput(videoOut) }
            if !session.outputs.contains(audioOut), session.canAddOutput(audioOut) { session.addOutput(audioOut) }
            session.commitConfiguration()
            audioFormat = nil
            if !session.isRunning { session.startRunning() }
            if let d = vIn?.device, let real = Engine.pickBestFormat(d, fps: fps) {
                DispatchQueue.main.async { self.onFps?(real) }
            }
        }
    }

    private static func area(_ f: AVCaptureDevice.Format) -> Int {
        let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        return Int(d.width) * Int(d.height)
    }

    private static func fps(_ f: AVCaptureDevice.Format) -> Double {
        f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    private static func is420(_ f: AVCaptureDevice.Format) -> Int {
        CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 1 : 0
    }

    private static func exact(_ f: AVCaptureDevice.Format, _ want: Double) -> Int {
        f.videoSupportedFrameRateRanges.contains { abs($0.maxFrameRate - want) < 0.5 } ? 1 : 0
    }

    /// The largest format that reaches the requested rate. Only when none does, the largest one at its own top rate.
    static func chooseFormat(_ formats: [AVCaptureDevice.Format], fps want: Int) -> (AVCaptureDevice.Format, CMTime?)? {
        let w = Double(want)
        let usable = formats.filter { fps($0) >= 24 }
        let fast = usable.filter { fps($0) >= w - 0.5 }
        let pool = fast.isEmpty ? usable : fast
        guard let best = pool.max(by: { (area($0), is420($0), exact($0, w), fps($0)) < (area($1), is420($1), exact($1, w), fps($1)) })
        else { return nil }
        let ranges = best.videoSupportedFrameRateRanges
        // A range that tops out at the rate keeps the device's own timing (29.97 stays 29.97).
        // A range that spans it gets exactly that rate. Otherwise the nearest top rate.
        let duration: CMTime?
        if let r = ranges.first(where: { abs($0.maxFrameRate - w) < 0.5 }) {
            duration = r.minFrameDuration
        } else if ranges.contains(where: { $0.minFrameRate <= w && w <= $0.maxFrameRate }) {
            duration = CMTime(value: 1, timescale: CMTimeScale(want))
        } else {
            duration = ranges.min { abs($0.maxFrameRate - w) < abs($1.maxFrameRate - w) }?.minFrameDuration
        }
        return (best, duration)
    }

    /// Returns the frame rate the camera now delivers.
    private static func pickBestFormat(_ d: AVCaptureDevice, fps want: Int) -> Int? {
        guard let (best, duration) = chooseFormat(d.formats, fps: want), (try? d.lockForConfiguration()) != nil else { return nil }
        d.activeFormat = best
        if let duration {
            d.activeVideoMinFrameDuration = duration
            d.activeVideoMaxFrameDuration = duration
        }
        let real = d.activeVideoMinFrameDuration.seconds
        d.unlockForConfiguration()
        return real > 0 ? Int((1 / real).rounded()) : nil
    }

    // MARK: Recording

    func record(to url: URL) {
        q.async { if case .idle = self.rec { self.rec = .armed(url) } }
    }

    /// Stops the take. `endAt` trims everything after that media time (the spoken command).
    /// `discard` moves the finished file into a `discarded` folder next to it instead of keeping it.
    func stop(endAt: CMTime? = nil, discard: Bool = false) {
        q.async { [self] in
            switch rec {
            case .armed:
                rec = .idle
                DispatchQueue.main.async { self.onSaved?(nil, nil, discard) }
            case .live:
                guard let w = writer else {
                    rec = .idle
                    DispatchQueue.main.async { self.onSaved?(nil, nil, discard) }
                    return
                }
                guard w.status == .writing else { fail(discard: discard); return }
                rec = .finishing
                if let t = endAt, t.isValid, CMTimeCompare(t, CMTimeAdd(start, CMTime(seconds: 0.5, preferredTimescale: 600))) > 0 {
                    w.endSession(atSourceTime: t)
                }
                wv?.markAsFinished()
                wa?.markAsFinished()
                w.finishWriting { [self] in
                    q.async { [self] in
                        var url: URL? = w.outputURL
                        let err: Error? = w.status == .completed ? nil : (w.error ?? Failure.writer)
                        if err != nil {
                            // An unfinished .mov has no index and never plays. Do not leave it behind.
                            try? FileManager.default.removeItem(at: w.outputURL)
                            url = nil
                        } else if discard, let u = url {
                            url = Engine.moveToDiscarded(u)
                        }
                        teardown()
                        rec = .idle
                        DispatchQueue.main.async { self.onSaved?(url, err, discard) }
                    }
                }
            case .idle:
                // Nothing is being written (a failure was already reported). Keep the caller in step.
                DispatchQueue.main.async { self.onSaved?(nil, nil, discard) }
            case .finishing:
                break
            }
        }
    }

    /// Capture queue. The writer stopped accepting media: drop the partial file and say so at once, not at Stop.
    private func fail(discard: Bool = false) {
        guard let w = writer else { return }
        let err: Error = w.error ?? Failure.writer
        if w.status == .writing { w.cancelWriting() }
        try? FileManager.default.removeItem(at: w.outputURL)
        teardown()
        rec = .idle
        DispatchQueue.main.async { self.onSaved?(nil, err, discard) }
    }

    private static func moveToDiscarded(_ url: URL) -> URL {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent().appendingPathComponent("discarded")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = url.deletingPathExtension().lastPathComponent
        var target = dir.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = dir.appendingPathComponent("\(base)-\(n).mov")
            n += 1
        }
        do { try fm.moveItem(at: url, to: target); return target } catch { return url }
    }

    private func teardown() {
        writer = nil; wv = nil; wa = nil; adaptor = nil
        start = .invalid; writerSize = .zero
    }

    /// AAC for any input. AAC encodes at 48 kHz at most, so 88.2, 96 and 192 kHz interfaces are resampled to 48.
    /// Below 44.1 kHz (AirPods, Bluetooth headsets at 16 or 24) a fixed bitrate is rejected, so the encoder picks its own.
    static func audioSettings(_ asbd: AudioStreamBasicDescription) -> [String: Any] {
        let ch = max(1, min(Int(asbd.mChannelsPerFrame), 2))
        let rate = min(asbd.mSampleRate, 48_000)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = ch == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: ch,
            AVSampleRateKey: rate,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
        if rate >= 44_100 { settings[AVEncoderBitRateKey] = ch == 1 ? 128_000 : 256_000 }
        return settings
    }

    private func begin(_ url: URL, _ size: CGSize, _ pts: CMTime) throws {
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let bitrate = size.width * size.height > 3_000_000 ? 45_000_000 : 18_000_000
        let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
        ])
        v.expectsMediaDataInRealTime = true
        guard w.canAdd(v) else { throw Failure.writer }
        w.add(v)
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: nil)

        var a: AVAssetWriterInput?
        if let f = audioFormat, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
            let settings = Engine.audioSettings(asbd)
            // A format AAC cannot take would raise inside AVAssetWriterInput. Then the take is video only.
            if w.canApply(outputSettings: settings, forMediaType: .audio) {
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                ai.expectsMediaDataInRealTime = true
                if w.canAdd(ai) { w.add(ai); a = ai }
            }
        }

        guard w.startWriting() else { throw w.error ?? Failure.writer }
        w.startSession(atSourceTime: pts)
        writer = w; wv = v; wa = a; adaptor = ad
        start = pts; writerSize = size
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOut { audio(sb, connection); return }
        guard let src = CMSampleBufferGetImageBuffer(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)

        let orientation: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        var img = CIImage(cvPixelBuffer: src).oriented(orientation[turns])
        let e = img.extent
        let (cw, ch) = Engine.cropSize(Int(e.width), Int(e.height), aspect)
        guard cw >= 2, ch >= 2 else { return }
        let w = CGFloat(cw), h = CGFloat(ch)
        let crop = CGRect(x: e.minX + floor((e.width - w) / 2), y: e.minY + floor((e.height - h) / 2), width: w, height: h)
        img = img.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let size = CGSize(width: w, height: h)

        guard let out = buffer(size) else { return }
        ci.render(img, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
        show(out, pts)
        DispatchQueue.main.async { self.onFrame?(size) }
        write(out, pts, size)
    }

    /// The largest centred crop of a `width` x `height` frame in this shape, even on both sides. Integer maths:
    /// the full side stays whole (1920 x 1080 to 9:16 is 608 x 1080, not 606 x 1078), the other side is the nearest even pixel.
    static func cropSize(_ width: Int, _ height: Int, _ shape: CGSize) -> (Int, Int) {
        let a = max(1, Int(shape.width.rounded())), b = max(1, Int(shape.height.rounded()))
        let fullW = width & ~1, fullH = height & ~1
        if width * b >= height * a {
            return (min(fullW, (fullH * a + b) / (2 * b) * 2), fullH)
        }
        return (fullW, min(fullH, (fullW * b + a) / (2 * a) * 2))
    }

    private func buffer(_ size: CGSize) -> CVPixelBuffer? {
        if pool == nil || size != poolSize {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            poolSize = size
        }
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    private func show(_ pb: CVPixelBuffer, _ pts: CMTime) {
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let fmt else { return }
        var t = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sbuf: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt,
                                                 sampleTiming: &t, sampleBufferOut: &sbuf)
        guard let sbuf else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: true), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let r = display.sampleBufferRenderer
        if r.status == .failed { r.flush() }
        r.enqueue(sbuf)
    }

    private func write(_ pb: CVPixelBuffer, _ pts: CMTime, _ size: CGSize) {
        if case .armed(let url) = rec {
            do {
                try begin(url, size, pts)
                rec = .live
                DispatchQueue.main.async { self.onLive?() }
            } catch {
                rec = .idle
                teardown()
                DispatchQueue.main.async { self.onSaved?(nil, error, false) }
                return
            }
        }
        guard case .live = rec else { return }
        if writer?.status == .failed { fail(); return }
        guard let wv, let adaptor, wv.isReadyForMoreMediaData, size == writerSize else { return }
        adaptor.append(pb, withPresentationTime: pts)
    }

    private func audio(_ sb: CMSampleBuffer, _ c: AVCaptureConnection) {
        onAudio?(sb)
        if audioFormat == nil { audioFormat = CMSampleBufferGetFormatDescription(sb) }
        var avg: Float = -160, peak: Float = -160
        for ch in c.audioChannels {
            avg = max(avg, ch.averagePowerLevel)
            peak = max(peak, ch.peakHoldLevel)
        }
        levelTick += 1
        if levelTick % 2 == 0 { DispatchQueue.main.async { self.onLevel?(avg, peak) } }
        guard case .live = rec else { return }
        if writer?.status == .failed { fail(); return }
        guard let wa, wa.isReadyForMoreMediaData else { return }
        if CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb), start) >= 0 { wa.append(sb) }
    }
}

