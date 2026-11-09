import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures exactly one display (the virtual one) via ScreenCaptureKit.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Swapped on the main thread (codec/settings changes) but read on the
    /// capture queue – hence the lock.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)? {
        get { frameLock.lock(); defer { frameLock.unlock() }; return _onFrame }
        set { frameLock.lock(); _onFrame = newValue; frameLock.unlock() }
    }
    var onStop: ((Error?) -> Void)?

    private let frameLock = NSLock()
    private var _onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private let queue = DispatchQueue(label: "webscreen.capture", qos: .userInteractive)

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, showsCursor: Bool) async throws {
        var target: SCDisplay?
        // The new display may take a moment to show up in the list.
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            target = content.displays.first { $0.displayID == displayID }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let target else { throw WebScreenError.displayNotFound }

        let filter = SCContentFilter(display: target, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 6
        config.showsCursor = showsCursor
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.configuration = config
    }

    /// Changes frame rate and pointer visibility on the fly – without restarting the capture
    func update(fps: Int, showsCursor: Bool) async throws {
        guard let stream, let configuration else { return }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.showsCursor = showsCursor
        try await stream.updateConfiguration(configuration)
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        self.configuration = nil
        try? await stream.stopCapture()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRaw = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        onFrame?(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
