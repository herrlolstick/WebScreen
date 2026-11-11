import AppKit
import CoreGraphics
import Foundation
import ServiceManagement

/// How devices are distributed across screens automatically
enum AssignmentMode: String, CaseIterable, Identifiable {
    /// All devices show the same main screen
    case shared
    /// Every device gets its own screen
    case perDevice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shared: return "One screen for all"
        case .perDevice: return "One per device"
        }
    }
}

/// A device that has connected before – recognized again by an identifier
/// stored in the browser.
struct KnownDevice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// Manual assignment – takes precedence over the automatic mode
    var pinnedScreenID: Int?
    /// Own screen (mode “own screen per device”)
    var ownScreenID: Int?
    var lastSeen: Date
    /// Last network address – used to show screens of several browsers on one computer together
    var lastAddress: String?
}

/// Screens grouped by the computer/tablet they are shown on
struct DeviceGroup: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let screens: [ScreenSession]
}

@MainActor
final class AppModel: ObservableObject {
    enum State: Equatable {
        case stopped, starting, running, stopping
    }

    static let customPresetID = customPresetIDValue
    /// How long a screen stays active without a device (survives reloading the page)
    static let idleTimeout: UInt64 = 20

    // MARK: Runtime state
    @Published private(set) var state: State = .stopped
    @Published private(set) var screens: [ScreenSession] = []
    @Published private(set) var clients: [ClientInfo] = []
    @Published private(set) var devices: [KnownDevice] = []
    @Published private(set) var addresses: [String] = []
    @Published private(set) var activeGlobal: GlobalSettings?
    @Published var errorText: String?

    // MARK: Assignment
    @Published var assignmentMode: AssignmentMode {
        didSet {
            save(assignmentMode.rawValue, "assignmentMode")
            guard isRunning else { return }
            Task {
                await reassignAll()
                await deactivateUnusedScreens()
            }
        }
    }
    @Published var primaryScreenID: Int {
        didSet { save(primaryScreenID, "primaryScreen"); reassignAllLater() }
    }
    /// Device screens take over the device's resolution (and Retina)
    @Published var autoMatchDevice: Bool { didSet { save(autoMatchDevice, "autoMatchDevice") } }

    // MARK: Streaming (applies to all screens)
    // Changes are applied on the fly – without disconnecting devices
    @Published var fps: Int { didSet { save(fps, "fps"); applyLiveSettingsLater() } }
    @Published var mode: StreamMode { didSet { save(mode.rawValue, "mode"); applyLiveSettingsLater() } }
    @Published var quality: Int { didSet { save(quality, "quality"); applyLiveSettingsLater() } }
    @Published var deltaUpdates: Bool { didSet { save(deltaUpdates, "deltaUpdates"); applyLiveSettingsLater() } }
    @Published var bitrateMbps: Int { didSet { save(bitrateMbps, "bitrateMbps"); applyLiveSettingsLater() } }
    @Published var adaptive: Bool { didSet { save(adaptive, "adaptive"); applyLiveSettingsLater() } }
    @Published var showsCursor: Bool { didSet { save(showsCursor, "showsCursor"); applyLiveSettingsLater() } }
    /// Real-time: keep the frame rate constant so movement starts without a hitch
    @Published var steadyFrameRate: Bool { didSet { save(steadyFrameRate, "steadyFrameRate"); applyLiveSettingsLater() } }
    /// Only a new port or a change of the low-latency mode requires restarting the stream
    @Published var port: Int { didSet { save(port, "port") } }
    /// Expert setting: HTTPS via local-ip.sh so browsers can decode with WebCodecs.
    /// Needs a router that resolves local-ip.sh (e.g. a FRITZ!Box rebind exception).
    @Published var lowLatency: Bool { didSet { save(lowLatency, "lowLatency") } }
    /// State of the HTTPS endpoint while running
    @Published private(set) var secureStatus: SecureStatus?

    enum SecureStatus: Equatable {
        case active(expires: Date)
        case failed(String)
    }

    // MARK: New screens
    @Published var defaultPresetID: String { didSet { save(defaultPresetID, "preset") } }
    @Published var defaultCustomWidth: Int { didSet { save(defaultCustomWidth, "customWidth") } }
    @Published var defaultCustomHeight: Int { didSet { save(defaultCustomHeight, "customHeight") } }
    @Published var defaultHiDPI: Bool { didSet { save(defaultHiDPI, "hiDPI") } }

    // MARK: General
    @Published var autoStart: Bool { didSet { save(autoStart, "autoStart") } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            updateLoginItem()
        }
    }

    private let defaults = UserDefaults.standard
    private var server: StreamServer?
    private var activePort: Int?
    private var activeLowLatency: Bool?
    /// Connection → screen (authoritative for codec choice and idling, without waiting for the server)
    private var assignments: [UUID: Int] = [:]
    private var connectionDevice: [UUID: String] = [:]
    private var connectionHEVC: [UUID: Bool] = [:]
    private var connectionWebRTC: [UUID: Bool] = [:]
    /// Screen explicitly chosen via `?screen=` for a connection
    private var connectionOverride: [UUID: Int] = [:]
    private var idleTasks: [Int: Task<Void, Never>] = [:]
    private var liveApplyTask: Task<Void, Never>?
    /// Time of the last automatic recovery per screen (prevents endless loops)
    private var lastRecovery: [Int: Date] = [:]

    var isRunning: Bool { state == .running }
    var isBusy: Bool { state == .starting || state == .stopping }

    var globalSettings: GlobalSettings {
        GlobalSettings(fps: fps, mode: mode, quality: quality, deltaUpdates: deltaUpdates,
                       bitrateMbps: bitrateMbps, adaptive: adaptive, showsCursor: showsCursor,
                       steadyFrameRate: steadyFrameRate)
    }

    /// Streaming settings apply immediately; only a changed port or low-latency mode needs a restart.
    var needsRestart: Bool {
        guard isRunning, let activePort else { return false }
        return activePort != port || activeLowLatency != lowLatency
    }

    var fixedScreens: [ScreenSession] { screens.filter { !$0.config.isDeviceScreen } }
    var deviceScreens: [ScreenSession] { screens.filter { $0.config.isDeviceScreen } }
    /// Screens the current mode can actually use. In “one per device” the regular screens are
    /// never used – they are hidden and stay switched off.
    var visibleScreens: [ScreenSession] {
        switch assignmentMode {
        case .shared: return screens
        case .perDevice: return deviceScreens
        }
    }

    func isUsable(_ screen: ScreenSession) -> Bool {
        assignmentMode == .shared || screen.config.isDeviceScreen
    }

    /// Device screens grouped by computer: several tabs of one browser belong together
    /// (same stored key), and so do different browsers on the same computer (same address).
    var deviceGroups: [DeviceGroup] {
        var order: [String] = []
        var members: [String: [ScreenSession]] = [:]
        var platforms: [String: String] = [:]
        for screen in deviceScreens {
            let ownerID = screen.config.ownerDeviceID ?? ""
            let owner = devices.first { $0.id == ownerID }
            let key = owner?.lastAddress ?? Self.baseDeviceKey(ownerID)
            if members[key] == nil { order.append(key); members[key] = [] }
            members[key]?.append(screen)
            if platforms[key] == nil { platforms[key] = Self.platform(of: owner?.name ?? screen.config.name) }
        }
        let titles = order.map { key -> String in
            if key == "::1" || key == "127.0.0.1" { return "This Mac" }
            return Self.computerName(platforms[key] ?? "Device")
        }
        return order.enumerated().map { index, key in
            var title = titles[index]
            // Two computers of the same kind: tell them apart by their address
            if titles.filter({ $0 == title }).count > 1, key.contains(".") { title += " (\(key))" }
            return DeviceGroup(id: key, title: title, symbol: DeviceSymbol.name(for: platforms[key] ?? ""),
                               screens: members[key] ?? [])
        }
    }

    /// “Chrome on Windows · Tab 2” → “Chrome · Tab 2” (the computer is shown above it)
    func browserName(of screen: ScreenSession) -> String {
        let name = screen.config.name
        guard let range = name.range(of: " on ") else { return name }
        let rest = name[range.upperBound...]
        let tab = rest.range(of: " · ").map { String(rest[$0.lowerBound...]) } ?? ""
        return String(name[..<range.lowerBound]) + tab
    }

    private static func baseDeviceKey(_ key: String) -> String {
        guard let range = key.range(of: #"-tab\d+$"#, options: .regularExpression) else { return key }
        return String(key[..<range.lowerBound])
    }

    /// “Chrome on Windows · Tab 2” → “Windows”
    private static func platform(of name: String) -> String {
        guard let range = name.range(of: " on ") else { return name }
        let rest = name[range.upperBound...]
        return String(rest.split(separator: "·").first ?? Substring(rest)).trimmingCharacters(in: .whitespaces)
    }

    private static func computerName(_ platform: String) -> String {
        switch platform {
        case "Windows": return "Windows PC"
        case "Linux": return "Linux PC"
        case "Android": return "Android device"
        case "ChromeOS": return "Chromebook"
        default: return platform
        }
    }

    var primaryScreen: ScreenSession? {
        screens.first { $0.id == primaryScreenID && !$0.config.isDeviceScreen } ?? fixedScreens.first
    }

    var defaultSize: (width: Int, height: Int) {
        if defaultPresetID == Self.customPresetID {
            return (Self.sanitize(defaultCustomWidth), Self.sanitize(defaultCustomHeight))
        }
        let preset = DisplayPreset.find(defaultPresetID)
        return (preset.width, preset.height)
    }

    init() {
        let d = UserDefaults.standard
        assignmentMode = AssignmentMode(rawValue: d.string(forKey: "assignmentMode") ?? "") ?? .shared
        primaryScreenID = d.object(forKey: "primaryScreen") as? Int ?? 1
        autoMatchDevice = d.object(forKey: "autoMatchDevice") as? Bool ?? true
        fps = d.object(forKey: "fps") as? Int ?? 60
        mode = StreamMode(rawValue: d.string(forKey: "mode") ?? "") ?? .videoAuto
        quality = d.object(forKey: "quality") as? Int ?? 70
        deltaUpdates = d.object(forKey: "deltaUpdates") as? Bool ?? true
        // A home network easily carries 20 Mbit/s – enough for sharp text; adaptation lowers it on weak Wi-Fi
        bitrateMbps = d.object(forKey: "bitrateMbps") as? Int ?? 20
        adaptive = d.object(forKey: "adaptive") as? Bool ?? true
        showsCursor = d.object(forKey: "showsCursor") as? Bool ?? true
        steadyFrameRate = d.object(forKey: "steadyFrameRate") as? Bool ?? true
        port = d.object(forKey: "port") as? Int ?? 8787
        lowLatency = d.object(forKey: "lowLatency") as? Bool ?? false
        defaultPresetID = d.string(forKey: "preset") ?? DisplayPreset.defaultID
        defaultCustomWidth = d.object(forKey: "customWidth") as? Int ?? 1600
        defaultCustomHeight = d.object(forKey: "customHeight") as? Int ?? 1000
        defaultHiDPI = d.bool(forKey: "hiDPI")
        autoStart = d.bool(forKey: "autoStart")
        launchAtLogin = SMAppService.mainApp.status == .enabled

        if let data = d.data(forKey: "screens"),
           let configs = try? JSONDecoder().decode([ScreenConfig].self, from: data) {
            screens = configs.map { makeSession($0) }
        }
        if let data = d.data(forKey: "devices"),
           let known = try? JSONDecoder().decode([KnownDevice].self, from: data) {
            devices = known
        }
        ensureFixedScreen()

        if autoStart {
            Task { await start() }
        }
    }

    // MARK: Streaming as a whole

    func toggle() {
        Task {
            if isRunning { await stop() } else { await start() }
        }
    }

    func restartAll() {
        Task {
            await stop()
            await start()
        }
    }

    func start() async {
        guard state == .stopped else { return }
        state = .starting
        errorText = nil

        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            errorText = WebScreenError.noScreenRecordingPermission.localizedDescription
            state = .stopped
            return
        }
        guard port >= 1024, port <= 65532 else {
            errorText = "Please choose a port between 1024 and 65532."
            state = .stopped
            return
        }

        // Low-latency mode: HTTPS + secure WebSocket on the next two ports
        var secure: StreamServer.SecureEndpoint?
        secureStatus = nil
        if lowLatency {
            do {
                let identity = try await SecureOrigin.load()
                secure = .init(identity: identity.identity, httpsPort: UInt16(port + 2),
                               wssPort: UInt16(port + 3), domain: SecureOrigin.domain)
                secureStatus = .active(expires: identity.expires)
            } catch {
                secureStatus = .failed(error.localizedDescription)
            }
        }

        let server: StreamServer
        let localAddresses = LocalNetwork.localIPv4Addresses()
        do {
            let page = try ReceiverPage.load()
            server = StreamServer(httpPort: UInt16(port), wsPort: UInt16(port + 1), pageHTML: page,
                                  secure: secure, defaultIPv4: localAddresses.first)
            server.onClientsChanged = { [weak self] infos in
                Task { @MainActor in self?.clients = infos }
            }
            server.onJoin = { [weak self] connection, request in
                Task { @MainActor in await self?.handleJoin(connection, request) }
            }
            server.onLeave = { [weak self] connection, _ in
                Task { @MainActor in await self?.handleLeave(connection) }
            }
            server.onError = { [weak self] message in
                Task { @MainActor in self?.errorText = message }
            }
            try server.start()
        } catch {
            errorText = error.localizedDescription
            state = .stopped
            return
        }

        self.server = server
        activeGlobal = globalSettings
        activePort = port
        activeLowLatency = lowLatency
        addresses = localAddresses
        state = .running

        // Screens are created on demand – only “keep always ready” ones right away
        for screen in screens where screen.config.keepAlive && isUsable(screen) {
            await ensureRunning(screen)
        }
    }

    func stop() async {
        guard state == .running else { return }
        state = .stopping
        liveApplyTask?.cancel()
        liveApplyTask = nil
        for task in idleTasks.values { task.cancel() }
        idleTasks.removeAll()
        for screen in screens {
            await screen.stop()
        }
        server?.stop()
        server = nil
        assignments.removeAll()
        connectionDevice.removeAll()
        connectionHEVC.removeAll()
        connectionWebRTC.removeAll()
        connectionOverride.removeAll()
        clients = []
        addresses = []
        activeGlobal = nil
        activePort = nil
        activeLowLatency = nil
        secureStatus = nil
        state = .stopped
    }

    // MARK: Managing screens

    @discardableResult
    func addScreen(width: Int? = nil, height: Int? = nil, hiDPI: Bool? = nil,
                   name: String? = nil, ownerDeviceID: String? = nil) -> ScreenSession {
        let size = defaultSize
        let id = (screens.map(\.id).max() ?? 0) + 1
        let config = ScreenConfig(
            id: id,
            name: name ?? "WebScreen \(id)",
            width: Self.sanitize(width ?? size.width),
            height: Self.sanitize(height ?? size.height),
            hiDPI: hiDPI ?? defaultHiDPI,
            ownerDeviceID: ownerDeviceID
        )
        let session = makeSession(config)
        screens.append(session)
        saveScreens()
        return session
    }

    func removeScreen(_ screen: ScreenSession) async {
        idleTasks[screen.id]?.cancel()
        idleTasks[screen.id] = nil
        await screen.stop()
        screens.removeAll { $0.id == screen.id }
        for index in devices.indices {
            if devices[index].pinnedScreenID == screen.id { devices[index].pinnedScreenID = nil }
            if devices[index].ownScreenID == screen.id { devices[index].ownScreenID = nil }
        }
        ensureFixedScreen()
        if primaryScreenID == screen.id, let first = fixedScreens.first { primaryScreenID = first.id }
        saveScreens()
        saveDevices()
        await reassignAll()
    }

    /// Apply a changed size/name of a running screen
    func apply(_ screen: ScreenSession) {
        saveScreens()
        guard isRunning, let server, let activeGlobal else { return }
        let codec = desiredCodec(for: screen)
        Task { await screen.restart(global: activeGlobal, codec: codec, server: server) }
    }

    func screenChanged() {
        saveScreens()
    }

    func setKeepAlive(_ screen: ScreenSession, _ keepAlive: Bool) {
        screen.config.keepAlive = keepAlive
        saveScreens()
        guard isRunning, isUsable(screen) else { return }
        Task {
            if keepAlive { await ensureRunning(screen) } else { scheduleIdleCheck(screen.id) }
        }
    }

    func screen(_ id: Int?) -> ScreenSession? {
        guard let id else { return nil }
        return screens.first { $0.id == id }
    }

    func clients(on screen: ScreenSession) -> [ClientInfo] {
        clients.filter { $0.screenID == screen.id }
    }

    func url(for screen: ScreenSession?) -> String? {
        guard let address = addresses.first else { return nil }
        let base = "http://\(address):\(activePort ?? port)"
        guard let screen else { return base }
        return base + "/?screen=\(screen.id)"
    }

    /// HTTPS address of the low-latency mode (the plain address switches there automatically)
    var secureURL: String? {
        guard case .active = secureStatus, let address = addresses.first, let activePort else { return nil }
        return "https://\(SecureOrigin.hostname(for: address)):\(activePort + 2)"
    }

    // MARK: Managing devices

    func isOnline(_ device: KnownDevice) -> Bool {
        clients.contains { $0.deviceKey == device.id }
    }

    /// Set a manual assignment (`nil` = automatic by mode)
    func pin(_ device: KnownDevice, to screenID: Int?) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[index].pinnedScreenID = screenID
        saveDevices()
        reassignAllLater()
    }

    func rename(_ device: KnownDevice, to name: String) {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        devices[index].name = trimmed
        if let own = screen(devices[index].ownScreenID) {
            own.config.name = trimmed
        }
        saveDevices()
        saveScreens()
    }

    func forget(_ device: KnownDevice) async {
        if let own = screen(device.ownScreenID) {
            await removeScreen(own)
        }
        devices.removeAll { $0.id == device.id }
        saveDevices()
    }

    func disconnect(_ client: ClientInfo) {
        server?.disconnect(client.id)
    }

    /// Describes where a device without a manual assignment would end up
    func automaticTargetName(for device: KnownDevice) -> String {
        switch assignmentMode {
        case .shared: return primaryScreen?.config.name ?? "main screen"
        case .perDevice: return "own screen"
        }
    }

    // MARK: Assignment logic

    private func handleJoin(_ connection: UUID, _ request: JoinRequest) async {
        guard isRunning else { return }

        // Remember or recognize the device
        let address = request.address.isEmpty ? nil : request.address
        if let index = devices.firstIndex(where: { $0.id == request.deviceKey }) {
            devices[index].lastSeen = Date()
            devices[index].lastAddress = address
        } else {
            devices.append(KnownDevice(id: request.deviceKey, name: request.deviceName,
                                       pinnedScreenID: nil, ownScreenID: nil, lastSeen: Date(),
                                       lastAddress: address))
        }
        saveDevices()

        connectionDevice[connection] = request.deviceKey
        connectionHEVC[connection] = request.supportsHEVC
        connectionWebRTC[connection] = request.supportsWebRTC
        if let wanted = request.screenID, screen(wanted) != nil {
            connectionOverride[connection] = wanted
        }

        guard let target = target(for: connection, request: request) else {
            server?.reject(connection, message: "No screen is available in WebScreen.")
            return
        }
        await assign(connection, to: target)
    }

    private func handleLeave(_ connection: UUID) async {
        let previous = assignments.removeValue(forKey: connection)
        connectionDevice[connection] = nil
        connectionHEVC[connection] = nil
        connectionWebRTC[connection] = nil
        connectionOverride[connection] = nil
        if let previous, let screen = screen(previous) {
            scheduleIdleCheck(previous)
            await updateCodec(screen)   // possibly back up to HEVC
        }
    }

    /// Order: 1. `?screen=` in the address, 2. manual assignment, 3. mode
    private func target(for connection: UUID, request: JoinRequest? = nil) -> ScreenSession? {
        if let override = connectionOverride[connection], let screen = screen(override), isUsable(screen) {
            return screen
        }
        guard let key = connectionDevice[connection],
              let device = devices.first(where: { $0.id == key }) else {
            return assignmentMode == .shared ? primaryScreen : nil
        }
        if let pinned = screen(device.pinnedScreenID), isUsable(pinned) {
            return pinned
        }
        switch assignmentMode {
        case .shared:
            return primaryScreen
        case .perDevice:
            return ownScreen(for: device, request: request)
        }
    }

    private func ownScreen(for device: KnownDevice, request: JoinRequest?) -> ScreenSession {
        if let existing = screen(device.ownScreenID) { return existing }
        var width: Int? = nil, height: Int? = nil, hiDPI: Bool? = nil
        if autoMatchDevice, let request {
            if request.pixelRatio >= 1.5 {
                // Retina/phones: points = CSS pixels, rendered at 2×
                width = request.width
                height = request.height
                hiDPI = true
            } else {
                // Windows scaling 125 %/150 % etc.: use the physical pixels 1:1 – otherwise the
                // browser would stretch a smaller image and text gets blurry
                width = Int((Double(request.width) * request.pixelRatio).rounded())
                height = Int((Double(request.height) * request.pixelRatio).rounded())
                hiDPI = false
            }
        }
        let screen = addScreen(width: width, height: height, hiDPI: hiDPI,
                               name: device.name, ownerDeviceID: device.id)
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index].ownScreenID = screen.id
            saveDevices()
        }
        return screen
    }

    private func assign(_ connection: UUID, to screen: ScreenSession) async {
        let previous = assignments[connection]
        assignments[connection] = screen.id
        idleTasks[screen.id]?.cancel()
        idleTasks[screen.id] = nil
        await ensureRunning(screen)
        server?.assign(connection, to: screen.id)
        if let previous, previous != screen.id, let old = self.screen(previous) {
            scheduleIdleCheck(previous)
            await updateCodec(old)
        }
    }

    /// Redistribute all connected devices (after a mode or assignment change)
    func reassignAll() async {
        guard isRunning else { return }
        for connection in Array(assignments.keys) {
            guard let target = target(for: connection) else { continue }
            if assignments[connection] != target.id {
                await assign(connection, to: target)
            }
        }
    }

    /// Switches off screens the current mode never uses (e.g. the regular screens in
    /// “one per device”) – even if they are set to “Keep Always Ready”.
    private func deactivateUnusedScreens() async {
        for screen in screens where !isUsable(screen) {
            idleTasks[screen.id]?.cancel()
            idleTasks[screen.id] = nil
            guard !assignments.values.contains(screen.id) else { continue }
            if screen.isRunning || screen.isBusy { await screen.stop() }
        }
        // Back in a mode that uses them: bring “Keep Always Ready” screens up again
        for screen in screens where screen.config.keepAlive && isUsable(screen) {
            await ensureRunning(screen)
        }
    }

    private func reassignAllLater() {
        guard isRunning else { return }
        Task { await reassignAll() }
    }

    private func ensureRunning(_ screen: ScreenSession) async {
        guard let server, let activeGlobal else { return }
        if !screen.isRunning && !screen.isBusy {
            await screen.start(global: activeGlobal, codec: desiredCodec(for: screen), server: server)
        }
        // Also catches up on settings that changed during startup
        if screen.isRunning, let current = self.activeGlobal {
            await screen.applyGlobal(current, codec: desiredCodec(for: screen))
        }
    }

    // MARK: Applying settings live

    /// Debounced so that e.g. a slider doesn't rebuild on every intermediate value
    private func applyLiveSettingsLater() {
        guard isRunning else { return }
        liveApplyTask?.cancel()
        liveApplyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.applyLiveSettings()
        }
    }

    private func applyLiveSettings() async {
        guard isRunning else { return }
        let global = globalSettings
        activeGlobal = global
        for screen in screens where screen.isRunning {
            await screen.applyGlobal(global, codec: desiredCodec(for: screen))
        }
    }

    // MARK: Sessions

    private func makeSession(_ config: ScreenConfig) -> ScreenSession {
        let session = ScreenSession(config: config)
        attach(session)
        return session
    }

    /// If a screen with viewers stops capturing unexpectedly, it is restarted
    /// once automatically – devices stay connected meanwhile.
    private func attach(_ session: ScreenSession) {
        session.onConfigChanged = { [weak self] in self?.saveScreens() }
        session.onUnexpectedStop = { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session else { return }
                let id = session.id
                if let last = self.lastRecovery[id], Date().timeIntervalSince(last) < 15 {
                    self.server?.unregisterScreen(id)   // don't keep devices waiting forever
                    return
                }
                self.lastRecovery[id] = Date()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.isRunning, self.assignments.values.contains(id) else { return }
                await self.ensureRunning(session)
            }
        }
    }

    private func updateCodec(_ screen: ScreenSession) async {
        guard screen.isRunning, assignments.values.contains(screen.id) else { return }
        let codec = desiredCodec(for: screen)
        if screen.codec != codec { screen.switchCodec(to: codec) }
    }

    /// “Video auto”: HEVC if all devices on the screen can play it, otherwise H.264
    private func desiredCodec(for screen: ScreenSession) -> StreamCodec {
        switch (activeGlobal ?? globalSettings).mode {
        case .realtime:
            // WebRTC needs every viewer on the screen to support it, otherwise H.264 via MSE
            let viewers = assignments.filter { $0.value == screen.id }.map(\.key)
            return viewers.allSatisfy { connectionWebRTC[$0] ?? true } ? .webrtc : .h264
        case .jpeg: return .jpeg
        case .h264: return .h264
        case .hevc: return .hevc
        case .videoAuto:
            let viewers = assignments.filter { $0.value == screen.id }.map(\.key)
            let allHEVC = viewers.allSatisfy { connectionHEVC[$0] ?? false }
            return allHEVC ? .hevc : .h264
        }
    }

    /// Turn off a screen without devices after a short time (unless “keep always ready”)
    private func scheduleIdleCheck(_ screenID: Int) {
        guard let screen = screen(screenID), !screen.config.keepAlive else { return }
        idleTasks[screenID]?.cancel()
        idleTasks[screenID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.idleTimeout * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard !self.assignments.values.contains(screenID), !screen.config.keepAlive else { return }
            await screen.stop()
            self.idleTasks[screenID] = nil
        }
    }

    // MARK: Helpers

    private func ensureFixedScreen() {
        if fixedScreens.isEmpty {
            let size = defaultSize
            let id = (screens.map(\.id).max() ?? 0) + 1
            screens.insert(makeSession(ScreenConfig(id: id, name: "WebScreen \(id)", width: size.width,
                                                    height: size.height, hiDPI: defaultHiDPI)), at: 0)
            primaryScreenID = id
            saveScreens()
        }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    private func saveScreens() {
        if let data = try? JSONEncoder().encode(screens.map(\.config)) {
            defaults.set(data, forKey: "screens")
        }
    }

    private func saveDevices() {
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: "devices")
        }
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorText = "Could not change the login item: \(error.localizedDescription)"
        }
    }

    /// Even number between 320 and 5120
    static func sanitize(_ value: Int) -> Int {
        let clamped = min(max(value, 320), 5120)
        return clamped - clamped % 2
    }

    func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    var runningScreenCount: Int { screens.filter(\.isRunning).count }

    /// Short status that fits on one line
    var statusLine: String {
        switch state {
        case .stopped: return "Inactive"
        case .starting: return "Starting …"
        case .stopping: return "Stopping …"
        case .running: return clients.isEmpty ? "Ready" : "Active"
        }
    }
}
