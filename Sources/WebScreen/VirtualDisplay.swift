import CoreGraphics
import Foundation
import CGVirtualDisplayBridge

struct DisplayPreset: Identifiable, Hashable {
    let width: Int
    let height: Int
    let label: String
    var id: String { "\(width)x\(height)" }

    static let all: [DisplayPreset] = [
        DisplayPreset(width: 1280, height: 800, label: "1280 × 800 (16:10)"),
        DisplayPreset(width: 1440, height: 900, label: "1440 × 900 (16:10)"),
        DisplayPreset(width: 1920, height: 1080, label: "1920 × 1080 (Full HD)"),
        DisplayPreset(width: 1920, height: 1200, label: "1920 × 1200 (16:10)"),
        DisplayPreset(width: 2560, height: 1440, label: "2560 × 1440 (QHD)"),
        DisplayPreset(width: 2560, height: 1600, label: "2560 × 1600 (16:10)"),
        DisplayPreset(width: 3440, height: 1440, label: "3440 × 1440 (Ultrawide)"),
        DisplayPreset(width: 3840, height: 2160, label: "3840 × 2160 (4K UHD)"),
        DisplayPreset(width: 1024, height: 768, label: "1024 × 768 (iPad, 4:3)"),
        DisplayPreset(width: 1180, height: 820, label: "1180 × 820 (iPad Air)"),
        DisplayPreset(width: 1366, height: 1024, label: "1366 × 1024 (iPad Pro 12,9″)"),
    ]

    static let defaultID = "1920x1080"

    static func find(_ id: String) -> DisplayPreset {
        all.first { $0.id == id } ?? all.first { $0.id == defaultID }!
    }
}

struct VirtualDisplayInfo {
    let displayID: CGDirectDisplayID
    let pointWidth: Int
    let pointHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
}

/// Creates an additional display through the private `CGVirtualDisplay` API.
/// As long as this object lives, macOS treats the monitor like a real one.
@MainActor
final class VirtualDisplayManager {
    private var display: CGVirtualDisplay?

    /// `serial` should be unique and stable per screen – macOS uses it to remember
    /// the arrangement.
    func create(width: Int, height: Int, hiDPI: Bool, refreshRate: Double,
                serial: UInt32 = 1, name: String = "WebScreen") async throws -> VirtualDisplayInfo {
        destroy()

        let scale = hiDPI ? 2 : 1
        let pixelWidth = width * scale
        let pixelHeight = height * scale

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(pixelWidth)
        descriptor.maxPixelsHigh = UInt32(pixelHeight)
        // The physical size determines how macOS estimates the pixel density.
        let ppi = hiDPI ? 220.0 : 110.0
        descriptor.sizeInMillimeters = CGSize(
            width: Double(pixelWidth) / ppi * 25.4,
            height: Double(pixelHeight) / ppi * 25.4
        )
        descriptor.vendorID = 0x5753 // "WS"
        descriptor.productID = 0x0001
        descriptor.serialNum = serial
        // sRGB primaries
        descriptor.whitePoint = CGPoint(x: 0.3125, y: 0.3291)
        descriptor.redPrimary = CGPoint(x: 0.6400, y: 0.3300)
        descriptor.greenPrimary = CGPoint(x: 0.3000, y: 0.6000)
        descriptor.bluePrimary = CGPoint(x: 0.1500, y: 0.0600)
        descriptor.terminationHandler = { _, _ in
            NSLog("WebScreen: virtual display was terminated by the system")
        }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw WebScreenError.virtualDisplayFailed
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        var modes = [CGVirtualDisplayMode(width: UInt32(pixelWidth), height: UInt32(pixelHeight), refreshRate: refreshRate)]
        if hiDPI {
            modes.append(CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: refreshRate))
        }
        settings.modes = modes

        guard display.apply(settings) else {
            throw WebScreenError.virtualDisplayFailed
        }
        self.display = display

        let id = display.displayID
        // macOS needs a moment until the new display and its modes are available.
        var chosen: CGDisplayMode?
        for _ in 0..<30 {
            _ = Self.selectMode(displayID: id, width: width, height: height, scale: scale)
            if let current = CGDisplayCopyDisplayMode(id),
               current.width == width, current.pixelWidth == pixelWidth {
                chosen = current
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if chosen == nil {
            // Fallback: take whatever macOS has set
            chosen = CGDisplayCopyDisplayMode(id)
        }
        guard let mode = chosen else {
            destroy()
            throw WebScreenError.virtualDisplayFailed
        }

        return VirtualDisplayInfo(
            displayID: id,
            pointWidth: mode.width,
            pointHeight: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight
        )
    }

    /// Moves a display to the right end of the arrangement, top-aligned with the
    /// main display – so new device screens line up next to each other instead of
    /// wherever macOS puts them. Saved permanently, so later changes by the user stick.
    static func placeRightOfOtherDisplays(_ displayID: CGDirectDisplayID) {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(32, &ids, &count) == .success else { return }
        let others = ids.prefix(Int(count)).filter { $0 != displayID && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        guard let rightEdge = others.map({ CGDisplayBounds($0).maxX }).max() else { return }
        let top = CGDisplayBounds(CGMainDisplayID()).minY

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayOrigin(config, displayID, Int32(rightEdge), Int32(top))
        _ = CGCompleteDisplayConfiguration(config, .permanently)
    }

    func destroy() {
        display = nil // Releasing it removes the display
    }

    private static func selectMode(displayID: CGDirectDisplayID, width: Int, height: Int, scale: Int) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return false
        }
        guard let match = modes.first(where: {
            $0.width == width && $0.height == height &&
                $0.pixelWidth == width * scale && $0.pixelHeight == height * scale
        }) else {
            return false
        }
        return CGDisplaySetDisplayMode(displayID, match, nil) == .success
    }
}
