import CoreMedia
import CoreVideo
import Foundation

/// Streaming method (setting)
enum StreamMode: String, CaseIterable, Identifiable {
    case realtime, jpeg, h264, hevc, videoAuto
    var id: String { rawValue }

    var title: String {
        switch self {
        case .realtime: return "Real-time"
        case .jpeg: return "JPEG"
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .videoAuto: return "Video auto"
        }
    }

    var isVideo: Bool { self != .jpeg }
}

/// Method actually used by a screen
enum StreamCodec: String, Equatable {
    case webrtc, jpeg, h264, hevc

    var title: String {
        switch self {
        case .webrtc: return "Real-time"
        case .jpeg: return "JPEG"
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }

    /// Largest width/height in pixels the hardware encoder can handle
    var maxDimension: Int {
        switch self {
        case .jpeg: return 16_384
        case .webrtc, .h264: return 4096
        case .hevc: return 8192
        }
    }
}

/// Common interface of both encoding pipelines
protocol FramePipelineProtocol: AnyObject {
    /// Finished packet for all receivers. The optional second packet is the same
    /// content for WebCodecs receivers (raw access unit instead of fMP4).
    /// `isSync` = full frame or keyframe where a receiver can (re)join the stream.
    var onPacket: ((Data, Data?, Bool) -> Void)? { get set }
    var hasReceivers: () -> Bool { get set }
    func submit(_ pixelBuffer: CVPixelBuffer, pts: CMTime)
    /// Make the next packet an entry point (even if nothing is moving)
    func requestSync()
    func stop()
}

/// Controls quality using AIMD (like TCP): down on congestion,
/// back up afterwards. `level` lies between `minimumLevel` and 1.
final class AdaptiveController {
    let enabled: Bool
    var onChange: ((Double) -> Void)?

    private let lock = NSLock()
    private var _level = 1.0
    private var calmSeconds = 0
    private var congestedSeconds = 0
    static let minimumLevel = 0.45

    init(enabled: Bool) {
        self.enabled = enabled
    }

    var level: Double {
        lock.lock(); defer { lock.unlock() }
        return enabled ? _level : 1.0
    }

    /// Called once per second with the state of the receivers.
    func report(congested: Bool) {
        guard enabled else { return }
        lock.lock()
        let old = _level
        if congested {
            congestedSeconds += 1
            calmSeconds = 0
            // Only react to sustained congestion (2 seconds in a row)
            if congestedSeconds >= 2 {
                _level = max(Self.minimumLevel, _level * 0.85)
            }
        } else {
            congestedSeconds = 0
            calmSeconds += 1
            if calmSeconds >= 2 {
                _level = min(1.0, _level + 0.1)
            }
        }
        let new = _level
        lock.unlock()
        if abs(new - old) > 0.001 { onChange?(new) }
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    static func be<T: FixedWidthInteger>(_ value: T) -> Data {
        var data = Data()
        data.appendBE(value)
        return data
    }
}
