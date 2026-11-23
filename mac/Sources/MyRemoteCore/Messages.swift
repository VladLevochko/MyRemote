import Foundation

/// Protocol version implemented by this agent (docs/PROTOCOL.md).
public let myRemoteProtocolVersion = 1

// MARK: - Shared value types

public enum Profile: String, Codable, Sendable, CaseIterable {
    case youtube, netflix, appletv, generic
}

public struct FrontApp: Codable, Equatable, Sendable {
    public var bundleId: String
    public var name: String

    public init(bundleId: String, name: String) {
        self.bundleId = bundleId
        self.name = name
    }
}

/// Section 4.4 "State".
public struct RemoteState: Codable, Equatable, Sendable {
    public var frontApp: FrontApp?
    public var profile: Profile
    public var accessibility: Bool

    public init(frontApp: FrontApp?, profile: Profile, accessibility: Bool) {
        self.frontApp = frontApp
        self.profile = profile
        self.accessibility = accessibility
    }

    private enum CodingKeys: String, CodingKey { case frontApp, profile, accessibility }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frontApp = try c.decodeIfPresent(FrontApp.self, forKey: .frontApp)
        profile = try c.decode(Profile.self, forKey: .profile)
        accessibility = try c.decode(Bool.self, forKey: .accessibility)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // The contract always carries the key; an unknown front app is an explicit null.
        if let frontApp {
            try c.encode(frontApp, forKey: .frontApp)
        } else {
            try c.encodeNil(forKey: .frontApp)
        }
        try c.encode(profile, forKey: .profile)
        try c.encode(accessibility, forKey: .accessibility)
    }
}

public struct AgentInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum MouseButton: String, Codable, Sendable, CaseIterable {
    case left, right
}

public enum AckError: String, Codable, Sendable, CaseIterable {
    case accessibilityDenied = "accessibility_denied"
    case unsupported
    case badRequest = "bad_request"
}

public enum ErrorCode: String, Codable, Sendable, CaseIterable {
    case unauthorized
    case unsupportedVersion = "unsupported_version"
    case badRequest = "bad_request"
}

private enum WireKey: String, CodingKey {
    case type, v, token, device, action, id, key, dx, dy, button, count, text, t
    case agent, state, ok, error, code, message
}

// MARK: - Client -> server

/// Section 4.1 / 4.2. `cmd.action` and `key.key` stay raw strings here: an unknown
/// value is a well-formed message that the session answers with `ack bad_request`.
public enum ClientMessage: Equatable, Sendable, Codable {
    case hello(v: Int, token: String, device: String?)
    case cmd(action: String, id: Int?)
    case key(key: String, id: Int?)
    case pointer(dx: Double, dy: Double)
    case click(button: MouseButton, count: Int)
    case scroll(dx: Double, dy: Double)
    case text(text: String, id: Int?)
    case ping(t: Int)

    public enum Kind: String, Sendable, CaseIterable {
        case hello, cmd, key, pointer, click, scroll, text, ping
    }

    public var kind: Kind {
        switch self {
        case .hello: return .hello
        case .cmd: return .cmd
        case .key: return .key
        case .pointer: return .pointer
        case .click: return .click
        case .scroll: return .scroll
        case .text: return .text
        case .ping: return .ping
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        let type = try c.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: type) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown client message type \(type)")
        }
        switch kind {
        case .hello:
            self = .hello(
                v: try c.decode(Int.self, forKey: .v),
                token: try c.decode(String.self, forKey: .token),
                device: try c.decodeIfPresent(String.self, forKey: .device))
        case .cmd:
            self = .cmd(
                action: try c.decode(String.self, forKey: .action),
                id: try c.decodeIfPresent(Int.self, forKey: .id))
        case .key:
            self = .key(
                key: try c.decode(String.self, forKey: .key),
                id: try c.decodeIfPresent(Int.self, forKey: .id))
        case .pointer:
            self = .pointer(
                dx: try c.decode(Double.self, forKey: .dx),
                dy: try c.decode(Double.self, forKey: .dy))
        case .click:
            let count = try c.decode(Int.self, forKey: .count)
            guard count == 1 || count == 2 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .count, in: c, debugDescription: "count must be 1 or 2")
            }
            self = .click(button: try c.decode(MouseButton.self, forKey: .button), count: count)
        case .scroll:
            self = .scroll(
                dx: try c.decode(Double.self, forKey: .dx),
                dy: try c.decode(Double.self, forKey: .dy))
        case .text:
            self = .text(
                text: try c.decode(String.self, forKey: .text),
                id: try c.decodeIfPresent(Int.self, forKey: .id))
        case .ping:
            self = .ping(t: try c.decode(Int.self, forKey: .t))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        try c.encode(kind.rawValue, forKey: .type)
        switch self {
        case let .hello(v, token, device):
            try c.encode(v, forKey: .v)
            try c.encode(token, forKey: .token)
            try c.encodeIfPresent(device, forKey: .device)
        case let .cmd(action, id):
            try c.encode(action, forKey: .action)
            try c.encodeIfPresent(id, forKey: .id)
        case let .key(key, id):
            try c.encode(key, forKey: .key)
            try c.encodeIfPresent(id, forKey: .id)
        case let .pointer(dx, dy):
            try c.encode(dx, forKey: .dx)
            try c.encode(dy, forKey: .dy)
        case let .click(button, count):
            try c.encode(button, forKey: .button)
            try c.encode(count, forKey: .count)
        case let .scroll(dx, dy):
            try c.encode(dx, forKey: .dx)
            try c.encode(dy, forKey: .dy)
        case let .text(text, id):
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(id, forKey: .id)
        case let .ping(t):
            try c.encode(t, forKey: .t)
        }
    }
}

/// Graded outcome of parsing one text frame. The session needs more than
/// "decoded / failed": the contract distinguishes an unknown `type` from a known
/// type with bad fields, and the latter must still be acked when an `id` is readable.
public enum ClientParseResult: Equatable, Sendable {
    case message(ClientMessage)
    /// Valid JSON object with a string `type` this version does not know.
    case unknownType(String)
    /// Known `type`, but required fields are missing or have the wrong shape.
    /// `id` is the integer `id` of the frame if one could be read.
    case invalid(kind: ClientMessage.Kind, id: Int?)
    /// Not a JSON object, or no string `type`.
    case malformed
}

extension ClientMessage {
    private struct Envelope: Decodable { let type: String }
    private struct IdProbe: Decodable { let id: Int? }
    private struct VersionProbe: Decodable { let v: Int? }

    public static func parse(_ data: Data) -> ClientParseResult {
        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            return .malformed
        }
        guard let kind = Kind(rawValue: envelope.type) else {
            return .unknownType(envelope.type)
        }
        if let message = try? decoder.decode(ClientMessage.self, from: data) {
            return .message(message)
        }
        let id = (try? decoder.decode(IdProbe.self, from: data))?.id
        return .invalid(kind: kind, id: id)
    }

    /// Reads just the integer `v` of a frame, for answering `unsupported_version`
    /// to a future `hello` whose other fields this version cannot decode.
    public static func probeVersion(_ data: Data) -> Int? {
        (try? JSONDecoder().decode(VersionProbe.self, from: data))?.v
    }
}

// MARK: - Server -> client

/// Section 4.3.
public enum ServerMessage: Equatable, Sendable, Codable {
    case welcome(v: Int, agent: AgentInfo, state: RemoteState)
    case ack(id: Int, ok: Bool, error: AckError?)
    case state(RemoteState)
    case pong(t: Int)
    case error(code: ErrorCode, message: String)

    public enum Kind: String, Sendable, CaseIterable {
        case welcome, ack, state, pong, error
    }

    public var kind: Kind {
        switch self {
        case .welcome: return .welcome
        case .ack: return .ack
        case .state: return .state
        case .pong: return .pong
        case .error: return .error
        }
    }

    public static func ackOK(_ id: Int) -> ServerMessage { .ack(id: id, ok: true, error: nil) }
    public static func ackFailed(_ id: Int, _ error: AckError) -> ServerMessage {
        .ack(id: id, ok: false, error: error)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        let type = try c.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: type) else {
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown server message type \(type)")
        }
        switch kind {
        case .welcome:
            self = .welcome(
                v: try c.decode(Int.self, forKey: .v),
                agent: try c.decode(AgentInfo.self, forKey: .agent),
                state: try c.decode(RemoteState.self, forKey: .state))
        case .ack:
            self = .ack(
                id: try c.decode(Int.self, forKey: .id),
                ok: try c.decode(Bool.self, forKey: .ok),
                error: try c.decodeIfPresent(AckError.self, forKey: .error))
        case .state:
            self = .state(try c.decode(RemoteState.self, forKey: .state))
        case .pong:
            self = .pong(t: try c.decode(Int.self, forKey: .t))
        case .error:
            self = .error(
                code: try c.decode(ErrorCode.self, forKey: .code),
                message: try c.decode(String.self, forKey: .message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        try c.encode(kind.rawValue, forKey: .type)
        switch self {
        case let .welcome(v, agent, state):
            try c.encode(v, forKey: .v)
            try c.encode(agent, forKey: .agent)
            try c.encode(state, forKey: .state)
        case let .ack(id, ok, error):
            try c.encode(id, forKey: .id)
            try c.encode(ok, forKey: .ok)
            // `error` exists only when ok=false.
            if !ok, let error {
                try c.encode(error, forKey: .error)
            }
        case let .state(state):
            try c.encode(state, forKey: .state)
        case let .pong(t):
            try c.encode(t, forKey: .t)
        case let .error(code, message):
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
        }
    }
}

// MARK: - Wire encoding

public enum WireJSON {
    /// One JSON object, no newlines, stable key order.
    public static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            // Every model in this module encodes plain strings, numbers and bools.
            // Non-finite doubles are the only way to fail and are rejected earlier.
            preconditionFailure("unencodable wire value: \(error)")
        }
    }

    public static func string<T: Encodable>(_ value: T) -> String {
        String(decoding: encode(value), as: UTF8.self)
    }
}
