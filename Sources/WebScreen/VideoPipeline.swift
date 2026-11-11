import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Video pipeline (H.264 or HEVC): hardware encoder (VideoToolbox) → fragmented MP4
/// → Browser (Media Source Extensions).
///
/// Packets (big endian):
///   Init:   [u8 type=2][u8 codec string length][codec string ASCII][init segment (ftyp+moov)]
///   Frame:  [u8 type=3][u8 keyframe?][media segment (moof+mdat)]
///
/// Additionally for WebCodecs receivers (no container, decoded immediately):
///   Config: [u8 type=5][u8 codec string length][codec string ASCII][avcC/hvcC description]
///   Frame:  [u8 type=4][u8 keyframe?][u64 timestamp µs][access unit, length-prefixed NALUs]
final class VideoPipeline: FramePipelineProtocol {
    var onPacket: ((Data, Data?, Bool) -> Void)?
    /// Init segment for MSE and decoder configuration for WebCodecs
    var onInit: ((Data, Data) -> Void)?
    var hasReceivers: () -> Bool = { true }

    private let queue = DispatchQueue(label: "webscreen.h264", qos: .userInteractive)
    private let encoder: VideoEncoder
    private let muxer: FMP4Muxer
    private let adaptive: AdaptiveController
    private let maxBitrate: Int
    private var appliedBitrate: Int
    private var lastPixelBuffer: CVPixelBuffer?
    private var forceKey = true
    private var lastSyncRequest: UInt64 = 0
    private var stopped = false
    // Steady frame rate: repeat the last frame while nothing changes, so the browser's
    // player never runs dry and movement starts without a hitch (see `WebRTCPipeline`)
    private var steadyTimer: DispatchSourceTimer?
    private var lastFrameTime = DispatchTime.now()
    private let frameInterval: Double
    private var lastPTS = CMTime.negativeInfinity
    private var steady = false

    /// Repeated and captured frames mix – timestamps must still only go forward
    private func monotonic(_ pts: CMTime) -> CMTime {
        let minimum = lastPTS.isNumeric ? CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1000)) : pts
        let result = (pts.isNumeric && CMTimeCompare(pts, minimum) > 0) ? pts : minimum
        lastPTS = result
        return result
    }

    init(codec: StreamCodec, width: Int, height: Int, fps: Int, bitrate: Int, adaptive: AdaptiveController,
         steady: Bool) throws {
        frameInterval = 1.0 / Double(max(fps, 1))
        self.adaptive = adaptive
        self.maxBitrate = bitrate
        self.appliedBitrate = bitrate
        let hevc = codec == .hevc
        encoder = try VideoEncoder(hevc: hevc, width: width, height: height, fps: fps, bitrate: bitrate)
        muxer = FMP4Muxer(hevc: hevc, width: width, height: height, fps: fps)

        encoder.onConfig = { [weak self] config in
            guard let self else { return }
            let codecString = hevc ? Self.hevcCodecString(config) : Self.avcCodecString(config)
            var packet = Data([2, UInt8(codecString.utf8.count)])
            packet.append(Data(codecString.utf8))
            packet.append(self.muxer.initSegment(config: config))
            var raw = Data([5, UInt8(codecString.utf8.count)])
            raw.append(Data(codecString.utf8))
            raw.append(config)
            self.onInit?(packet, raw)
        }
        encoder.onFrame = { [weak self] sample, isKey, pts in
            guard let self else { return }
            var packet = Data([3, isKey ? 1 : 0])
            packet.append(self.muxer.mediaSegment(sample: sample, isKey: isKey))
            var raw = Data([4, isKey ? 1 : 0])
            let micros = pts.isNumeric ? UInt64(max(0, pts.seconds * 1_000_000)) : 0
            raw.appendBE(micros)
            raw.append(sample)
            self.onPacket?(packet, raw, isKey)
        }
        self.steady = steady
        if steady { startSteadyTimer() }
    }

    /// Current target bitrate in bit/s
    var currentBitrate: Int {
        max(1_000_000, Int(Double(maxBitrate) * adaptive.level))
    }

    private func startSteadyTimer() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + frameInterval / 2, repeating: frameInterval / 2, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.repeatIfIdle() }
        timer.resume()
        steadyTimer = timer
    }

    /// Runs on `queue`
    private func repeatIfIdle() {
        guard !stopped, let pixelBuffer = lastPixelBuffer, hasReceivers(), intervalElapsed else { return }
        encodeNow(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()))
        lastWasRepeat = true
    }

    /// The fMP4 muxer gives every frame the same duration (1/fps). More frames per second
    /// than that would make the video run ahead of real time and the browser buffer
    /// (= latency) grow – so a repeat only goes out when a whole interval passed without
    /// any frame (captured frames are limited to the frame rate by ScreenCaptureKit).
    private var intervalElapsed: Bool {
        // Captured frames jitter a little – only fill in once they have clearly stopped,
        // then keep repeating at the frame rate
        let factor = lastWasRepeat ? 0.95 : 1.5
        return DispatchTime.now().uptimeNanoseconds - lastFrameTime.uptimeNanoseconds > UInt64(frameInterval * factor * 1e9)
    }
    private var lastWasRepeat = false

    private func encodeNow(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lastFrameTime = .now()
        applyBitrateIfNeeded()
        let key = forceKey
        forceKey = false
        encoder.encode(pixelBuffer, pts: monotonic(pts), forceKeyFrame: key)
    }

    func submit(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        queue.async {
            guard !self.stopped else { return }
            self.lastPixelBuffer = pixelBuffer
            guard self.hasReceivers() else {
                self.forceKey = true
                return
            }
            // Captured frames always go out right away – only repeats give way
            self.lastWasRepeat = false
            self.encodeNow(pixelBuffer, pts: pts)
        }
    }

    /// Request a keyframe. If the screen is idle, the last image is re-encoded right away.
    func requestSync() {
        queue.async {
            guard !self.stopped else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now &- self.lastSyncRequest > 300_000_000, let pixelBuffer = self.lastPixelBuffer else {
                self.forceKey = true
                return
            }
            self.lastSyncRequest = now
            self.encoder.encode(pixelBuffer, pts: self.monotonic(CMClockGetTime(CMClockGetHostTimeClock())), forceKeyFrame: true)
        }
    }

    func stop() {
        steadyTimer?.cancel()
        queue.sync {
            stopped = true
            encoder.invalidate()
            lastPixelBuffer = nil
        }
    }

    /// "avc1.PPCCLL" from the avcC box
    static func avcCodecString(_ avcC: Data) -> String {
        let b = [UInt8](avcC)
        guard b.count >= 4 else { return "avc1.640028" }
        return String(format: "avc1.%02x%02x%02x", UInt32(b[1]), UInt32(b[2]), UInt32(b[3]))
    }

    /// "hvc1.<profile>.<compatibility>.<tier><level>.<constraints>" from the hvcC box (ISO/IEC 14496-15, Annex E)
    static func hevcCodecString(_ hvcC: Data) -> String {
        let b = [UInt8](hvcC)
        guard b.count >= 13 else { return "hvc1.1.6.L120.90" }
        let profileSpace = Int(b[1] >> 6)
        let tierFlag = (b[1] >> 5) & 0x1
        let profileIDC = Int(b[1] & 0x1F)
        var compatibility = UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5])
        // Bits in reverse order
        var reversed: UInt32 = 0
        for _ in 0..<32 {
            reversed = (reversed << 1) | (compatibility & 1)
            compatibility >>= 1
        }
        let level = Int(b[12])
        var constraints = Array(b[6...11])
        while let last = constraints.last, last == 0 { constraints.removeLast() }

        var parts = ["hvc1"]
        parts.append(["", "A", "B", "C"][profileSpace] + String(profileIDC))
        parts.append(String(reversed, radix: 16, uppercase: true))
        parts.append((tierFlag == 1 ? "H" : "L") + String(level))
        parts.append(contentsOf: constraints.map { String(format: "%02X", UInt32($0)) })
        return parts.joined(separator: ".")
    }

    private func applyBitrateIfNeeded() {
        let target = currentBitrate
        if abs(target - appliedBitrate) > appliedBitrate / 20 {
            encoder.setBitrate(target)
            appliedBitrate = target
        }
    }
}

// MARK: - Encoder

final class VideoEncoder {
    var onConfig: ((Data) -> Void)?
    var onFrame: ((Data, Bool, CMTime) -> Void)?

    private var session: VTCompressionSession?
    private var lastPTS: CMTime?
    private var lastDescription: Data?

    private let configKey: String
    /// Whether the session runs with low-latency rate control
    private(set) var isLowLatency = false

    init(hevc: Bool, width: Int, height: Int, fps: Int, bitrate: Int) throws {
        configKey = hevc ? "hvcC" : "avcC"
        // Low-latency rate control: no lookahead, every frame leaves the encoder as soon
        // as it is done. Falls back to the normal mode where the hardware can't do it.
        var session: VTCompressionSession?
        var status: OSStatus = noErr
        for lowLatency in [true, false] {
            var spec: [String: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true }
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height),
                codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &session
            )
            if status == noErr, session != nil {
                isLowLatency = lowLatency
                break
            }
        }
        guard status == noErr, let session else { throw WebScreenError.encoderFailed(status) }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // Never hold frames back inside the encoder
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        // Regular keyframes so the browser recovers quickly after dropouts
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 4) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 4 as CFNumber)
        self.session = session
        setBitrate(bitrate)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { invalidate() }

    func setBitrate(_ bitrate: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        let bytesPerSecond = Double(bitrate) * 1.5 / 8
        let limits = [NSNumber(value: bytesPerSecond), NSNumber(value: 1.0)] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts inputPTS: CMTime, forceKeyFrame: Bool) {
        guard let session else { return }
        var pts = inputPTS
        if let last = lastPTS, CMTimeCompare(pts, last) <= 0 {
            pts = CMTimeAdd(last, CMTime(value: 1, timescale: 1000))
        }
        lastPTS = pts

        let props: CFDictionary? = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
            duration: .invalid, frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.handle(sampleBuffer)
        }
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, let blockBuffer = sampleBuffer.dataBuffer else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKey = !notSync

        if isKey, let format = sampleBuffer.formatDescription,
           let atoms = CMFormatDescriptionGetExtension(
               format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
           ) as? [String: Any],
           let config = atoms[configKey] as? Data, config.count >= 4,
           config != lastDescription {
            lastDescription = config
            onConfig?(config)
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == noErr else { return }
        onFrame?(data, isKey, sampleBuffer.presentationTimeStamp)
    }
}

// MARK: - Fragmented MP4

/// Minimal fMP4 muxer for one H.264 or HEVC video track (ISO/IEC 14496-12/-15).
final class FMP4Muxer {
    private let hevc: Bool
    private let width: Int
    private let height: Int
    private let sampleDuration: UInt32
    private let timescale: UInt32 = 90_000
    private var sequence: UInt32 = 0
    private var decodeTime: UInt64 = 0

    init(hevc: Bool, width: Int, height: Int, fps: Int) {
        self.hevc = hevc
        self.width = width
        self.height = height
        self.sampleDuration = UInt32(90_000 / max(fps, 1))
    }

    /// `config` is the avcC or hvcC box (without box header) as delivered by VideoToolbox
    func initSegment(config: Data) -> Data {
        let sampleEntry = hevc ? "hvc1" : "avc1"
        let configBox = hevc ? "hvcC" : "avcC"
        let ftyp = box("ftyp") { d in
            d.ascii("isom"); d.appendBE(UInt32(0x200))
            d.ascii("isom"); d.ascii("iso6"); d.ascii(sampleEntry); d.ascii("mp41")
        }

        let mvhd = fullBox("mvhd", version: 0, flags: 0) { d in
            d.appendBE(UInt32(0)); d.appendBE(UInt32(0))          // creation/modification
            d.appendBE(UInt32(1000)); d.appendBE(UInt32(0))       // timescale, duration
            d.appendBE(UInt32(0x0001_0000)); d.appendBE(UInt16(0x0100)) // rate, volume
            d.zeros(10)                                           // reserved
            d.matrix()
            d.zeros(24)                                           // pre_defined
            d.appendBE(UInt32(2))                                 // next_track_ID
        }

        let tkhd = fullBox("tkhd", version: 0, flags: 0x000003) { d in
            d.appendBE(UInt32(0)); d.appendBE(UInt32(0))          // creation/modification
            d.appendBE(UInt32(1)); d.appendBE(UInt32(0))          // track_ID, reserved
            d.appendBE(UInt32(0))                                 // duration
            d.zeros(8)                                            // reserved
            d.appendBE(UInt16(0)); d.appendBE(UInt16(0))          // layer, alternate_group
            d.appendBE(UInt16(0)); d.appendBE(UInt16(0))          // volume, reserved
            d.matrix()
            d.appendBE(UInt32(width << 16)); d.appendBE(UInt32(height << 16))
        }

        let mdhd = fullBox("mdhd", version: 0, flags: 0) { d in
            d.appendBE(UInt32(0)); d.appendBE(UInt32(0))
            d.appendBE(timescale); d.appendBE(UInt32(0))
            d.appendBE(UInt16(0x55C4)); d.appendBE(UInt16(0))     // language "und"
        }

        let hdlr = fullBox("hdlr", version: 0, flags: 0) { d in
            d.appendBE(UInt32(0)); d.ascii("vide"); d.zeros(12)
            d.ascii("VideoHandler"); d.zeros(1)
        }

        let visualEntry = box(sampleEntry) { d in
            d.zeros(6); d.appendBE(UInt16(1))                     // reserved, data_reference_index
            d.zeros(16)                                           // pre_defined/reserved
            d.appendBE(UInt16(width)); d.appendBE(UInt16(height))
            d.appendBE(UInt32(0x0048_0000)); d.appendBE(UInt32(0x0048_0000)) // 72 dpi
            d.appendBE(UInt32(0)); d.appendBE(UInt16(1))          // reserved, frame_count
            d.zeros(32)                                           // compressorname
            d.appendBE(UInt16(0x0018)); d.appendBE(UInt16(0xFFFF))
            d.append(self.box(configBox) { $0.append(config) })
        }

        let stsd = fullBox("stsd", version: 0, flags: 0) { d in
            d.appendBE(UInt32(1)); d.append(visualEntry)
        }
        let stts = fullBox("stts", version: 0, flags: 0) { $0.appendBE(UInt32(0)) }
        let stsc = fullBox("stsc", version: 0, flags: 0) { $0.appendBE(UInt32(0)) }
        let stsz = fullBox("stsz", version: 0, flags: 0) { d in d.appendBE(UInt32(0)); d.appendBE(UInt32(0)) }
        let stco = fullBox("stco", version: 0, flags: 0) { $0.appendBE(UInt32(0)) }
        let stbl = box("stbl") { d in
            d.append(stsd); d.append(stts); d.append(stsc); d.append(stsz); d.append(stco)
        }

        let url = fullBox("url ", version: 0, flags: 1) { _ in }
        let dref = fullBox("dref", version: 0, flags: 0) { d in d.appendBE(UInt32(1)); d.append(url) }
        let dinf = box("dinf") { $0.append(dref) }
        let vmhd = fullBox("vmhd", version: 0, flags: 1) { $0.zeros(8) }
        let minf = box("minf") { d in d.append(vmhd); d.append(dinf); d.append(stbl) }
        let mdia = box("mdia") { d in d.append(mdhd); d.append(hdlr); d.append(minf) }
        let trak = box("trak") { d in d.append(tkhd); d.append(mdia) }

        let trex = fullBox("trex", version: 0, flags: 0) { d in
            d.appendBE(UInt32(1)); d.appendBE(UInt32(1))          // track_ID, sample description
            d.appendBE(UInt32(0)); d.appendBE(UInt32(0)); d.appendBE(UInt32(0))
        }
        let mvex = box("mvex") { $0.append(trex) }
        let moov = box("moov") { d in d.append(mvhd); d.append(trak); d.append(mvex) }

        sequence = 0
        decodeTime = 0
        var result = ftyp
        result.append(moov)
        return result
    }

    func mediaSegment(sample: Data, isKey: Bool) -> Data {
        sequence += 1
        let seq = sequence
        let time = decodeTime
        let duration = sampleDuration
        let sampleFlags: UInt32 = isKey ? 0x0200_0000 : 0x0101_0000

        let mfhd = fullBox("mfhd", version: 0, flags: 0) { $0.appendBE(seq) }
        let tfhd = fullBox("tfhd", version: 0, flags: 0x020000) { $0.appendBE(UInt32(1)) } // default-base-is-moof
        let tfdt = fullBox("tfdt", version: 1, flags: 0) { $0.appendBE(time) }

        func moof(dataOffset: Int32) -> Data {
            // data-offset | sample-duration | sample-size | sample-flags
            let trun = fullBox("trun", version: 0, flags: 0x000701) { d in
                d.appendBE(UInt32(1))
                d.appendBE(UInt32(bitPattern: dataOffset))
                d.appendBE(duration)
                d.appendBE(UInt32(sample.count))
                d.appendBE(sampleFlags)
            }
            let traf = box("traf") { d in d.append(tfhd); d.append(tfdt); d.append(trun) }
            return box("moof") { d in d.append(mfhd); d.append(traf) }
        }

        let size = moof(dataOffset: 0).count
        var result = moof(dataOffset: Int32(size + 8))
        result.append(box("mdat") { $0.append(sample) })
        decodeTime += UInt64(sampleDuration)
        return result
    }

    // MARK: Box helpers

    private func box(_ type: String, _ build: (inout Data) -> Void) -> Data {
        var payload = Data()
        build(&payload)
        var data = Data()
        data.appendBE(UInt32(8 + payload.count))
        data.ascii(type)
        data.append(payload)
        return data
    }

    private func fullBox(_ type: String, version: UInt8, flags: UInt32, _ build: (inout Data) -> Void) -> Data {
        box(type) { d in
            d.append(version)
            d.append(UInt8((flags >> 16) & 0xFF))
            d.append(UInt8((flags >> 8) & 0xFF))
            d.append(UInt8(flags & 0xFF))
            build(&d)
        }
    }
}

private extension Data {
    mutating func ascii(_ string: String) { append(contentsOf: Array(string.utf8)) }
    mutating func zeros(_ count: Int) { append(contentsOf: [UInt8](repeating: 0, count: count)) }
    mutating func matrix() {
        for value: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] {
            appendBE(value)
        }
    }
}
