import CoreMedia
import CoreVideo
import Foundation
import WebRTC

/// Real-time pipeline: WebRTC (libwebrtc) with hardware H.264.
///
/// Works on plain `http://` pages – unlike WebCodecs, browsers offer `RTCPeerConnection`
/// without a secure context – and gives the lowest latency without any setup:
/// a jitter buffer of a few milliseconds, built-in congestion control, keyframes on
/// demand (RTCP PLI). Every device gets its own peer connection; signaling (SDP and
/// ICE candidates) runs over the existing WebSocket as `{"type":"rtc-…"}` messages.
final class WebRTCPipeline: NSObject, FramePipelineProtocol {
    var onPacket: ((Data, Data?, Bool) -> Void)?   // unused – media flows over WebRTC
    var hasReceivers: () -> Bool = { true }
    /// Sends a signaling message (JSON) to one device
    var sendSignal: ((UUID, String) -> Void)?

    private static let debugLogger = RTCCallbackLogger()

    private static let factory: RTCPeerConnectionFactory = {
        // Tell browsers to show every frame as soon as it is decoded (RTP playout-delay
        // extension = 0). Without it Chrome keeps ~80 ms of frames in its playout buffer,
        // which `jitterBufferTarget = 0` on the page alone does not remove.
        RTCInitFieldTrialDictionary(["WebRTC-ForcePlayoutDelay": "min_ms:0,max_ms:0"])
        RTCInitializeSSL()
        // Debugging aid: WEBSCREEN_RTC_LOG=1 prints libwebrtc's log to stderr
        if ProcessInfo.processInfo.environment["WEBSCREEN_RTC_LOG"] != nil {
            debugLogger.severity = .info
            debugLogger.start { message in FileHandle.standardError.write(Data(message.utf8)) }
        }
        return RTCPeerConnectionFactory(encoderFactory: ScreenEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    private let source: RTCVideoSource
    private let capturer: RTCVideoCapturer
    private let queue = DispatchQueue(label: "webscreen.webrtc", qos: .userInteractive)
    private let lock = NSLock()
    private var peers: [UUID: Peer] = [:]
    private var peerCount = 0
    private var maxBitrate: Int
    private var fps: Int
    private var stopped = false

    // Steady frame rate: ScreenCaptureKit only delivers frames when something changes.
    // A stream that goes quiet makes the encoder, the bandwidth estimate and the browser's
    // decoder idle, so the first movement afterwards (dragging a window over, moving the
    // pointer in) stutters while everything ramps up again. Repeating the last frame keeps
    // the stream at the chosen frame rate all the time – identical frames cost almost no
    // bandwidth, and they also let the encoder sharpen areas that just changed.
    private var lastBuffer: CVPixelBuffer?
    private var lastFrameTime = DispatchTime.now()
    private var refreshTimer: DispatchSourceTimer?
    private var frameInterval: Double
    /// Off: only send frames when something changes (saves a little power); areas that
    /// just changed are still sharpened for a moment
    private var steady: Bool
    private var refreshesLeft = 0
    private static let refreshAfterChange = 1.0   // seconds of sharpening frames when not steady

    init(width: Int, height: Int, fps: Int, bitrate: Int, steady: Bool) {
        source = Self.factory.videoSource(forScreenCast: true)
        source.adaptOutputFormat(toWidth: Int32(width), height: Int32(height), fps: Int32(fps))
        capturer = RTCVideoCapturer(delegate: source)
        maxBitrate = bitrate
        self.fps = fps
        frameInterval = 1.0 / Double(max(fps, 1))
        self.steady = steady
        super.init()

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + frameInterval, repeating: frameInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.refreshIfIdle() }
        timer.resume()
        refreshTimer = timer
    }

    deinit {
        refreshTimer?.cancel()
    }

    private func refreshIfIdle() {
        lock.lock()
        let active = peerCount > 0 && !stopped
        // Only fill gaps – a real frame that arrived within this interval wins
        let idle = DispatchTime.now().uptimeNanoseconds - lastFrameTime.uptimeNanoseconds > UInt64(frameInterval * 0.9e9)
        let buffer = (active && idle && (steady || refreshesLeft > 0)) ? lastBuffer : nil
        if buffer != nil {
            lastFrameTime = .now()
            if !steady { refreshesLeft -= 1 }
        }
        lock.unlock()
        if let buffer { deliver(buffer) }
    }

    private func deliver(_ pixelBuffer: CVPixelBuffer) {
        let buffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let nanos = Int64(CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1_000_000_000)
        source.capturer(capturer, didCapture: RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: nanos))
    }

    // MARK: FramePipelineProtocol

    func submit(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        let active = peerCount > 0 && !stopped
        lastBuffer = pixelBuffer
        lastFrameTime = .now()
        refreshesLeft = Int(Self.refreshAfterChange / frameInterval)
        lock.unlock()
        guard active else { return }
        deliver(pixelBuffer)
    }

    /// Keyframes are requested by the browser itself (RTCP PLI/FIR)
    func requestSync() {}

    func stop() {
        refreshTimer?.cancel()
        queue.sync {
            lock.lock(); stopped = true; peerCount = 0; lastBuffer = nil; lock.unlock()
            for peer in peers.values { peer.connection.close() }
            peers.removeAll()
        }
    }

    /// Bitrate and frame rate on the fly – no renegotiation needed
    func update(fps: Int, bitrate: Int, steady: Bool) {
        queue.async {
            self.fps = fps
            self.maxBitrate = bitrate
            self.lock.lock()
            self.frameInterval = 1.0 / Double(max(fps, 1))
            self.steady = steady
            self.lock.unlock()
            self.refreshTimer?.schedule(deadline: .now() + self.frameInterval, repeating: self.frameInterval,
                                        leeway: .milliseconds(1))
            for peer in self.peers.values { self.applyEncoding(to: peer) }
        }
    }

    // MARK: Devices

    /// A device was assigned to this screen → offer it a stream
    func attach(_ client: UUID) {
        queue.async {
            guard !self.stopped else { return }
            self.removePeer(client)

            let config = RTCConfiguration()
            config.sdpSemantics = .unifiedPlan
            config.bundlePolicy = .maxBundle
            config.rtcpMuxPolicy = .require
            config.iceServers = []                    // local network: host candidates only
            config.continualGatheringPolicy = .gatherOnce
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            let peer = Peer(client: client, pipeline: self)
            guard let connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: peer) else { return }
            peer.connection = connection

            let track = Self.factory.videoTrack(with: self.source, trackId: "screen")
            let init_ = RTCRtpTransceiverInit()
            init_.direction = .sendOnly
            init_.streamIds = ["webscreen"]
            peer.transceiver = connection.addTransceiver(with: track, init: init_)
            self.applyEncoding(to: peer)

            self.peers[client] = peer
            self.lock.lock()
            self.peerCount = self.peers.count
            self.refreshesLeft = Int(Self.refreshAfterChange / self.frameInterval)   // first picture right away
            self.lock.unlock()

            connection.offer(for: constraints) { description, error in
                guard let description, error == nil else { return }
                connection.setLocalDescription(description) { error in
                    guard error == nil else { return }
                    self.signal(client, ["type": "rtc-offer", "sdp": description.sdp])
                }
            }
        }
    }

    func detach(_ client: UUID) {
        queue.async { self.removePeer(client) }
    }

    /// Signaling message from the browser
    func handleSignal(_ client: UUID, json: String) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let type = object["type"] as? String else { return }
        queue.async {
            guard let peer = self.peers[client], let connection = peer.connection else { return }
            switch type {
            case "rtc-answer":
                guard let sdp = object["sdp"] as? String else { return }
                let answer = RTCSessionDescription(type: .answer, sdp: Self.tuneAnswer(sdp, maxKbps: self.maxBitrate / 1000))
                connection.setRemoteDescription(answer) { error in
                    if let error { NSLog("WebScreen WebRTC: remote description failed: \(error)") }
                }
            case "rtc-candidate":
                guard let candidate = object["candidate"] as? String, !candidate.isEmpty else { return }
                let ice = RTCIceCandidate(sdp: candidate,
                                          sdpMLineIndex: Int32((object["sdpMLineIndex"] as? NSNumber)?.intValue ?? 0),
                                          sdpMid: object["sdpMid"] as? String)
                connection.add(ice) { _ in }
            default:
                break
            }
        }
    }

    // MARK: Internals

    private func removePeer(_ client: UUID) {
        guard let peer = peers.removeValue(forKey: client) else { return }
        peer.connection?.close()
        lock.lock(); peerCount = peers.count; lock.unlock()
    }

    fileprivate func signal(_ client: UUID, _ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        sendSignal?(client, json)
    }

    private func applyEncoding(to peer: Peer) {
        guard let sender = peer.transceiver?.sender else { return }
        let parameters = sender.parameters
        // Screen content: keep text sharp and rather drop frames than resolution
        parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: maxBitrate)
            encoding.maxFramerate = NSNumber(value: fps)
            encoding.networkPriority = .high
            encoding.bitratePriority = 4
        }
        sender.parameters = parameters
    }

    /// Start at full bitrate and never estimate below half of it: libwebrtc sends each
    /// frame paced at 2.5× the estimated bandwidth. On a mostly still screen the estimate
    /// sinks, and the next big change then trickles out over 10+ ms – which the browser
    /// answers with a bigger playout buffer. A home network carries this easily; on real
    /// congestion the browser's feedback still lowers the rate.
    private static func tuneAnswer(_ sdp: String, maxKbps: Int) -> String {
        let start = max(1000, maxKbps)
        let minimum = max(1000, maxKbps / 2)
        let lines = sdp.components(separatedBy: "\r\n")
        var h264Payloads = Set<String>()
        for line in lines where line.hasPrefix("a=rtpmap:") && line.contains("H264/90000") {
            if let id = line.dropFirst("a=rtpmap:".count).split(separator: " ").first { h264Payloads.insert(String(id)) }
        }
        return lines.map { line in
            guard line.hasPrefix("a=fmtp:"),
                  let id = line.dropFirst("a=fmtp:".count).split(separator: " ").first,
                  h264Payloads.contains(String(id)), !line.contains("x-google-start-bitrate") else { return line }
            return line + ";x-google-start-bitrate=\(start);x-google-min-bitrate=\(minimum);x-google-max-bitrate=\(start)"
        }.joined(separator: "\r\n")
    }

    // MARK: Peer

    private final class Peer: NSObject, RTCPeerConnectionDelegate {
        let client: UUID
        weak var pipeline: WebRTCPipeline?
        var connection: RTCPeerConnection!
        var transceiver: RTCRtpTransceiver?

        init(client: UUID, pipeline: WebRTCPipeline) {
            self.client = client
            self.pipeline = pipeline
        }

        func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
            pipeline?.signal(client, ["type": "rtc-candidate", "candidate": candidate.sdp,
                                      "sdpMid": candidate.sdpMid ?? "0", "sdpMLineIndex": candidate.sdpMLineIndex])
        }

        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
            if newState == .complete { pipeline?.signal(client, ["type": "rtc-candidate", "candidate": ""]) }
        }

        func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
        func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
        func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    }
}

/// Hardware H.264 (VideoToolbox) at level 5.2, so Retina and 4K screens fit. Several
/// profiles, because browsers differ: Safari prefers Constrained High (640c), Chrome
/// often only lists High (6400), Constrained Baseline (42e0) works everywhere.
/// VP8 is the software fallback for browsers without H.264.
private final class ScreenEncoderFactory: NSObject, RTCVideoEncoderFactory {
    private static let h264Profiles = ["640c34", "640034", "42e034"].map { profile in
        RTCVideoCodecInfo(name: kRTCVideoCodecH264Name, parameters: [
            "profile-level-id": profile,
            "level-asymmetry-allowed": "1",
            "packetization-mode": "1",
        ])
    }
    private static let vp8 = RTCVideoCodecInfo(name: (kRTCVp8CodecName as String))

    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        if info.name == kRTCVideoCodecH264Name { return LowLatencyH264Encoder(codecInfo: Self.atLevel52(info)) }
        if info.name == (kRTCVp8CodecName as String) { return RTCVideoEncoderVP8.vp8Encoder() }
        return nil
    }

    /// Browsers answer with level 3.1 (max. 1280×720), and libwebrtc would configure the
    /// hardware encoder with exactly that – which fails for Retina/4K screens. With
    /// `level-asymmetry-allowed` the sender may use a higher level, so keep the
    /// negotiated profile and raise the level to 5.2.
    private static func atLevel52(_ info: RTCVideoCodecInfo) -> RTCVideoCodecInfo {
        guard let id = info.parameters["profile-level-id"], id.count == 6 else { return info }
        var parameters = info.parameters
        parameters["profile-level-id"] = String(id.prefix(4)) + "34"
        return RTCVideoCodecInfo(name: info.name, parameters: parameters)
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        Self.h264Profiles + [Self.vp8]
    }
}
