import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

/// JPEG pipeline with optional partial updates.
///
/// Packet format (big endian):
///   [u8 type=1][u8 full frame?][u16 width][u16 height][u16 count]
///   per region: [u16 x][u16 y][u16 w][u16 h][u32 length][JPEG]
///
/// “Latest frame wins”: while encoding, new frames overwrite each other.
/// Partial updates are always computed against the last *sent* image,
/// so this stays correct when frames are skipped.
final class JPEGPipeline: FramePipelineProtocol {
    var onPacket: ((Data, Data?, Bool) -> Void)?
    var hasReceivers: () -> Bool = { true }

    private let queue = DispatchQueue(label: "webscreen.encode", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let maxQuality: Double
    private let minQuality = 0.45
    private let adaptive: AdaptiveController
    private let differ: TileDiffer?

    private let lock = NSLock()
    private var next: CVPixelBuffer?
    private var lastSeen: CVPixelBuffer?
    private var encoding = false
    private var stopped = false
    private var forceFull = true

    init(quality: Double, deltaUpdates: Bool, adaptive: AdaptiveController) {
        self.maxQuality = quality
        self.adaptive = adaptive
        self.differ = deltaUpdates ? TileDiffer() : nil
    }

    /// JPEG quality currently in use (0…1)
    var currentQuality: Double {
        let level = adaptive.level
        return minQuality + (maxQuality - minQuality) * level
    }

    func submit(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        next = pixelBuffer
        lastSeen = pixelBuffer
        let start = !encoding && !stopped
        if start { encoding = true }
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    func requestSync() {
        lock.lock()
        forceFull = true
        if next == nil { next = lastSeen }
        let start = next != nil && !encoding && !stopped
        if start { encoding = true }
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    func stop() {
        lock.lock()
        stopped = true
        next = nil
        lastSeen = nil
        lock.unlock()
        queue.sync {}
    }

    private func drain() {
        while true {
            lock.lock()
            guard let pixelBuffer = next, !stopped else {
                encoding = false
                lock.unlock()
                return
            }
            next = nil
            let full = forceFull
            forceFull = false
            lock.unlock()

            guard hasReceivers() else {
                // Don't encode without receivers – start with a full frame next time
                lock.lock(); forceFull = true; lock.unlock()
                continue
            }
            if let result = encode(pixelBuffer, forceFull: full) {
                onPacket?(result.packet, nil, result.isFull)
            }
        }
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, forceFull: Bool) -> (packet: Data, isFull: Bool)? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var full = forceFull || differ == nil
        var rects: [CGRect] = []
        if let differ {
            // diff() always updates the reference image – even when we send a full frame
            if let changed = differ.diff(pixelBuffer) {
                rects = changed
            } else {
                full = true
            }
        }
        if !full {
            if rects.isEmpty { return nil }
            let area = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
            if area > 0.55 * Double(width * height) || rects.count > 48 {
                full = true
            }
        }
        if full {
            rects = [CGRect(x: 0, y: 0, width: width, height: height)]
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: currentQuality]

        var packet = Data()
        packet.append(UInt8(1))
        packet.append(UInt8(full ? 1 : 0))
        packet.appendBE(UInt16(width))
        packet.appendBE(UInt16(height))
        packet.appendBE(UInt16(rects.count))

        for rect in rects {
            // Core Image has its origin at the bottom left
            let ciRect = CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
            let patch = image
                .cropped(to: ciRect)
                .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
            guard let jpeg = context.jpegRepresentation(of: patch, colorSpace: colorSpace, options: options) else {
                return nil
            }
            packet.appendBE(UInt16(rect.minX))
            packet.appendBE(UInt16(rect.minY))
            packet.appendBE(UInt16(rect.width))
            packet.appendBE(UInt16(rect.height))
            packet.appendBE(UInt32(jpeg.count))
            packet.append(jpeg)
        }
        return (packet, full)
    }
}

/// Compares frames tile by tile (32 × 32 pixels) with the last sent image
/// and returns the changed regions as few rectangles as possible.
final class TileDiffer {
    private let tile = 32
    private var previousY: [UInt8] = []
    private var previousUV: [UInt8] = []
    private var width = 0
    private var height = 0

    /// `nil` = no comparison possible (first image, new size) → send a full frame
    func diff(_ pixelBuffer: CVPixelBuffer) -> [CGRect]? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let uvRowBytes = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) * 2
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        guard let yRaw = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvRaw = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else { return nil }
        let yBase = yRaw.assumingMemoryBound(to: UInt8.self)
        let uvBase = uvRaw.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        let first = previousY.isEmpty || w != width || h != height
        if first {
            width = w
            height = h
            previousY = [UInt8](repeating: 0, count: w * h)
            previousUV = [UInt8](repeating: 0, count: uvRowBytes * uvHeight)
        }

        let cols = (w + tile - 1) / tile
        let rows = (h + tile - 1) / tile
        var dirty = [Bool](repeating: false, count: cols * rows)

        // Luma (Y)
        previousY.withUnsafeMutableBufferPointer { prev in
            guard let prevBase = prev.baseAddress else { return }
            for y in 0..<h {
                let src = yBase + y * yStride
                let dst = prevBase + y * w
                if !first && memcmp(src, dst, w) == 0 { continue }
                if !first {
                    let row = y / tile
                    for c in 0..<cols where !dirty[row * cols + c] {
                        let x0 = c * tile
                        if memcmp(src + x0, dst + x0, min(tile, w - x0)) != 0 {
                            dirty[row * cols + c] = true
                        }
                    }
                }
                memcpy(dst, src, w)
            }
        }

        // Chroma (CbCr, half resolution, 2 bytes per pixel pair → byte offset = luma x)
        previousUV.withUnsafeMutableBufferPointer { prev in
            guard let prevBase = prev.baseAddress else { return }
            for y in 0..<uvHeight {
                let src = uvBase + y * uvStride
                let dst = prevBase + y * uvRowBytes
                if !first && memcmp(src, dst, uvRowBytes) == 0 { continue }
                if !first {
                    let row = min((y * 2) / tile, rows - 1)
                    for c in 0..<cols where !dirty[row * cols + c] {
                        let x0 = c * tile
                        guard x0 < uvRowBytes else { continue }
                        if memcmp(src + x0, dst + x0, min(tile, uvRowBytes - x0)) != 0 {
                            dirty[row * cols + c] = true
                        }
                    }
                }
                memcpy(dst, src, uvRowBytes)
            }
        }

        if first { return nil }
        return merge(dirty, cols: cols, rows: rows)
    }

    /// Merges tiles into rectangles: first horizontal runs per row,
    /// then runs of equal width stacked vertically.
    private func merge(_ dirty: [Bool], cols: Int, rows: Int) -> [CGRect] {
        var rects: [CGRect] = []
        var open: [Int: Int] = [:]
        for r in 0..<rows {
            var nextOpen: [Int: Int] = [:]
            var c = 0
            while c < cols {
                guard dirty[r * cols + c] else { c += 1; continue }
                var e = c
                while e + 1 < cols && dirty[r * cols + e + 1] { e += 1 }
                let key = (c << 16) | e
                let x = c * tile
                let rectWidth = min((e + 1) * tile, width) - x
                let y = r * tile
                let rectHeight = min((r + 1) * tile, height) - y
                if let index = open[key] {
                    rects[index].size.height += CGFloat(rectHeight)
                    nextOpen[key] = index
                } else {
                    rects.append(CGRect(x: x, y: y, width: rectWidth, height: rectHeight))
                    nextOpen[key] = rects.count - 1
                }
                c = e + 1
            }
            open = nextOpen
        }
        return rects
    }
}
