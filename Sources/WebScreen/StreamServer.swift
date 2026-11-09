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
    /// Screen size of the device in CSS pixels (points) and pixel ratio
    var width: Int
    var height: Int
    var pixelRatio: Double
    var deviceName: String
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
    }

    private final class Client {
        let id = UUID()
        let connection: NWConnection
        let address: String
        let connectedAt = Date()
        var deviceName = "Browser"
        var deviceKey = ""
        var supportsHEVC = false
        var screenID: Int?
        var inflight = 0
        var needsSync = true
        var skipped = 0
        var frames = 0
        var bytes = 0
        var fps = 0.0
        var mbps = 0.0

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
    private let page: Data
    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private var statsTimer: DispatchSourceTimer?
    private var clients: [UUID: Client] = [:]
    private var channels: [Int: ScreenChannel] = [:]
    private var initPackets: [Int: Data] = [:]
    private var syncPending: Set<Int> = []
    private var lastSync: [Int: UInt64] = [:]

    // For queries from other threads (e.g. “does this screen have viewers?”)
    private let countLock = NSLock()
    private var receiverCounts: [Int: Int] = [:]

    init(httpPort: UInt16, wsPort: UInt16, pageHTML: String) {
        self.httpPort = httpPort
        self.wsPort = wsPort
        self.page = Data(pageHTML.replacingOccurrences(of: "__WS_PORT__", with: String(wsPort)).utf8)
    }

    // MARK: Start/stop

    func start() throws {
        let httpPort = self.httpPort
        let wsPort = self.wsPort

        let httpParams = NWParameters.tcp
        httpParams.allowLocalEndpointReuse = true
        let http = try NWListener(using: httpParams, on: NWEndpoint.Port(rawValue: httpPort)!)
        http.newConnectionHandler = { [weak self] in self?.handleHTTP($0) }
        http.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onError?("Port \(httpPort) is not available: \(error.localizedDescription)")
            }
        }

        let wsParams = NWParameters.tcp
        wsParams.allowLocalEndpointReuse = true
        if let tcp = wsParams.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsParams.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        let ws = try NWListener(using: wsParams, on: NWEndpoint.Port(rawValue: wsPort)!)
        ws.newConnectionHandler = { [weak self] in self?.handleWebSocket($0) }
        ws.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onError?("Port \(wsPort) is not available: \(error.localizedDescription)")
            }
        }

        http.start(queue: queue)
        ws.start(queue: queue)
        httpListener = http
        wsListener = ws

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.updateStats() }
        timer.resume()
        statsTimer = timer
    }

    func stop() {
        queue.sync {
            statsTimer?.cancel()
            statsTimer = nil
            httpListener?.cancel()
            wsListener?.cancel()
            httpListener = nil
            wsListener = nil
            for client in clients.values { client.connection.cancel() }
            clients.removeAll()
            channels.removeAll()
            initPackets.removeAll()
            notifyClients()
        }
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
            let message = detachClients
                ? #"{"type":"waiting","message":"This screen was removed."}"#
                : #"{"type":"waiting","message":"Setting up the screen again …"}"#
            for client in self.clients.values where client.screenID == id {
                if detachClients { client.screenID = nil }
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
            client.screenID = screenID
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

    /// Init segment (video only): stored and sent to new devices first
    func setInit(_ packet: Data, screen id: Int) {
        queue.async {
            self.initPackets[id] = packet
            for client in self.clients.values where client.screenID == id {
                client.needsSync = true
                self.sendBinary(packet, to: client, counted: false)
            }
        }
    }

    func broadcast(_ packet: Data, isSync: Bool, screen id: Int) {
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
                client.bytes += packet.count
                self.sendBinary(packet, to: client, counted: true)
            }
        }
    }

    private func welcome(_ client: Client) {
        guard let screenID = client.screenID, let channel = channels[screenID] else { return }
        client.needsSync = true
        let hello: [String: Any] = ["type": "hello", "mode": channel.codec.rawValue, "screen": screenID, "name": channel.name]
        if let data = try? JSONSerialization.data(withJSONObject: hello), let json = String(data: data, encoding: .utf8) {
            sendText(json, to: client)
        }
        if let initPacket = initPackets[screenID] {
            sendBinary(initPacket, to: client, counted: false)
        }
        requestSync(screen: screenID)
    }

    private func updateStats() {
        guard !clients.isEmpty else { return }
        var congestion: [Int: Bool] = [:]
        for client in clients.values {
            client.fps = Double(client.frames)
            client.mbps = Double(client.bytes) * 8 / 1_000_000
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
            } else {
                response = Self.httpResponse(status: "404 Not Found", type: "text/plain; charset=utf-8",
                                             body: Data("Not found".utf8))
            }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func httpResponse(status: String, type: String, body: Data) -> Data {
        let header = "HTTP/1.1 \(status)\r\n" +
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
            if let data, let text = String(data: data, encoding: .utf8) {
                if text == "sync" {
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
        client.deviceKey = (object["device"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? client.id.uuidString
        client.supportsHEVC = (object["hevc"] as? Bool) ?? false
        let request = JoinRequest(
            deviceKey: client.deviceKey,
            screenID: (object["screen"] as? NSNumber)?.intValue,
            supportsHEVC: client.supportsHEVC,
            width: (object["width"] as? NSNumber)?.intValue ?? 1280,
            height: (object["height"] as? NSNumber)?.intValue ?? 800,
            pixelRatio: (object["dpr"] as? NSNumber)?.doubleValue ?? 1,
            deviceName: client.deviceName
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
