import AppKit
import CoreGraphics
import Foundation

/// Identifier for “custom resolution” in the resolution pickers
let customPresetIDValue = "custom"

/// Settings of a single virtual screen
struct ScreenConfig: Codable, Equatable, Identifiable {
    var id: Int
    var name: String
    var width: Int
    var height: Int
    var hiDPI: Bool
    /// Belongs to exactly one device (“own screen per device”)
    var ownerDeviceID: String?
    /// Keep active even without a connected device
    var keepAlive: Bool = false
    /// Device screens are lined up to the right of the existing displays once;
    /// after that macOS remembers wherever the user moves them.
    var placed: Bool = false

    var pixelWidth: Int { width * (hiDPI ? 2 : 1) }
    var pixelHeight: Int { height * (hiDPI ? 2 : 1) }
    var isDeviceScreen: Bool { ownerDeviceID != nil }

    var presetID: String {
        let id = "\(width)x\(height)"
        return DisplayPreset.all.contains { $0.id == id } ? id : customPresetIDValue
    }

    init(id: Int, name: String, width: Int, height: Int, hiDPI: Bool,
         ownerDeviceID: String? = nil, keepAlive: Bool = false) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.hiDPI = hiDPI
        self.ownerDeviceID = ownerDeviceID
        self.keepAlive = keepAlive
    }

    // Tolerant of older saved versions
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "WebScreen \(id)"
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1920
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1080
        hiDPI = try c.decodeIfPresent(Bool.self, forKey: .hiDPI) ?? false
        ownerDeviceID = try c.decodeIfPresent(String.self, forKey: .ownerDeviceID)
        keepAlive = try c.decodeIfPresent(Bool.self, forKey: .keepAlive) ?? false
        placed = try c.decodeIfPresent(Bool.self, forKey: .placed) ?? false
    }
}

/// Streaming settings shared by all screens
struct GlobalSettings: Equatable {
    var fps: Int
    var mode: StreamMode
    var quality: Int
    var deltaUpdates: Bool
    var bitrateMbps: Int
    var adaptive: Bool
    var showsCursor: Bool
    /// Real-time: repeat the last frame so the stream never goes idle
    var steadyFrameRate: Bool
}

/// A virtual screen including capture and encoding.
/// The codec can be switched on the fly without recreating the screen
/// (and thus moving the windows on it).
@MainActor
final class ScreenSession: ObservableObject, Identifiable {
    nonisolated let id: Int

    @Published var config: ScreenConfig
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var displayInfo: VirtualDisplayInfo?
    @Published private(set) var preview: NSImage?
    @Published private(set) var adaptiveLevel: Double?
    @Published private(set) var codec: StreamCodec?
    @Published var errorText: String?
    @Published private(set) var activeConfig: ScreenConfig?
    private(set) var activeGlobal: GlobalSettings?

    private let display = VirtualDisplayManager()
    private var capture: CaptureEngine?
    private var pipeline: FramePipelineProtocol?
    private var previewRenderer: PreviewRenderer?
    private var controller: AdaptiveController?
    private weak var server: StreamServer?

    /// The capture stopped unexpectedly (e.g. because macOS reconfigured the display).
    /// Devices stay assigned – the app can restart it.
    var onUnexpectedStop: (() -> Void)?
    /// The screen changed its own configuration (e.g. it was placed) – save it
    var onConfigChanged: (() -> Void)?

    /// Virtual screens always run at 60 Hz – the capture controls the streaming
    /// frame rate. That way it can change without recreating the screen.
    private static let displayRefreshRate = 60.0

    init(config: ScreenConfig) {
        self.id = config.id
        self.config = config
    }

    var hasPendingChanges: Bool {
        guard let activeConfig, isRunning else { return false }
        return activeConfig.width != config.width || activeConfig.height != config.height
            || activeConfig.hiDPI != config.hiDPI || activeConfig.name != config.name
    }

    // MARK: Start/stop

    func start(global: GlobalSettings, codec: StreamCodec, server: StreamServer) async {
        guard !isRunning, !isBusy else { return }
        isBusy = true
        errorText = nil
        defer { isBusy = false }

        let config = self.config
        let codec = fittingCodec(codec, for: config)

        do {
            let info = try await display.create(
                width: config.width, height: config.height, hiDPI: config.hiDPI,
                refreshRate: Self.displayRefreshRate, serial: UInt32(config.id), name: config.name
            )
            displayInfo = info
            if config.isDeviceScreen && !config.placed {
                VirtualDisplayManager.placeRightOfOtherDisplays(info.displayID)
                self.config.placed = true
                onConfigChanged?()
            }
            self.server = server
            activeGlobal = global

            let previewRenderer = PreviewRenderer()
            previewRenderer.onImage = { [weak self] image in
                Task { @MainActor in self?.preview = image }
            }
            self.previewRenderer = previewRenderer

            try installPipeline(codec: codec, global: global, info: info, server: server, announce: true)

            let capture = CaptureEngine()
            capture.onStop = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.isRunning, !self.isBusy else { return }
                    await self.stop(detachClients: false)
                    if let error { self.errorText = "Capture stopped: \(error.localizedDescription)" }
                    self.onUnexpectedStop?()
                }
            }
            self.capture = capture
            connectCapture()
            try await capture.start(displayID: info.displayID, width: info.pixelWidth,
                                    height: info.pixelHeight, fps: global.fps, showsCursor: global.showsCursor)

            activeConfig = config
            isRunning = true
        } catch {
            await teardown()
            errorText = error.localizedDescription
        }
    }

    /// `detachClients == false`: devices stay assigned to the screen and are greeted
    /// again automatically on the next start.
    func stop(detachClients: Bool = true) async {
        guard isRunning, !isBusy else { return }
        isBusy = true
        await teardown(detachClients: detachClients)
        isRunning = false
        isBusy = false
    }

    /// Recreate (e.g. after a resolution change). Connected devices stay assigned
    /// and receive the new screen as soon as it is ready.
    func restart(global: GlobalSettings, codec: StreamCodec, server: StreamServer) async {
        await stop(detachClients: false)
        await start(global: global, codec: codec, server: server)
    }

    /// Switches the codec without recreating the virtual screen
    func switchCodec(to newCodec: StreamCodec) {
        guard isRunning, !isBusy, let info = displayInfo, let global = activeGlobal, let server else { return }
        let target = fittingCodec(newCodec, for: activeConfig ?? config)
        guard target != codec else { return }
        pipeline?.stop()
        do {
            try installPipeline(codec: target, global: global, info: info, server: server, announce: true)
            connectCapture()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Applies changed streaming settings on the fly – without recreating the
    /// virtual screen and without disconnecting devices.
    func applyGlobal(_ global: GlobalSettings, codec requested: StreamCodec) async {
        guard isRunning, !isBusy, let info = displayInfo, let old = activeGlobal, let server else { return }
        let target = fittingCodec(requested, for: activeConfig ?? config)
        guard global != old || target != codec else { return }
        activeGlobal = global

        // Swap the pipeline synchronously (before the first `await`, so two quick
        // changes cannot overtake each other)
        let pipelineChanged = target != codec
            || global.fps != old.fps || global.quality != old.quality
            || global.deltaUpdates != old.deltaUpdates || global.bitrateMbps != old.bitrateMbps
            || global.adaptive != old.adaptive || global.steadyFrameRate != old.steadyFrameRate
        if pipelineChanged, target == .webrtc, codec == .webrtc, let rtc = pipeline as? WebRTCPipeline {
            // Keep the peer connections – WebRTC adapts bitrate and frame rate live
            rtc.update(fps: global.fps,
                       bitrate: Int(Self.effectiveBitrateMbps(global.bitrateMbps, info: info) * 1_000_000),
                       steady: global.steadyFrameRate)
        } else if pipelineChanged {
            let announce = target != codec
            pipeline?.stop()
            do {
                try installPipeline(codec: target, global: global, info: info, server: server, announce: announce)
                connectCapture()
            } catch {
                errorText = error.localizedDescription
            }
        }

        if global.fps != old.fps || global.showsCursor != old.showsCursor {
            do {
                try await capture?.update(fps: global.fps, showsCursor: global.showsCursor)
            } catch {
                errorText = "Capture could not be adjusted: \(error.localizedDescription)"
            }
        }
    }

    /// Falls back to a codec the encoder can handle at this size
    private func fittingCodec(_ codec: StreamCodec, for config: ScreenConfig) -> StreamCodec {
        let size = max(config.pixelWidth, config.pixelHeight)
        if size <= codec.maxDimension { return codec }
        if (codec == .h264 || codec == .webrtc) && size <= StreamCodec.hevc.maxDimension { return .hevc }
        return .jpeg
    }

    private func installPipeline(codec: StreamCodec, global: GlobalSettings,
                                 info: VirtualDisplayInfo, server: StreamServer, announce: Bool) throws {
        let controller = AdaptiveController(enabled: global.adaptive)
        adaptiveLevel = global.adaptive ? 1.0 : nil
        controller.onChange = { [weak self] level in
            Task { @MainActor in self?.adaptiveLevel = level }
        }
        self.controller = controller

        let screenID = id
        let pipeline: FramePipelineProtocol
        switch codec {
        case .jpeg:
            pipeline = JPEGPipeline(quality: Double(global.quality) / 100,
                                    deltaUpdates: global.deltaUpdates, adaptive: controller)
        case .h264, .hevc:
            let video = try VideoPipeline(codec: codec, width: info.pixelWidth, height: info.pixelHeight,
                                          fps: global.fps,
                                          bitrate: Int(Self.effectiveBitrateMbps(global.bitrateMbps, info: info) * 1_000_000),
                                          adaptive: controller, steady: global.steadyFrameRate)
            video.onInit = { [weak server] in server?.setInit($0, raw: $1, screen: screenID) }
            pipeline = video
        case .webrtc:
            let rtc = WebRTCPipeline(width: info.pixelWidth, height: info.pixelHeight, fps: global.fps,
                                     bitrate: Int(Self.effectiveBitrateMbps(global.bitrateMbps, info: info) * 1_000_000),
                                     steady: global.steadyFrameRate)
            rtc.sendSignal = { [weak server] client, json in server?.sendSignal(json, to: client) }
            pipeline = rtc
        }
        pipeline.onPacket = { [weak server] packet, raw, isSync in
            server?.broadcast(packet, raw: raw, isSync: isSync, screen: screenID)
        }
        pipeline.hasReceivers = { [weak server] in server?.hasReceivers(screen: screenID) ?? false }
        self.pipeline = pipeline
        self.codec = codec

        // With a new method, (re-)registering greets connected devices again;
        // otherwise only the callbacks are switched to the new pipeline.
        var channel = StreamServer.ScreenChannel(
            name: (activeConfig ?? config).name,
            codec: codec,
            onSyncNeeded: { [weak pipeline] in pipeline?.requestSync() },
            onCongestion: { [weak controller] in controller?.report(congested: $0) }
        )
        if let rtc = pipeline as? WebRTCPipeline {
            channel.onClientAttached = { [weak rtc] in rtc?.attach($0) }
            channel.onClientDetached = { [weak rtc] in rtc?.detach($0) }
            channel.onSignal = { [weak rtc] in rtc?.handleSignal($0, json: $1) }
        }
        server.registerScreen(id, channel: channel, announce: announce)
    }

    private func connectCapture() {
        let pipeline = self.pipeline
        let previewRenderer = self.previewRenderer
        capture?.onFrame = { [weak pipeline, weak previewRenderer] buffer, pts in
            pipeline?.submit(buffer, pts: pts)
            previewRenderer?.submit(buffer)
        }
    }

    private func teardown(detachClients: Bool = true) async {
        server?.unregisterScreen(id, detachClients: detachClients)
        if let capture { await capture.stop() }
        capture = nil
        pipeline?.stop()
        pipeline = nil
        controller = nil
        previewRenderer = nil
        display.destroy()
        displayInfo = nil
        preview = nil
        adaptiveLevel = nil
        codec = nil
        activeConfig = nil
        activeGlobal = nil
    }

    /// The configured bitrate applies to Full HD (≈ 2 megapixels). Larger screens
    /// get proportionally more – otherwise 4K or Retina gets blocky.
    static func effectiveBitrateMbps(_ base: Int, info: VirtualDisplayInfo) -> Double {
        let pixels = Double(info.pixelWidth * info.pixelHeight)
        let factor = min(4.0, max(0.5, pixels / (1920.0 * 1080.0)))
        return Double(base) * factor
    }

    // MARK: Display

    var sizeLabel: String {
        if let info = displayInfo {
            return info.pixelWidth != info.pointWidth
                ? "\(info.pointWidth)×\(info.pointHeight) @2x"
                : "\(info.pointWidth)×\(info.pointHeight)"
        }
        return "\(config.width)×\(config.height)" + (config.hiDPI ? " @2x" : "")
    }

    /// Short: “HEVC · 6.2 Mbit/s” or “JPEG · 65 %”
    var liveQualityText: String? {
        guard let codec, let global = activeGlobal else { return nil }
        let level = adaptiveLevel ?? 1.0
        switch codec {
        case .jpeg:
            let q = 45 + Double(global.quality - 45) * level
            return "JPEG · \(Int(q.rounded())) %"
        case .webrtc:
            let base = displayInfo.map { Self.effectiveBitrateMbps(global.bitrateMbps, info: $0) } ?? Double(global.bitrateMbps)
            return "Real-time · up to " + String(format: "%.0f Mbit/s", base)
        case .h264, .hevc:
            let base = displayInfo.map { Self.effectiveBitrateMbps(global.bitrateMbps, info: $0) } ?? Double(global.bitrateMbps)
            let mbps = max(1, base * level)
            return codec.title + " · " + String(format: "%.1f Mbit/s", mbps)
        }
    }
}
