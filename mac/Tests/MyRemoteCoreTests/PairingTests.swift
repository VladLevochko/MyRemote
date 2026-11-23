import Foundation
import MyRemoteCore
import XCTest

final class PairingTests: XCTestCase {
    private let fp = String(repeating: "ab", count: 32)

    private func info(name: String = "MacBook Pro", host: String = "192.168.1.42", port: Int = 47110) -> PairingInfo {
        PairingInfo(host: host, port: port, id: "0123456789abcdef", name: name, fp: fp, token: PairingToken.generate())
    }

    func testRoundTrip() throws {
        let original = info()
        let uri = try PairingURI.build(original)
        XCTAssertTrue(uri.hasPrefix("myremote://pair?v=1&host=192.168.1.42&port=47110&id=0123456789abcdef&name=MacBook%20Pro&fp="))
        XCTAssertEqual(try PairingURI.parse(uri), original)
    }

    func testRoundTripWithAwkwardNames() throws {
        let names = [
            "admin’s MacBook Pro", "Мій Mac", "a&b=c", "100% + more", "tab\there", "#hash?query/slash",
            "emoji 🎬🍿", "日本語", "plus+plus", "percent%20literal", " leading and trailing ",
        ]
        for name in names {
            let original = info(name: name)
            let uri = try PairingURI.build(original)
            // Only unreserved characters and the query syntax may appear literally.
            XCTAssertNil(
                uri.range(of: #"[^A-Za-z0-9\-._~%:/?&=]"#, options: .regularExpression),
                "unescaped character in \(uri)")
            XCTAssertFalse(uri.contains("+"), "a literal + would be read as a space by some parsers: \(uri)")
            XCTAssertEqual(try PairingURI.parse(uri), original, name)
        }
    }

    func testHostnameHost() throws {
        let original = info(host: "macbook.local", port: 50123)
        XCTAssertEqual(try PairingURI.parse(try PairingURI.build(original)), original)
    }

    func testParameterOrderDoesNotMatterAndUnknownParametersAreIgnored() throws {
        let original = info()
        let uri = try PairingURI.build(original)
        let query = uri.split(separator: "?", maxSplits: 1)[1].split(separator: "&")
        let shuffled = "myremote://pair?extra=1&" + query.reversed().joined(separator: "&") + "&another=x%20y"
        XCTAssertEqual(try PairingURI.parse(shuffled), original)
    }

    func testEveryParameterIsRequired() throws {
        let uri = try PairingURI.build(info())
        let query = uri.split(separator: "?", maxSplits: 1)[1].split(separator: "&").map(String.init)
        for (index, parameter) in query.enumerated() {
            var remaining = query
            remaining.remove(at: index)
            let name = String(parameter.split(separator: "=")[0])
            XCTAssertThrowsError(try PairingURI.parse("myremote://pair?" + remaining.joined(separator: "&"))) { error in
                XCTAssertEqual(error as? PairingError, .missingParameter(name))
            }
        }
    }

    func testBuildRefusesInvalidFields() {
        var bad = info()
        bad.port = 0
        XCTAssertThrowsError(try PairingURI.build(bad))
        bad = info()
        bad.port = 65536
        XCTAssertThrowsError(try PairingURI.build(bad))
        bad = info()
        bad.fp = fp.uppercased()
        XCTAssertThrowsError(try PairingURI.build(bad))
        bad = info()
        bad.id = "0123"
        XCTAssertThrowsError(try PairingURI.build(bad))
        bad = info()
        bad.token = "short"
        XCTAssertThrowsError(try PairingURI.build(bad))
        bad = info()
        bad.host = ""
        XCTAssertThrowsError(try PairingURI.build(bad))
        bad = info()
        bad.name = ""
        XCTAssertThrowsError(try PairingURI.build(bad))
    }

    func testPortBoundaries() throws {
        XCTAssertEqual(try PairingURI.parse(try PairingURI.build(info(port: 1))).port, 1)
        XCTAssertEqual(try PairingURI.parse(try PairingURI.build(info(port: 65535))).port, 65535)
        let uri = try PairingURI.build(info())
        for bad in ["0", "65536", "-1", "47110.0", "0x1F", "", " 47110"] {
            let broken = uri.replacingOccurrences(of: "port=47110", with: "port=\(bad)")
            XCTAssertThrowsError(try PairingURI.parse(broken), "port=\(bad)") { error in
                XCTAssertEqual(error as? PairingError, .invalidPort)
            }
        }
    }

    // MARK: Tokens and ids

    func testGeneratedTokenShape() throws {
        var seen = Set<String>()
        for _ in 0..<200 {
            let token = PairingToken.generate()
            XCTAssertEqual(token.count, 43)
            XCTAssertNil(token.range(of: "[^A-Za-z0-9_-]", options: .regularExpression), token)
            XCTAssertEqual(Base64URL.decode(token)?.count, 32)
            XCTAssertTrue(PairingToken.isWellFormed(token))
            seen.insert(token)
        }
        XCTAssertEqual(seen.count, 200, "tokens must not repeat")
    }

    func testTokenWellFormedness() {
        XCTAssertTrue(PairingToken.isWellFormed("q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA"))
        XCTAssertFalse(PairingToken.isWellFormed("short"))
        XCTAssertFalse(PairingToken.isWellFormed("q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA="))  // padded
        XCTAssertFalse(PairingToken.isWellFormed("q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJ+"))  // not url-safe
        XCTAssertFalse(PairingToken.isWellFormed("q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJAA")) // 33 bytes
        XCTAssertFalse(PairingToken.isWellFormed(""))
    }

    func testBase64URLRoundTrip() {
        for length in 0..<70 {
            let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 251) })
            let encoded = Base64URL.encode(data)
            XCTAssertFalse(encoded.contains("="))
            XCTAssertFalse(encoded.contains("+"))
            XCTAssertFalse(encoded.contains("/"))
            XCTAssertEqual(Base64URL.decode(encoded), data)
        }
        XCTAssertNil(Base64URL.decode("a"))
        XCTAssertNil(Base64URL.decode("ab=="))
        XCTAssertNil(Base64URL.decode("a b"))
    }

    func testConstantTimeEquals() {
        let token = PairingToken.generate()
        XCTAssertTrue(PairingToken.constantTimeEquals(token, token))
        XCTAssertTrue(PairingToken.constantTimeEquals(String(token), String(Array(token))))
        XCTAssertFalse(PairingToken.constantTimeEquals(token, PairingToken.generate()))
        XCTAssertFalse(PairingToken.constantTimeEquals("", token))
        XCTAssertFalse(PairingToken.constantTimeEquals(String(token.dropLast()), token))
        XCTAssertFalse(PairingToken.constantTimeEquals(token + "A", token))
        XCTAssertFalse(PairingToken.constantTimeEquals(token.lowercased(), token.uppercased()))
        XCTAssertTrue(PairingToken.constantTimeEquals("", ""))
    }

    func testAgentIdShape() {
        var seen = Set<String>()
        for _ in 0..<100 {
            let id = AgentID.generate()
            XCTAssertEqual(id.count, 16)
            XCTAssertNil(id.range(of: "[^0-9a-f]", options: .regularExpression), id)
            XCTAssertTrue(AgentID.isWellFormed(id))
            seen.insert(id)
        }
        XCTAssertEqual(seen.count, 100)
        XCTAssertFalse(AgentID.isWellFormed("0123456789ABCDEF"))
        XCTAssertFalse(AgentID.isWellFormed("0123456789abcde"))
        XCTAssertFalse(AgentID.isWellFormed("0123456789abcdeg"))
    }

    func testFingerprintOfKnownBytes() {
        // SHA-256("abc"), the classic test vector.
        XCTAssertEqual(
            CertificateFingerprint.sha256Hex(ofDER: Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(CertificateFingerprint.isWellFormed(String(repeating: "0f", count: 32)))
        XCTAssertFalse(CertificateFingerprint.isWellFormed(String(repeating: "0F", count: 32)))
        XCTAssertFalse(CertificateFingerprint.isWellFormed("abc123"))
    }
}
