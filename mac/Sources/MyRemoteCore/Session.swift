import Foundation

public struct SessionConfig: Equatable, Sendable {
    /// `hello` must arrive within this many seconds of the WebSocket opening.
    public var helloTimeout: TimeInterval
    /// An authenticated connection with no client message for this long is closed.
    public var idleTimeout: TimeInterval
    /// Upper bound for one `text` message, in UTF-16 code units (not in the contract;
    /// longer texts are answered with `bad_request` instead of typing for seconds).
    public var maxTextLength: Int

    public init(helloTimeout: TimeInterval = 5, idleTimeout: TimeInterval = 30, maxTextLength: Int = 10_000) {
        self.helloTimeout = helloTimeout
        self.idleTimeout = idleTimeout
        self.maxTextLength = maxTextLength
    }
}

public enum WSCloseCode {
    /// Invalid token / first message not `hello` / hello timeout.
    public static let unauthorized: UInt16 = 4401
    /// `hello.v` not supported.
    public static let unsupportedVersion: UInt16 = 4400
    /// Idle timeout and agent shutdown (the contract names no code for these).
    public static let goingAway: UInt16 = 1001
}

/// What the session needs from its host. Closures instead of values so that a token
/// reset or a profile change is seen by sessions that are already open.
public struct SessionEnvironment {
    public var agent: AgentInfo
    public var verifyToken: (String) -> Bool
    public var currentState: () -> RemoteState
    public var injector: InputInjector

    public init(
        agent: AgentInfo,
        verifyToken: @escaping (String) -> Bool,
        currentState: @escaping () -> RemoteState,
        injector: InputInjector
    ) {
        self.agent = agent
        self.verifyToken = verifyToken
        self.currentState = currentState
        self.injector = injector
    }
}

public enum SessionEffect: Equatable, Sendable {
    /// Send one text frame.
    case send(ServerMessage)
    /// Close the WebSocket with this close code. Always the last effect.
    case close(code: UInt16)
}

/// The per-connection protocol state machine (PROTOCOL.md section 4).
///
/// It is deliberately free of I/O and of real time: the host feeds it frames and
/// the current monotonic time and executes the returned effects. Not thread-safe;
/// the host confines each session to one queue.
public final class Session {
    public enum Phase: Equatable, Sendable {
        case awaitingHello
        case authenticated(device: String)
        case closed
    }

    public private(set) var phase: Phase = .awaitingHello

    private let config: SessionConfig
    private let environment: SessionEnvironment
    private let openedAt: TimeInterval
    private var lastMessageAt: TimeInterval

    /// - Parameter now: monotonic seconds at the moment the WebSocket opened.
    public init(config: SessionConfig = SessionConfig(), environment: SessionEnvironment, now: TimeInterval) {
        self.config = config
        self.environment = environment
        self.openedAt = now
        self.lastMessageAt = now
    }

    public var isAuthenticated: Bool {
        if case .authenticated = phase { return true }
        return false
    }

    /// The device name from `hello`, once authenticated.
    public var device: String? {
        if case let .authenticated(device) = phase { return device }
        return nil
    }

    /// Monotonic time at which `tick` will have something to do, or nil when closed.
    public var deadline: TimeInterval? {
        switch phase {
        case .awaitingHello: return openedAt + config.helloTimeout
        case .authenticated: return lastMessageAt + config.idleTimeout
        case .closed: return nil
        }
    }

    // MARK: Inputs

    /// A text frame arrived.
    public func receiveText(_ data: Data, now: TimeInterval) -> [SessionEffect] {
        switch phase {
        case .closed:
            return []
        case .awaitingHello:
            // A hello that shows up after the deadline is still too late.
            let expired = tick(now: now)
            if !expired.isEmpty { return expired }
            return handleHandshake(data, now: now)
        case .authenticated:
            lastMessageAt = now
            return handleAuthenticated(data)
        }
    }

    /// A binary frame arrived. The server ignores binary frames entirely: they do
    /// not count as the first message and do not reset the idle timer.
    public func receiveBinary() -> [SessionEffect] {
        []
    }

    /// Time passed. Call at (or after) `deadline`.
    public func tick(now: TimeInterval) -> [SessionEffect] {
        switch phase {
        case .awaitingHello:
            guard now - openedAt >= config.helloTimeout else { return [] }
            return reject(.unauthorized, "hello not received in time", WSCloseCode.unauthorized)
        case .authenticated:
            guard now - lastMessageAt >= config.idleTimeout else { return [] }
            phase = .closed
            return [.close(code: WSCloseCode.goingAway)]
        case .closed:
            return []
        }
    }

    /// The agent state changed; authenticated clients get a `state` push.
    public func stateDidChange(_ state: RemoteState) -> [SessionEffect] {
        guard isAuthenticated else { return [] }
        return [.send(.state(state))]
    }

    /// Pairing was reset: the token this client holds is no longer valid.
    public func revoke() -> [SessionEffect] {
        guard phase != .closed else { return [] }
        return reject(.unauthorized, "pairing was reset", WSCloseCode.unauthorized)
    }

    /// The transport went away (peer closed, network error).
    public func transportClosed() {
        phase = .closed
    }

    // MARK: Handshake

    private func handleHandshake(_ data: Data, now: TimeInterval) -> [SessionEffect] {
        switch ClientMessage.parse(data) {
        case let .message(.hello(v, token, device)):
            guard v == myRemoteProtocolVersion else {
                return rejectVersion(v)
            }
            guard environment.verifyToken(token) else {
                return reject(.unauthorized, "invalid token", WSCloseCode.unauthorized)
            }
            phase = .authenticated(device: device ?? "")
            lastMessageAt = now
            return [.send(.welcome(
                v: myRemoteProtocolVersion, agent: environment.agent, state: environment.currentState()))]

        case .invalid(kind: .hello, _):
            // A hello from a future protocol version may not decode at all;
            // it still deserves `unsupported_version` rather than `unauthorized`.
            if let v = ClientMessage.probeVersion(data), v != myRemoteProtocolVersion {
                return rejectVersion(v)
            }
            return reject(.unauthorized, "malformed hello", WSCloseCode.unauthorized)

        default:
            return reject(.unauthorized, "hello required", WSCloseCode.unauthorized)
        }
    }

    private func rejectVersion(_ v: Int) -> [SessionEffect] {
        reject(
            .unsupportedVersion,
            "protocol version \(v) is not supported (supported: \(myRemoteProtocolVersion))",
            WSCloseCode.unsupportedVersion)
    }

    private func reject(_ code: ErrorCode, _ message: String, _ closeCode: UInt16) -> [SessionEffect] {
        phase = .closed
        return [.send(.error(code: code, message: message)), .close(code: closeCode)]
    }

    // MARK: Authenticated traffic

    private func handleAuthenticated(_ data: Data) -> [SessionEffect] {
        switch ClientMessage.parse(data) {
        case .malformed:
            return protocolError("malformed message")

        case let .unknownType(type):
            return protocolError("unknown message type \"\(type.prefix(40))\"")

        case let .invalid(kind, id):
            switch kind {
            case .cmd, .key, .text:
                // Ackable message with bad fields: the contract's ack `bad_request`.
                if let id { return [.send(.ackFailed(id, .badRequest))] }
                return protocolError("invalid \(kind.rawValue) message")
            case .hello, .pointer, .click, .scroll, .ping:
                return protocolError("invalid \(kind.rawValue) message")
            }

        case let .message(message):
            return handle(message)
        }
    }

    private func handle(_ message: ClientMessage) -> [SessionEffect] {
        switch message {
        case .hello:
            return protocolError("already authenticated")

        case let .cmd(action, id):
            guard let cmd = CmdAction(rawValue: action) else {
                return ack(id, failure: .badRequest)
            }
            let profile = environment.currentState().profile
            guard let input = ProfileMap.action(for: cmd, profile: profile) else {
                return ack(id, failure: .unsupported)
            }
            return ack(id, result: environment.injector.perform(input))

        case let .key(key, id):
            guard let remoteKey = RemoteKey(rawValue: key) else {
                return ack(id, failure: .badRequest)
            }
            return ack(id, result: environment.injector.perform(.key(remoteKey.virtualKey)))

        case let .text(text, id):
            guard text.utf16.count <= config.maxTextLength else {
                return ack(id, failure: .badRequest)
            }
            guard !text.isEmpty else {
                return ack(id, result: .ok)
            }
            return ack(id, result: environment.injector.perform(.text(text)))

        case let .pointer(dx, dy):
            guard dx.isFinite, dy.isFinite else { return protocolError("invalid pointer message") }
            // Never acknowledged, not even on failure; `state.accessibility` tells the client.
            _ = environment.injector.perform(.pointer(dx: dx, dy: dy))
            return []

        case let .click(button, count):
            _ = environment.injector.perform(.click(button: button, count: count))
            return []

        case let .scroll(dx, dy):
            guard dx.isFinite, dy.isFinite else { return protocolError("invalid scroll message") }
            _ = environment.injector.perform(.scroll(dx: dx, dy: dy))
            return []

        case let .ping(t):
            return [.send(.pong(t: t))]
        }
    }

    /// `error bad_request`; the connection stays open.
    private func protocolError(_ message: String) -> [SessionEffect] {
        [.send(.error(code: .badRequest, message: message))]
    }

    /// An ack is sent if and only if the message carried an `id`.
    private func ack(_ id: Int?, failure: AckError) -> [SessionEffect] {
        guard let id else { return [] }
        return [.send(.ackFailed(id, failure))]
    }

    private func ack(_ id: Int?, result: InjectionResult) -> [SessionEffect] {
        guard let id else { return [] }
        switch result {
        case .ok: return [.send(.ackOK(id))]
        case .accessibilityDenied: return [.send(.ackFailed(id, .accessibilityDenied))]
        }
    }
}
