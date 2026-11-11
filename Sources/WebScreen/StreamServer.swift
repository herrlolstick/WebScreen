import Foundation
import Network

/// Info about a connected receiving device (for the device list in the UI)
struct ClientInfo: Identifiable, Equatable {
    let id: UUID
    /// Persistent device identifier (stored in the browser)
    let deviceKey: String
    let supportsHEVC: Bool
    let address: String
    let deviceName: String
    let connectedAt: Date
    var screenID: Int?
    var fps: Double
    var mbps: Double
}

/// What a browser sends when connecting
struct JoinRequest {
    /// Persistent device identifier
    var deviceKey: String
    /// Explicitly requested screen (from `?screen=` in the address)
    var screenID: Int?
    var supportsHEVC: Bool
    /// Browser has `RTCPeerConnection` (real-time mode)
    var supportsWebRTC: Bool
    /// Screen size of the device in CSS pixels (points) and pixel ratio
    var width: Int
    var height: Int
    var pixelRatio: Double
    var deviceName: String
    /// Network address – browsers on the same computer share it
    var address: String = ""
}

/// An HTTP server for the receiver page and a WebSocket server for the image data –
/// shared by all virtual screens. Every device is assigned to exactly one screen
/// and only receives its packets.
///
/// Every device joins at a “sync” packet (full frame or keyframe). If a packet has
/// to be skipped for a device, it waits for the next sync packet.
final class StreamServer {
    var onClientsChanged: (([ClientInfo]) -> Void)?
    /// A device has joined – the app decides which screen it gets
    var onJoin: ((UUID, JoinRequest) -> Void)?
    /// A device has closed the connection
    var onLeave: ((UUID, Int?) -> Void)?
    var onError: ((String) -> Void)?

    /// Callbacks of a screen (run on the server queue)
    struct ScreenChannel {
        var name: String
        var codec: StreamCodec
        var onSyncNeeded: () -> Void
        var onCongestion: (Bool) -> Void
        /// WebRTC: a device now watches / no longer watches this screen
        var onClientAttached: (UUID) -> Void = { _ in }
        var onClientDetached: (UUID) -> Void = { _ in }
        /// WebRTC: signaling message (JSON) from a device on this screen
        var onSignal: (UUID, String) -> Void = { _, _ in }
    }

    private final class Client {
        let id = UUID()
        let connection: NWConnection
        let address: String
        let connectedAt = Date()
        var deviceName = "Browser"
        var deviceKey = ""
        var supportsHEVC = false
        /// Decodes with WebCodecs and gets raw access units instead of fMP4
        var webCodecs = false
        var supportsWebRTC = false
        var screenID: Int?
        /// Heartbeat: last sign of life from a page that sends pings
        var lastHeard = Date()
        var sendsPings = false
        var inflight = 0
        var needsSync = true
        var skipped = 0
        var frames = 0
        var bytes = 0
        var fps = 0.0
        var mbps = 0.0
        /// Real-time mode: the media bypasses this server, so the page reports what it receives
        var reportedFps = 0.0
        var reportedMbps = 0.0
        var reportedAt: Date?

        init(_ connection: NWConnection) {
            self.connection = connection
            self.address = Self.describe(connection.endpoint)
        }

        static func describe(_ endpoint: NWEndpoint) -> String {
            if case .hostPort(let host, _) = endpoint {
                var text = "\(host)"
                if text.hasPrefix("::ffff:") { text.removeFirst(7) }
                if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
                return text
            }
            return "\(endpoint)"
        }

        var info: ClientInfo {
            ClientInfo(id: id, deviceKey: deviceKey, supportsHEVC: supportsHEVC, address: address,
                       deviceName: deviceName, connectedAt: connectedAt,
                       screenID: screenID, fps: fps, mbps: mbps)
        }
    }

    private static let maxInflight = 3

    private let queue = DispatchQueue(label: "webscreen.server", qos: .userInteractive)
    private let httpPort: UInt16
    private let wsPort: UInt16
    private let secure: SecureEndpoint?
    private let page: Data
    private var listeners: [NWListener] = []
    private var statsTimer: DispatchSourceTimer?
    private var clients: [UUID: Client] = [:]
    private var channels: [Int: ScreenChannel] = [:]
    private var initPackets: [Int: Data] = [:]
    private var initPacketsRaw: [Int: Data] = [:]
    private var syncPending: Set<Int> = []
    private var lastSync: [Int: UInt64] = [:]

    // For queries from other threads (e.g. “does this screen have viewers?”)
    private let countLock = NSLock()
    private var receiverCounts: [Int: Int] = [:]

    /// HTTPS page + secure WebSocket (needed for WebCodecs, see `SecureOrigin`)
    struct SecureEndpoint {
        let identity: sec_identity_t
        let httpsPort: UInt16
        let wssPort: UInt16
        /// Hostname suffix, e.g. "local-ip.sh"
        let domain: String
    }

    init(httpPort: UInt16, wsPort: UInt16, pageHTML: String, secure: SecureEndpoint? = nil, defaultIPv4: String? = nil) {
        self.httpPort = httpPort
        self.wsPort = wsPort
        self.secure = secure
        let html = pageHTML
            .replacingOccurrences(of: "__WS_PORT__", with: String(wsPort))
            .replacingOccurrences(of: "__SECURE_PORT__", with: secure.map { String($0.httpsPort) } ?? "")
            .replacingOccurrences(of: "__WSS_PORT__", with: secure.map { String($0.wssPort) } ?? "")
            .replacingOccurrences(of: "__SECURE_DOMAIN__", with: secure?.domain ?? "")
            .replacingOccurrences(of: "__SECURE_HOST__", with: defaultIPv4 ?? "")
        self.page = Data(html.utf8)
    }

    // MARK: Start/stop

    func start() throws {
        var created = [
            try makeListener(port: httpPort, tls: nil, webSocket: false),
            try makeListener(port: wsPort, tls: nil, webSocket: true),
        ]
        if let secure {
            created.append(try makeListener(port: secure.httpsPort, tls: secure.identity, webSocket: false))
            created.append(try makeListener(port: secure.wssPort, tls: secure.identity, webSocket: true))
        }
        for listener in created { listener.start(queue: queue) }
        listeners = created

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.updateStats()
            self?.heartbeat()
        }
        timer.resume()
        statsTimer = timer
    }

    /// Lets pages notice a dead connection (e.g. Wi-Fi gone, Mac asleep) quickly and
    /// drops pages that stopped answering, so their screens can idle out.
    private func heartbeat() {
        let now = Date()
        for client in clients.values {
            if client.sendsPings, now.timeIntervalSince(client.lastHeard) > 10 {
                client.connection.cancel()
                continue
            }
            sendText(#"{"type":"ping"}"#, to: client)
        }
    }

    func stop() {
        queue.sync {
            statsTimer?.cancel()
            statsTimer = nil
            for listener in listeners { listener.cancel() }
            listeners.removeAll()
            for client in clients.values { client.connection.cancel() }
            clients.removeAll()
            channels.removeAll()
            initPackets.removeAll()
            initPacketsRaw.removeAll()
            notifyClients()
        }
    }

    private func makeListener(port: UInt16, tls identity: sec_identity_t?, webSocket: Bool) throws -> NWListener {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params: NWParameters
        if let identity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: tls, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        params.allowLocalEndpointReuse = true
        if webSocket {
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            params.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        }
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            if webSocket { self?.handleWebSocket(connection) } else { self?.handleHTTP(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onError?("Port \(port) is not available: \(error.localizedDescription)")
            }
        }
        return listener
    }

    // MARK: Screens

    /// Registers a screen. `announce` = greet devices again (needed when the method
    /// changed or the screen is new). Without `announce` only the callbacks are
    /// swapped – devices don't notice anything, the new pipeline starts with an
    /// entry point anyway.
    func registerScreen(_ id: Int, channel: ScreenChannel, announce: Bool = true) {
        queue.async {
            let known = self.channels[id] != nil
            self.channels[id] = channel
            guard announce || !known else { return }
            self.initPackets[id] = nil
            self.initPacketsRaw[id] = nil
            // Greet devices that are already waiting for this screen
            for client in self.clients.values where client.screenID == id {
                self.welcome(client)
            }
        }
    }

    /// Unregisters a screen. With `detachClients == false` devices stay assigned to it
    /// (e.g. while it is recreated after a resolution change) and are greeted
    /// as soon as it is registered again.
    func unregisterScreen(_ id: Int, detachClients: Bool = true) {
        queue.async {
            self.channels[id] = nil
            self.initPackets[id] = nil
            self.initPacketsRaw[id] = nil
            let message = detachClients
                ? #"{"type":"waiting","message":"This screen was removed."}"#
                : #"{"type":"waiting","message":"Setting up the screen again …"}"#
            for client in self.clients.values where client.screenID == id {
                if detachClients { self.moveClient(client, to: nil) } else { self.channels[id]?.onClientDetached(client.id) }
                client.needsSync = true
                self.sendText(message, to: client)
            }
            self.notifyClients()
        }
    }

    /// Assigns a device to a screen (also to move it to another one)
    func assign(_ clientID: UUID, to screenID: Int) {
        queue.async {
            guard let client = self.clients[clientID] else { return }
            self.moveClient(client, to: screenID)
            self.notifyClients()
            if self.channels[screenID] != nil {
                self.welcome(client)
            } else {
                self.sendText(#"{"type":"waiting","message":"Preparing the screen …"}"#, to: client)
            }
        }
    }

    func reject(_ clientID: UUID, message: String) {
        queue.async {
            guard let client = self.clients[clientID] else { return }
            let json = (try? JSONSerialization.data(withJSONObject: ["type": "waiting", "message": message]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            self.sendText(json, to: client)
        }
    }

    func disconnect(_ clientID: UUID) {
        queue.async { self.clients[clientID]?.connection.cancel() }
    }

    /// Thread-safe: does this screen currently have viewers?
    func hasReceivers(screen id: Int) -> Bool {
        countLock.lock(); defer { countLock.unlock() }
        return (receiverCounts[id] ?? 0) > 0
    }

    // MARK: Streaming

    /// Init segment (video only): stored and sent to new devices first.
    /// `raw` is the decoder configuration for WebCodecs receivers.
    func setInit(_ packet: Data, raw: Data?, screen id: Int) {
        queue.async {
            self.initPackets[id] = packet
            self.initPacketsRaw[id] = raw
            for client in self.clients.values where client.screenID == id {
                client.needsSync = true
                self.sendBinary(client.webCodecs ? (raw ?? packet) : packet, to: client, counted: false)
            }
        }
    }

    func broadcast(_ packet: Data, raw: Data? = nil, isSync: Bool, screen id: Int) {
        queue.async {
            for client in self.clients.values where client.screenID == id {
                if client.needsSync && !isSync { continue }
                if client.inflight >= Self.maxInflight {
                    client.needsSync = true
                    client.skipped += 1
                    continue
                }
                if isSync { client.needsSync = false }
                client.frames += 1
                let payload = client.webCodecs ? (raw ?? packet) : packet
                client.bytes += payload.count
                self.sendBinary(payload, to: client, counted: true)
            }
        }
    }

    /// Changes a device's screen and tells the screen it leaves (WebRTC closes the peer)
    private func moveClient(_ client: Client, to screenID: Int?) {
        if let old = client.screenID, old != screenID {
            channels[old]?.onClientDetached(client.id)
        }
        client.screenID = screenID
    }

    /// WebRTC signaling towards a device
    func sendSignal(_ json: String, to clientID: UUID) {
        queue.async {
            guard let client = self.clients[clientID] else { return }
            self.sendText(json, to: client)
        }
    }

    private func welcome(_ client: Client) {
        guard let screenID = client.screenID, let channel = channels[screenID] else { return }
        client.needsSync = true
        let hello: [String: Any] = ["type": "hello", "mode": channel.codec.rawValue, "screen": screenID, "name": channel.name]
        if let data = try? JSONSerialization.data(withJSONObject: hello), let json = String(data: data, encoding: .utf8) {
            sendText(json, to: client)
        }
        if let initPacket = client.webCodecs ? (initPacketsRaw[screenID] ?? initPackets[screenID]) : initPackets[screenID] {
            sendBinary(initPacket, to: client, counted: false)
        }
        channel.onClientAttached(client.id)   // WebRTC: send the offer
        requestSync(screen: screenID)
    }

    private func updateStats() {
        guard !clients.isEmpty else { return }
        var congestion: [Int: Bool] = [:]
        for client in clients.values {
            if client.frames == 0, let reportedAt = client.reportedAt, Date().timeIntervalSince(reportedAt) < 3 {
                client.fps = client.reportedFps
                client.mbps = client.reportedMbps
            } else {
                client.fps = Double(client.frames)
                client.mbps = Double(client.bytes) * 8 / 1_000_000
            }
            if let screenID = client.screenID {
                // Only count real, significant dropouts (more than 10 % of frames skipped).
                // A full send buffer at the moment of measuring is normal at 60 fps.
                let total = client.frames + client.skipped
                let congested = client.skipped >= 2 && Double(client.skipped) > Double(total) * 0.1
                congestion[screenID] = (congestion[screenID] ?? false) || congested
            }
            client.frames = 0
            client.bytes = 0
            client.skipped = 0
        }
        notifyClients()
        for (screenID, congested) in congestion {
            channels[screenID]?.onCongestion(congested)
        }
    }

    /// Request an entry point – at most every 250 ms per screen, so a slow
    /// device doesn't keep triggering expensive full frames.
    private func requestSync(screen id: Int) {
        guard !syncPending.contains(id) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let remaining = 250_000_000 - Int64(bitPattern: now &- (lastSync[id] ?? 0))
        if remaining <= 0 {
            lastSync[id] = now
            channels[id]?.onSyncNeeded()
            return
        }
        syncPending.insert(id)
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(remaining))) { [weak self] in
            guard let self else { return }
            self.syncPending.remove(id)
            self.lastSync[id] = DispatchTime.now().uptimeNanoseconds
            if self.clients.values.contains(where: { $0.screenID == id && $0.needsSync }) {
                self.channels[id]?.onSyncNeeded()
            }
        }
    }

    // MARK: HTTP

    private func handleHTTP(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self, error == nil, let data,
                  let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let parts = request.split(separator: " ", maxSplits: 2)
            let path = parts.count > 1 ? String(parts[1]) : "/"

            let response: Data
            if path == "/" || path.hasPrefix("/?") || path.hasPrefix("/index.html") {
                response = Self.httpResponse(status: "200 OK", type: "text/html; charset=utf-8", body: self.page)
            } else if path.hasPrefix("/ping") {
                // Lets the plain-HTTP page check whether the HTTPS address is reachable
                response = Self.httpResponse(status: "204 No Content", type: "text/plain", body: Data(),
                                             extraHeaders: "Access-Control-Allow-Origin: *\r\n")
            } else {
                response = Self.httpResponse(status: "404 Not Found", type: "text/plain; charset=utf-8",
                                             body: Data("Not found".utf8))
            }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func httpResponse(status: String, type: String, body: Data, extraHeaders: String = "") -> Data {
        let header = "HTTP/1.1 \(status)\r\n" + extraHeaders +
            "Content-Type: \(type)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    // MARK: WebSocket

    private func handleWebSocket(_ connection: NWConnection) {
        let client = Client(connection)
        let id = client.id

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.clients[id] = client
                self.notifyClients()
                self.receive(on: client)
            case .failed(_):
                connection.cancel()
            case .cancelled:
                if let removed = self.clients.removeValue(forKey: id) {
                    self.notifyClients()
                    if let screenID = removed.screenID { self.channels[screenID]?.onClientDetached(id) }
                    self.onLeave?(id, removed.screenID)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Messages from the browser: "join:{…}" (sign-in) and "sync" (entry point please)
    private func receive(on client: Client) {
        client.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil {
                client.connection.cancel()
                return
            }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata, metadata.opcode == .close {
                client.connection.cancel()
                return
            }
            client.lastHeard = Date()
            if let data, let text = String(data: data, encoding: .utf8) {
                if text == "ping" {
                    client.sendsPings = true
                } else if text.hasPrefix("stats:") {
                    let object = (try? JSONSerialization.jsonObject(with: Data(text.dropFirst(6).utf8))) as? [String: Any]
                    client.reportedFps = (object?["fps"] as? NSNumber)?.doubleValue ?? 0
                    client.reportedMbps = (object?["mbps"] as? NSNumber)?.doubleValue ?? 0
                    client.reportedAt = Date()
                } else if text.hasPrefix("rtc:") {
                    if let screenID = client.screenID {
                        self.channels[screenID]?.onSignal(client.id, String(text.dropFirst(4)))
                    }
                } else if text == "sync" {
                    client.needsSync = true
                    if let screenID = client.screenID { self.requestSync(screen: screenID) }
                } else if text.hasPrefix("join:") {
                    self.handleJoin(client, json: String(text.dropFirst(5)))
                }
            }
            self.receive(on: client)
        }
    }

    private func handleJoin(_ client: Client, json: String) {
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        let ua = object["ua"] as? String ?? ""
        client.deviceName = Self.deviceName(fromUserAgent: ua)
        // Further WebScreen tabs in the same browser are devices of their own
        if let tab = (object["tab"] as? NSNumber)?.intValue, tab > 1 {
            client.deviceName += " · Tab \(tab)"
        }
        client.deviceKey = (object["device"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? client.id.uuidString
        client.supportsHEVC = (object["hevc"] as? Bool) ?? false
        client.webCodecs = (object["wc"] as? Bool) ?? false
        client.supportsWebRTC = (object["rtc"] as? Bool) ?? false
        let request = JoinRequest(
            deviceKey: client.deviceKey,
            screenID: (object["screen"] as? NSNumber)?.intValue,
            supportsHEVC: client.supportsHEVC,
            supportsWebRTC: client.supportsWebRTC,
            width: (object["width"] as? NSNumber)?.intValue ?? 1280,
            height: (object["height"] as? NSNumber)?.intValue ?? 800,
            pixelRatio: (object["dpr"] as? NSNumber)?.doubleValue ?? 1,
            deviceName: client.deviceName,
            address: client.address
        )
        notifyClients()
        onJoin?(client.id, request)
    }

    static func deviceName(fromUserAgent ua: String) -> String {
        let browser: String
        if ua.contains("Edg/") { browser = "Edge" }
        else if ua.contains("Firefox/") { browser = "Firefox" }
        else if ua.contains("Chrome/") || ua.contains("CriOS/") { browser = "Chrome" }
        else if ua.contains("Safari/") { browser = "Safari" }
        else { browser = "Browser" }

        let device: String
        if ua.contains("iPad") || (ua.contains("Macintosh") && ua.contains("Mobile")) { device = "iPad" }
        else if ua.contains("iPhone") { device = "iPhone" }
        else if ua.contains("Android") { device = "Android" }
        else if ua.contains("Windows") { device = "Windows" }
        else if ua.contains("CrOS") { device = "ChromeOS" }
        else if ua.contains("Linux") { device = "Linux" }
        else if ua.contains("Macintosh") { device = "Mac" }
        else { device = "Device" }
        return "\(browser) on \(device)"
    }

    private func sendText(_ text: String, to client: Client) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        client.connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                               completion: .contentProcessed { _ in })
    }

    private func sendBinary(_ data: Data, to client: Client, counted: Bool) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        if counted { client.inflight += 1 }
        client.connection.send(content: data, contentContext: context, isComplete: true,
                               completion: .contentProcessed { [weak self] _ in
                                   // runs on `queue` because the connection was started there
                                   guard counted else { return }
                                   client.inflight -= 1
                                   if client.needsSync && client.inflight == 0, let screenID = client.screenID {
                                       self?.requestSync(screen: screenID)
                                   }
                               })
    }

    private func notifyClients() {
        var counts: [Int: Int] = [:]
        for client in clients.values {
            if let screenID = client.screenID { counts[screenID, default: 0] += 1 }
        }
        countLock.lock()
        receiverCounts = counts
        countLock.unlock()
        let infos = clients.values.map(\.info).sorted { $0.connectedAt < $1.connectedAt }
        onClientsChanged?(infos)
    }
}
