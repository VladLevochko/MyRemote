import Foundation
import MyRemoteCore
import Network

public struct ServerConfig {
    /// Port to try first. 0 means "any free port". If the preferred port is busy the
    /// server falls back to any free port (PROTOCOL.md section 1).
    public var preferredPort: UInt16
    /// Advertise `_myremote._tcp` over Bonjour.
    public var advertise: Bool
    /// Bonjour instance name (the computer name).
    public var serviceName: String
    public var session: SessionConfig
    /// Time a client has to finish the TCP/TLS/WebSocket handshake.
    public var handshakeTimeout: TimeInterval
    /// After sending a close frame, how long to wait for the peer before dropping TCP.
    public var closeGrace: TimeInterval
    /// Largest accepted WebSocket message.
    public var maximumMessageSize: Int
    /// Simultaneous connections (authenticated or not) the server will hold.
    public var maximumConnections: Int

    public static let defaultPort: UInt16 = 47110
    public static let bonjourType = "_myremote._tcp"
    public static let bonjourDomain = "local."

    public init(
        preferredPort: UInt16 = ServerConfig.defaultPort,
        advertise: Bool = true,
        serviceName: String,
        session: SessionConfig = SessionConfig(),
        handshakeTimeout: TimeInterval = 10,
        closeGrace: TimeInterval = 1,
        maximumMessageSize: Int = 256 * 1024,
        maximumConnections: Int = 32
    ) {
        self.preferredPort = preferredPort
        self.advertise = advertise
        self.serviceName = serviceName
        self.session = session
        self.handshakeTimeout = handshakeTimeout
        self.closeGrace = closeGrace
        self.maximumMessageSize = maximumMessageSize
        self.maximumConnections = maximumConnections
    }
}

public struct ConnectedClient: Equatable, Sendable {
    public let id: UUID
    public let device: String
    public let remoteAddress: String
}

public enum ServerError: Error, CustomStringConvertible {
    case identityRejected
    case listenerFailed(String)
    case startTimedOut

    public var description: String {
        switch self {
        case .identityRejected: return "the TLS identity was rejected by the TLS stack"
        case let .listenerFailed(reason): return "listener failed: \(reason)"
        case .startTimedOut: return "listener did not become ready in time"
        }
    }
}

/// The WSS server: NWListener + TLS + NWProtocolWebSocket, one `Session` per
/// connection. Everything mutable is confined to `queue`.
public final class RemoteServer {
    public let agent: AgentInfo
    public let identity: TLSIdentity

    private let config: ServerConfig
    private let store: StateStore
    private let injector: InputInjector
    private let clock: () -> TimeInterval
    private let queue = DispatchQueue(label: "dev.myremote.agent.server")
    private let queueKey = DispatchSpecificKey<Bool>()

    // Confined to `queue`.
    private var listener: NWListener?
    private var connections: [UUID: ClientConnection] = [:]
    private var token: String
    private var state: RemoteState
    private var boundPort: UInt16 = 0
    private var stopped = false
    private var lastReportedClients: [ConnectedClient] = []
    private var clientsObserver: (([ConnectedClient]) -> Void)?

    public static func monotonicNow() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    public init(
        config: ServerConfig,
        store: StateStore,
        identity: TLSIdentity,
        agent: AgentInfo,
        token: String,
        injector: InputInjector,
        initialState: RemoteState,
        clock: @escaping () -> TimeInterval = RemoteServer.monotonicNow
    ) {
        self.config = config
        self.store = store
        self.identity = identity
        self.agent = agent
        self.token = token
        self.injector = injector
        self.state = initialState
        self.clock = clock
        queue.setSpecific(key: queueKey, value: true)
    }

    private func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    // MARK: Public API (callable from any thread)

    /// The port the listener is bound to; 0 before `start`.
    public var port: UInt16 { onQueue { boundPort } }

    public var currentToken: String { onQueue { token } }

    public var currentState: RemoteState { onQueue { state } }

    /// Authenticated clients.
    public var clients: [ConnectedClient] { onQueue { authenticatedClients() } }

    /// Called on an internal queue whenever the set of authenticated clients changes.
    public func observeClients(_ observer: @escaping ([ConnectedClient]) -> Void) {
        onQueue { clientsObserver = observer }
    }

    /// Starts listening and blocks until the listener is ready. Returns the bound port.
    @discardableResult
    public func start(timeout: TimeInterval = 10) throws -> UInt16 {
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<UInt16, Error> = .failure(ServerError.startTimedOut)
        queue.async {
            self.startListener(port: self.config.preferredPort, allowFallback: true) { result in
                outcome = result
                done.signal()
            }
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            stop()
            throw ServerError.startTimedOut
        }
        return try queue.sync { try outcome.get() }
    }

    /// Stops listening and drops every connection.
    public func stop() {
        onQueue {
            stopped = true
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            for connection in Array(connections.values) {
                close(connection, code: WSCloseCode.goingAway)
            }
        }
    }

    /// Replaces the agent state and pushes `state` to authenticated clients if it changed.
    public func updateState(_ newState: RemoteState) {
        onQueue {
            guard newState != state else { return }
            state = newState
            for connection in Array(connections.values) {
                guard let session = connection.session else { continue }
                apply(session.stateDidChange(newState), to: connection)
            }
        }
    }

    /// "Reset pairing": a new token is generated and persisted, the certificate and
    /// agent id stay, and every active connection is dropped.
    @discardableResult
    public func resetPairing() throws -> String {
        try onQueue {
            let newToken = try store.resetToken()
            token = newToken
            for connection in Array(connections.values) {
                if let session = connection.session {
                    apply(session.revoke(), to: connection)
                } else {
                    drop(connection)
                }
            }
            return newToken
        }
    }

    // MARK: Listener

    private func makeParameters() throws -> NWParameters {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity.identity) else {
            throw ServerError.identityRejected
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        // WebSocket runs over HTTP/1.1; say so when the client offers ALPN.
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15

        let parameters = NWParameters(tls: tls, tcp: tcp)
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = config.maximumMessageSize
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        return parameters
    }

    private func startListener(
        port: UInt16, allowFallback: Bool, completion: @escaping (Result<UInt16, Error>) -> Void
    ) {
        let newListener: NWListener
        do {
            let parameters = try makeParameters()
            let endpointPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
            newListener = try NWListener(using: parameters, on: endpointPort)
        } catch {
            if allowFallback, port != 0 {
                Log.info("port \(port) is unavailable (\(error)); using any free port")
                startListener(port: 0, allowFallback: false, completion: completion)
            } else {
                completion(.failure(ServerError.listenerFailed("\(error)")))
            }
            return
        }

        if config.advertise {
            var txt = NWTXTRecord()
            txt["v"] = String(myRemoteProtocolVersion)
            txt["id"] = agent.id
            newListener.service = NWListener.Service(
                name: config.serviceName, type: ServerConfig.bonjourType,
                domain: ServerConfig.bonjourDomain, txtRecord: txt)
            newListener.serviceRegistrationUpdateHandler = { change in
                switch change {
                case let .add(endpoint): Log.info("Bonjour registered: \(endpoint)")
                case let .remove(endpoint): Log.info("Bonjour removed: \(endpoint)")
                @unknown default: break
                }
            }
        }

        var settled = false
        newListener.stateUpdateHandler = { [weak self, weak newListener] listenerState in
            guard let self, let newListener else { return }
            switch listenerState {
            case .ready:
                guard !settled else { return }
                settled = true
                self.boundPort = newListener.port?.rawValue ?? 0
                completion(.success(self.boundPort))
            case let .failed(error):
                newListener.cancel()
                if self.listener === newListener { self.listener = nil }
                guard !settled else {
                    // It was serving and died (for example across a network change).
                    // Come back on the same port so paired phones find it again.
                    Log.error("listener failed: \(error); restarting")
                    self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, !self.stopped, self.listener == nil else { return }
                        self.startListener(port: self.boundPort, allowFallback: true) { result in
                            if case let .failure(restartError) = result {
                                Log.error("listener could not be restarted: \(restartError)")
                            }
                        }
                    }
                    return
                }
                settled = true
                if allowFallback, port != 0 {
                    Log.info("port \(port) is unavailable (\(error)); using any free port")
                    self.startListener(port: 0, allowFallback: false, completion: completion)
                } else {
                    completion(.failure(ServerError.listenerFailed("\(error)")))
                }
            case let .waiting(error):
                Log.info("listener waiting: \(error)")
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener = newListener
        newListener.start(queue: queue)
    }

    // MARK: Connections

    private final class ClientConnection {
        let id = UUID()
        let transport: NWConnection
        var session: Session?
        var timer: DispatchSourceTimer?
        /// Monotonic time the session-deadline timer is armed for, if it is armed.
        var armedDeadline: TimeInterval?
        var closing = false

        init(transport: NWConnection) {
            self.transport = transport
        }

        var remoteAddress: String {
            switch transport.endpoint {
            case let .hostPort(host, port): return "\(host):\(port)"
            default: return "\(transport.endpoint)"
            }
        }
    }

    private func accept(_ transport: NWConnection) {
        guard connections.count < config.maximumConnections else {
            transport.cancel()
            return
        }
        let connection = ClientConnection(transport: transport)
        connections[connection.id] = connection

        // Until the WebSocket is open there is no session; bound the handshake.
        schedule(connection, after: config.handshakeTimeout) { [weak self, weak connection] in
            guard let self, let connection, connection.session == nil else { return }
            self.drop(connection)
        }

        transport.stateUpdateHandler = { [weak self, weak connection] transportState in
            guard let self, let connection else { return }
            switch transportState {
            case .ready:
                self.opened(connection)
            case .failed, .cancelled:
                self.remove(connection)
            default:
                break
            }
        }
        transport.start(queue: queue)
    }

    /// TLS and the WebSocket upgrade are done: the 5 s hello clock starts now.
    private func opened(_ connection: ClientConnection) {
        guard connection.session == nil, !connection.closing else { return }
        let environment = SessionEnvironment(
            agent: agent,
            verifyToken: { [weak self] presented in
                guard let self else { return false }
                return PairingToken.constantTimeEquals(presented, self.token)
            },
            currentState: { [weak self] in
                self?.state ?? RemoteState(frontApp: nil, profile: .generic, accessibility: false)
            },
            injector: injector)
        connection.session = Session(config: config.session, environment: environment, now: clock())
        rescheduleDeadline(connection)
        receive(on: connection)
    }

    private func receive(on connection: ClientConnection) {
        connection.transport.receiveMessage { [weak self, weak connection] content, context, _, error in
            guard let self, let connection else { return }
            if error != nil {
                self.drop(connection)
                return
            }
            guard let context,
                  let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
            else {
                // End of stream without a close frame.
                self.drop(connection)
                return
            }

            switch metadata.opcode {
            case .text:
                self.handleText(content ?? Data(), on: connection)
            case .binary:
                // Binary frames are ignored (PROTOCOL.md section 1).
                if let session = connection.session {
                    self.apply(session.receiveBinary(), to: connection)
                }
            case .close:
                self.peerClosed(connection)
                return
            default:
                break
            }
            self.receive(on: connection)
        }
    }

    private func handleText(_ data: Data, on connection: ClientConnection) {
        guard let session = connection.session, !connection.closing else { return }
        let wasAuthenticated = session.isAuthenticated
        apply(session.receiveText(data, now: clock()), to: connection)
        if session.isAuthenticated != wasAuthenticated {
            clientsChanged()
        }
        rescheduleDeadline(connection)
    }

    private func apply(_ effects: [SessionEffect], to connection: ClientConnection) {
        for effect in effects {
            switch effect {
            case let .send(message):
                send(message, on: connection)
            case let .close(code):
                close(connection, code: code)
            }
        }
    }

    private func send(_ message: ServerMessage, on connection: ClientConnection) {
        guard !connection.closing else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.transport.send(
            content: WireJSON.encode(message), contentContext: context, isComplete: true,
            completion: .contentProcessed { [weak self, weak connection] error in
                guard error != nil, let self, let connection else { return }
                self.drop(connection)
            })
    }

    /// Sends a close frame with `code`, then drops the transport once the peer has
    /// answered or the grace period is over.
    private func close(_ connection: ClientConnection, code: UInt16) {
        guard !connection.closing else { return }
        connection.closing = true
        connection.session?.transportClosed()
        clientsChanged()

        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = Self.closeCode(code)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.transport.send(
            content: nil, contentContext: context, isComplete: true,
            completion: .contentProcessed { _ in })
        schedule(connection, after: config.closeGrace) { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.drop(connection)
        }
    }

    /// The peer sent a close frame: echo one (unless ours is already on its way)
    /// and tear the transport down.
    private func peerClosed(_ connection: ClientConnection) {
        guard !connection.closing else {
            drop(connection)
            return
        }
        connection.closing = true
        connection.session?.transportClosed()
        clientsChanged()
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.transport.send(
            content: nil, contentContext: context, isComplete: true,
            completion: .contentProcessed { [weak self, weak connection] _ in
                guard let self, let connection else { return }
                self.drop(connection)
            })
    }

    static func closeCode(_ code: UInt16) -> NWProtocolWebSocket.CloseCode {
        switch code {
        case 1000: return .protocolCode(.normalClosure)
        case 1001: return .protocolCode(.goingAway)
        case 3000...3999: return .applicationCode(code)
        case 4000...4999: return .privateCode(code)
        default: return .protocolCode(.normalClosure)
        }
    }

    /// Tears the transport down immediately.
    private func drop(_ connection: ClientConnection) {
        connection.closing = true
        connection.transport.cancel()
        remove(connection)
    }

    private func remove(_ connection: ClientConnection) {
        connection.timer?.cancel()
        connection.timer = nil
        guard connections.removeValue(forKey: connection.id) != nil else { return }
        connection.session?.transportClosed()
        clientsChanged()
    }

    // MARK: Timers

    private func schedule(_ connection: ClientConnection, after delay: TimeInterval, _ body: @escaping () -> Void) {
        connection.timer?.cancel()
        connection.armedDeadline = nil
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, delay))
        timer.setEventHandler(handler: body)
        connection.timer = timer
        timer.resume()
    }

    /// Arms the connection's timer for the session's next deadline (hello or idle).
    ///
    /// Every client message pushes the idle deadline further out. Instead of
    /// re-creating the timer for each of them (pointer events arrive by the
    /// hundred), a timer that is already armed for an earlier moment is left
    /// alone: when it fires, `tick` finds nothing to do and it is re-armed here.
    private func rescheduleDeadline(_ connection: ClientConnection) {
        guard !connection.closing, let session = connection.session, let deadline = session.deadline else { return }
        if let armed = connection.armedDeadline, armed <= deadline { return }
        schedule(connection, after: deadline - clock()) { [weak self, weak connection] in
            guard let self, let connection, let session = connection.session else { return }
            connection.armedDeadline = nil
            let wasAuthenticated = session.isAuthenticated
            self.apply(session.tick(now: self.clock()), to: connection)
            if session.isAuthenticated != wasAuthenticated { self.clientsChanged() }
            self.rescheduleDeadline(connection)
        }
        connection.armedDeadline = deadline
    }

    // MARK: Client bookkeeping

    private func authenticatedClients() -> [ConnectedClient] {
        connections.values
            .compactMap { connection -> ConnectedClient? in
                guard let device = connection.session?.device else { return nil }
                return ConnectedClient(id: connection.id, device: device, remoteAddress: connection.remoteAddress)
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private func clientsChanged() {
        let current = authenticatedClients()
        guard current != lastReportedClients else { return }
        lastReportedClients = current
        clientsObserver?(current)
    }
}
