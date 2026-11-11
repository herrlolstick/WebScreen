import CoreMedia
import Foundation
import VideoToolbox
import CGVirtualDisplayBridge
import WebRTC

/// H.264 encoder for WebRTC that uses VideoToolbox's low-latency mode.
///
/// libwebrtc's built-in `RTCVideoEncoderH264` sets up the hardware encoder in its normal
/// mode, which holds back a few frames (~40 ms at 60 Hz) before it outputs one. With
/// `EnableLowLatencyRateControl` (the mode FaceTime uses) every frame comes out right
/// after it went in – the same setup WebScreen's own H.264/HEVC pipeline uses.
final class LowLatencyH264Encoder: WSVideoEncoderBase {
    private let codecInfo: RTCVideoCodecInfo
    private var callback: RTCVideoEncoderCallback?
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var bitrate = 4_000_000
    private var framerate = 60
    private let lock = NSLock()

    // libwebrtc's return codes
    private static let ok = 0
    private static let error = -1
    private static let uninitialized = -7

    init(codecInfo: RTCVideoCodecInfo) {
        self.codecInfo = codecInfo
        super.init()
    }

    deinit {
        destroySession()
    }

    // MARK: RTCVideoEncoder

    override func setCallback(_ callback: RTCVideoEncoderCallback?) {
        lock.lock(); self.callback = callback; lock.unlock()
    }

    override func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        width = Int32(settings.width)
        height = Int32(settings.height)
        bitrate = Int(max(settings.startBitrate, 300)) * 1000
        framerate = Int(max(settings.maxFramerate, 1))
        return createSession() ? Self.ok : Self.error
    }

    override func stopEncoder() -> Int {
        destroySession()
        return Self.ok
    }

    override func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: RTCCodecSpecificInfo?, frameTypes: [NSNumber]) -> Int {
        guard let buffer = frame.buffer as? RTCCVPixelBuffer else { return Self.error }
        let pixelBuffer = buffer.pixelBuffer
        // The size can change (e.g. resolution of the screen changed) → new session
        let frameWidth = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let frameHeight = Int32(CVPixelBufferGetHeight(pixelBuffer))
        if frameWidth != width || frameHeight != height || session == nil {
            width = frameWidth
            height = frameHeight
            destroySession()
            guard createSession() else { return Self.error }
        }
        guard let session else { return Self.uninitialized }

        let forceKey = frameTypes.contains { $0.uintValue == RTCFrameType.videoFrameKey.rawValue }
        let properties: CFDictionary? = forceKey
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil

        let rtpTimestamp = UInt32(bitPattern: frame.timeStamp)
        let captureMs = frame.timeStampNs / 1_000_000
        let rotation = frame.rotation
        let encodeStart = Int64(Date().timeIntervalSince1970 * 1000)
        let pts = CMTime(value: frame.timeStampNs, timescale: 1_000_000_000)

        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.deliver(sample, rtpTimestamp: rtpTimestamp, captureMs: captureMs,
                         rotation: rotation, encodeStart: encodeStart)
        }
        return status == noErr ? Self.ok : Self.error
    }

    override func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        bitrate = Int(max(bitrateKbit, 300)) * 1000
        if framerate > 0 { self.framerate = Int(framerate) }
        if let session { applyRate(session) }
        return Int32(Self.ok)
    }

    override func implementationName() -> String { "VideoToolbox (low latency)" }

    /// No automatic resolution scaling – screen content stays sharp
    override func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }

    override var resolutionAlignment: Int { 1 }
    override var applyAlignmentToAllSimulcastLayers: Bool { false }
    override var supportsNativeHandle: Bool { true }

    // MARK: Session

    private func createSession() -> Bool {
        let spec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true,
        ]
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        var created: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        if status != noErr {
            // Older Macs: hardware encoder without the low-latency mode
            status = VTCompressionSessionCreate(
                allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        guard status == noErr, let created else {
            NSLog("WebScreen WebRTC: low-latency encoder unavailable (\(status))")
            return false
        }
        let profileID = codecInfo.parameters["profile-level-id"] ?? "42e034"
        let profile = profileID.hasPrefix("42") ? kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
                                                : kVTProfileLevel_H264_High_AutoLevel
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        // Keyframes come on request from the browser (PLI); a periodic one as a safety net
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 10 as CFNumber)
        applyRate(created)
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        return true
    }

    private func applyRate(_ session: VTCompressionSession) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: framerate as CFNumber)
    }

    private func destroySession() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    // MARK: Output

    private func deliver(_ sample: CMSampleBuffer, rtpTimestamp: UInt32, captureMs: Int64,
                         rotation: RTCVideoRotation, encodeStart: Int64) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        guard let annexB = Self.annexB(from: sample, includeParameterSets: isKey) else { return }

        let image = RTCEncodedImage()
        image.buffer = annexB
        image.encodedWidth = width
        image.encodedHeight = height
        image.timeStamp = rtpTimestamp
        image.captureTimeMs = captureMs
        image.frameType = isKey ? .videoFrameKey : .videoFrameDelta
        image.rotation = rotation
        image.contentType = .screenshare
        image.encodeStartMs = encodeStart
        image.encodeFinishMs = Int64(Date().timeIntervalSince1970 * 1000)

        let info = RTCCodecSpecificInfoH264()
        info.packetizationMode = .nonInterleaved
        lock.lock(); let callback = self.callback; lock.unlock()
        _ = callback?(image, info)
    }

    /// AVCC (length-prefixed NAL units) → Annex B (start codes), with SPS/PPS before keyframes
    private static func annexB(from sample: CMSampleBuffer, includeParameterSets: Bool) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()

        if includeParameterSets, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                                                                      parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                                                                      parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let pointer {
                    out.append(contentsOf: startCode)
                    out.append(pointer, count: size)
                }
            }
        }

        // Copy out – the block buffer may consist of several pieces
        let length = CMBlockBufferGetDataLength(block)
        var raw = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &raw) == kCMBlockBufferNoErr else {
            return nil
        }
        var offset = 0
        while offset + 4 <= length {
            let nalLength = Int(raw[offset]) << 24 | Int(raw[offset + 1]) << 16 | Int(raw[offset + 2]) << 8 | Int(raw[offset + 3])
            offset += 4
            guard nalLength > 0, offset + nalLength <= length else { break }
            out.append(contentsOf: startCode)
            out.append(contentsOf: raw[offset..<offset + nalLength])
            offset += nalLength
        }
        return out
    }
}
