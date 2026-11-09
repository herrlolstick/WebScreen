import AppKit
import CoreImage
import CoreVideo

/// Creates a small preview image for the UI from the captured frames
/// (at most a few times per second so it costs next to nothing).
final class PreviewRenderer {
    var onImage: ((NSImage) -> Void)?

    private let queue = DispatchQueue(label: "webscreen.preview", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let maxWidth: CGFloat = 640
    private let interval: UInt64 = 250_000_000 // 4 images per second
    private let lock = NSLock()
    private var lastRender: UInt64 = 0
    private var busy = false

    func submit(_ pixelBuffer: CVPixelBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        guard !busy, now &- lastRender >= interval else {
            lock.unlock()
            return
        }
        busy = true
        lastRender = now
        lock.unlock()

        queue.async {
            defer {
                self.lock.lock()
                self.busy = false
                self.lock.unlock()
            }
            var image = CIImage(cvPixelBuffer: pixelBuffer)
            let scale = min(1, self.maxWidth / image.extent.width)
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cgImage = self.context.createCGImage(image, from: image.extent) else { return }
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            self.onImage?(nsImage)
        }
    }
}
