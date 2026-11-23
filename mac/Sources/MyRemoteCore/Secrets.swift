import CryptoKit
import Foundation

public enum Base64URL {
    /// base64url without padding (RFC 4648 section 5).
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict: only the base64url alphabet, no padding, canonical length.
    public static func decode(_ string: String) -> Data? {
        guard string.utf8.allSatisfy({ byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F
        }) else { return nil }
        guard string.utf8.count % 4 != 1 else { return nil }
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.utf8.count % 4) % 4)
        return Data(base64Encoded: s)
    }
}

/// The pairing secret: 32 random bytes as base64url without padding (43 characters).
public enum PairingToken {
    public static let byteCount = 32
    public static let encodedLength = 43

    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    public static func generate<G: RandomNumberGenerator>(using generator: inout G) -> String {
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Base64URL.encode(Data(bytes))
    }

    public static func isWellFormed(_ token: String) -> Bool {
        token.utf8.count == encodedLength && Base64URL.decode(token)?.count == byteCount
    }

    /// Constant-time comparison of a presented token against the expected one.
    /// Both sides are hashed first so that neither the length nor the position of
    /// the first differing byte influences timing.
    public static func constantTimeEquals(_ presented: String, _ expected: String) -> Bool {
        let a = SHA256.hash(data: Data(presented.utf8))
        let b = SHA256.hash(data: Data(expected.utf8))
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) {
            difference |= x ^ y
        }
        return difference == 0
    }
}

/// Stable random agent identifier: 16 lowercase hex characters.
public enum AgentID {
    public static let length = 16

    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<length / 2)
            .map { _ in Hex.byte(UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    public static func isWellFormed(_ id: String) -> Bool {
        id.utf8.count == length && Hex.isLowercaseHex(id)
    }
}

public enum Hex {
    private static let digits = Array("0123456789abcdef")

    static func byte(_ value: UInt8) -> String {
        String([digits[Int(value >> 4)], digits[Int(value & 0x0F)]])
    }

    public static func encode<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map(byte).joined()
    }

    public static func isLowercaseHex(_ string: String) -> Bool {
        !string.isEmpty && string.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }
    }
}

public enum CertificateFingerprint {
    /// `fp` of the contract: SHA-256 over the DER encoding of the leaf certificate,
    /// 64 lowercase hex characters.
    public static func sha256Hex(ofDER der: Data) -> String {
        Hex.encode(SHA256.hash(data: der))
    }

    public static func isWellFormed(_ fp: String) -> Bool {
        fp.utf8.count == 64 && Hex.isLowercaseHex(fp)
    }
}
