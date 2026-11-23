import Foundation

/// The contents of a pairing URI (PROTOCOL.md section 3):
///
///     myremote://pair?v=1&host=<ipv4|hostname>&port=<port>&id=<agentId>&name=<pct>&fp=<64 hex>&token=<43 chars>
public struct PairingInfo: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var id: String
    public var name: String
    public var fp: String
    public var token: String

    public init(host: String, port: Int, id: String, name: String, fp: String, token: String) {
        self.host = host
        self.port = port
        self.id = id
        self.name = name
        self.fp = fp
        self.token = token
    }
}

public enum PairingError: Error, Equatable, Sendable, CustomStringConvertible {
    case notAPairingURI
    case wrongScheme
    case wrongAction
    case missingParameter(String)
    case unsupportedVersion(String)
    case invalidHost
    case invalidPort
    case invalidAgentId
    case invalidName
    case invalidFingerprint
    case invalidToken

    public var description: String {
        switch self {
        case .notAPairingURI: return "not a pairing URI"
        case .wrongScheme: return "wrong scheme (expected myremote://)"
        case .wrongAction: return "wrong action (expected myremote://pair)"
        case let .missingParameter(name): return "missing parameter \(name)"
        case let .unsupportedVersion(v): return "unsupported pairing version \(v) (this build supports 1)"
        case .invalidHost: return "host is empty or malformed"
        case .invalidPort: return "port is not in 1...65535"
        case .invalidAgentId: return "id is not 16 lowercase hex characters"
        case .invalidName: return "name is empty or not valid percent-encoded UTF-8"
        case .invalidFingerprint: return "fp is not 64 lowercase hex characters"
        case .invalidToken: return "token is not 32 bytes of unpadded base64url"
        }
    }
}

public enum PairingURI {
    public static let scheme = "myremote"
    public static let action = "pair"

    /// RFC 3986 "unreserved" only. Everything else is percent-encoded, so a space is
    /// always `%20` and never `+` (which some query parsers turn into a space).
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Validates the fields and renders the URI with parameters in the contract's order.
    public static func build(_ info: PairingInfo) throws -> String {
        try validate(info)
        let query: [(String, String)] = [
            ("v", String(myRemoteProtocolVersion)),
            ("host", info.host),
            ("port", String(info.port)),
            ("id", info.id),
            ("name", info.name),
            ("fp", info.fp),
            ("token", info.token),
        ]
        let rendered = query.map { "\($0.0)=\(percentEncode($0.1))" }.joined(separator: "&")
        return "\(scheme)://\(action)?\(rendered)"
    }

    /// Parses and validates. Parameter order is free, unknown parameters are ignored,
    /// and every contract parameter is required.
    public static func parse(_ uri: String) throws -> PairingInfo {
        guard let schemeEnd = uri.range(of: "://") else { throw PairingError.notAPairingURI }
        let uriScheme = uri[uri.startIndex..<schemeEnd.lowerBound]
        guard !uriScheme.isEmpty, uriScheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { throw PairingError.notAPairingURI }
        guard uriScheme.lowercased() == scheme else { throw PairingError.wrongScheme }

        var rest = uri[schemeEnd.upperBound...]
        if let fragment = rest.firstIndex(of: "#") {
            rest = rest[rest.startIndex..<fragment]
        }
        let authority: Substring
        let query: Substring
        if let mark = rest.firstIndex(of: "?") {
            authority = rest[rest.startIndex..<mark]
            query = rest[rest.index(after: mark)...]
        } else {
            authority = rest
            query = ""
        }
        var target = authority
        if target.hasSuffix("/") { target = target.dropLast() }
        guard target.lowercased() == action else { throw PairingError.wrongAction }

        var parameters: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let rawName: Substring
            let rawValue: Substring
            if let equals = pair.firstIndex(of: "=") {
                rawName = pair[pair.startIndex..<equals]
                rawValue = pair[pair.index(after: equals)...]
            } else {
                rawName = pair
                rawValue = ""
            }
            guard let name = String(rawName).removingPercentEncoding else { continue }
            // First occurrence wins; an undecodable value is kept as "invalid".
            if parameters[name] == nil {
                parameters[name] = String(rawValue).removingPercentEncoding ?? "\u{FFFD}"
            }
        }

        func required(_ name: String) throws -> String {
            guard let value = parameters[name] else { throw PairingError.missingParameter(name) }
            return value
        }

        let version = try required("v")
        guard version == String(myRemoteProtocolVersion) else {
            throw PairingError.unsupportedVersion(version)
        }
        let host = try required("host")
        let portText = try required("port")
        let id = try required("id")
        let name = try required("name")
        let fp = try required("fp")
        let token = try required("token")

        guard portText.utf8.count <= 5, portText.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let port = Int(portText)
        else { throw PairingError.invalidPort }

        let info = PairingInfo(host: host, port: port, id: id, name: name, fp: fp, token: token)
        try validate(info)
        return info
    }

    public static func validate(_ info: PairingInfo) throws {
        guard !info.host.isEmpty,
              !info.host.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }),
              !info.host.contains("/"), !info.host.contains("?"), !info.host.contains("#"),
              !info.host.unicodeScalars.contains("\u{FFFD}")
        else { throw PairingError.invalidHost }
        guard (1...65535).contains(info.port) else { throw PairingError.invalidPort }
        guard AgentID.isWellFormed(info.id) else { throw PairingError.invalidAgentId }
        guard !info.name.isEmpty, !info.name.unicodeScalars.contains("\u{FFFD}") else {
            throw PairingError.invalidName
        }
        guard CertificateFingerprint.isWellFormed(info.fp) else { throw PairingError.invalidFingerprint }
        guard PairingToken.isWellFormed(info.token) else { throw PairingError.invalidToken }
    }
}
