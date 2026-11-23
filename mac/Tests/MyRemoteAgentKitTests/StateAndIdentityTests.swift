import CryptoKit
import Foundation
@testable import MyRemoteAgentKit
import MyRemoteCore
import XCTest

final class StateStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestDirectories.make().appendingPathComponent("nested/state", isDirectory: true)
    }

    override func tearDown() {
        TestDirectories.remove(directory.deletingLastPathComponent().deletingLastPathComponent())
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }

    func testCreatesDirectoryPrivately() throws {
        let store = try StateStore(directory: directory)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try permissions(store.directory), 0o700)
    }

    func testAgentIdIsGeneratedOnceAndStable() throws {
        let id = try StateStore(directory: directory).loadOrCreateAgentId()
        XCTAssertTrue(AgentID.isWellFormed(id))
        XCTAssertEqual(try StateStore(directory: directory).loadOrCreateAgentId(), id)
        XCTAssertEqual(try permissions(directory.appendingPathComponent("agent-id")), 0o600)
    }

    func testTokenIsGeneratedOnceStableAndResettable() throws {
        let store = try StateStore(directory: directory)
        let token = try store.loadOrCreateToken()
        XCTAssertTrue(PairingToken.isWellFormed(token))
        XCTAssertEqual(try StateStore(directory: directory).loadOrCreateToken(), token)
        XCTAssertEqual(try permissions(directory.appendingPathComponent("token")), 0o600)

        let agentId = try store.loadOrCreateAgentId()
        let reset = try store.resetToken()
        XCTAssertNotEqual(reset, token)
        XCTAssertTrue(PairingToken.isWellFormed(reset))
        XCTAssertEqual(try StateStore(directory: directory).loadOrCreateToken(), reset)
        XCTAssertEqual(try permissions(directory.appendingPathComponent("token")), 0o600)
        XCTAssertEqual(try store.loadOrCreateAgentId(), agentId, "resetting the token must not touch the agent id")
    }

    func testCorruptValuesAreReplaced() throws {
        let store = try StateStore(directory: directory)
        try store.write(Data("not a token".utf8), to: StateStore.tokenFile)
        try store.write(Data("XYZ".utf8), to: StateStore.agentIdFile)
        XCTAssertTrue(PairingToken.isWellFormed(try store.loadOrCreateToken()))
        XCTAssertTrue(AgentID.isWellFormed(try store.loadOrCreateAgentId()))
    }

    func testTrailingNewlineInFilesIsTolerated() throws {
        let store = try StateStore(directory: directory)
        try store.write(Data("0123456789abcdef\n".utf8), to: StateStore.agentIdFile)
        XCTAssertEqual(try store.loadOrCreateAgentId(), "0123456789abcdef")
    }

    func testWritesAreAtomicAndLeaveNoTemporaryFiles() throws {
        let store = try StateStore(directory: directory)
        for round in 0..<5 {
            try store.write(Data("value \(round)".utf8), to: "thing")
        }
        XCTAssertEqual(store.read("thing"), Data("value 4".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["thing"])
        XCTAssertEqual(try permissions(directory.appendingPathComponent("thing")), 0o600)
    }
}

final class TLSIdentityTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestDirectories.make()
    }

    override func tearDown() {
        TestDirectories.remove(directory)
    }

    func testIdentityIsCreatedPersistedPrivatelyAndReloaded() throws {
        let store = try StateStore(directory: directory)
        let created = try TLSIdentityStore.loadOrCreate(in: store)
        XCTAssertTrue(CertificateFingerprint.isWellFormed(created.fingerprint))
        XCTAssertEqual(created.fingerprint, CertificateFingerprint.sha256Hex(ofDER: created.certificateDER))

        // Only the archive remains: no key.pem, cert.pem or scratch directory.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["identity.p12"])
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("identity.p12").path)
        XCTAssertEqual((attributes[.posixPermissions] as! NSNumber).intValue, 0o600)

        let reloaded = try TLSIdentityStore.loadOrCreate(in: try StateStore(directory: directory))
        XCTAssertEqual(reloaded.certificateDER, created.certificateDER)
        XCTAssertEqual(reloaded.fingerprint, created.fingerprint)
    }

    func testDifferentStateDirectoriesGetDifferentIdentities() throws {
        let other = try TestDirectories.make("other")
        defer { TestDirectories.remove(other) }
        let first = try TLSIdentityStore.loadOrCreate(in: try StateStore(directory: directory))
        let second = try TLSIdentityStore.loadOrCreate(in: try StateStore(directory: other))
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
    }

    /// Cross-check with a second implementation: openssl extracts the certificate
    /// from the archive, and its SHA-256 must be our `fp`.
    func testFingerprintAgreesWithOpenSSL() throws {
        let store = try StateStore(directory: directory)
        let identity = try TLSIdentityStore.loadOrCreate(in: store)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "pkcs12", "-in", store.url(for: StateStore.identityFile).path,
            "-passin", "pass:myremote", "-nokeys", "-clcerts",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let pem = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let begin = try XCTUnwrap(pem.range(of: "-----BEGIN CERTIFICATE-----"))
        let end = try XCTUnwrap(pem.range(of: "-----END CERTIFICATE-----"))
        let base64 = pem[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
        let der = try XCTUnwrap(Data(base64Encoded: String(base64)))
        XCTAssertEqual(der, identity.certificateDER)
        XCTAssertEqual(
            SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined(), identity.fingerprint)
    }

    func testCertificateProperties() throws {
        let identity = try TLSIdentityStore.loadOrCreate(in: try StateStore(directory: directory))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, identity.certificateDER as CFData))
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, "MyRemote Agent")
        // P-256 key.
        let key = try XCTUnwrap(SecCertificateCopyKey(certificate))
        let attributes = try XCTUnwrap(SecKeyCopyAttributes(key) as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrKeyType as String] as? String, kSecAttrKeyTypeECSECPrimeRandom as String)
        XCTAssertEqual(attributes[kSecAttrKeySizeInBits as String] as? Int, 256)
    }

    /// A throwaway archive (CN=probe, passphrase "myremote") made by LibreSSL 3.3.6
    /// whose P-256 private scalar starts with a zero byte and is therefore encoded
    /// in 31 bytes. Security.framework "imports" it successfully with zero items.
    private static let shortScalarArchive = Data(base64Encoded: """
        MIIDOAIBAzCCAv4GCSqGSIb3DQEHAaCCAu8EggLrMIIC5zCCAccGCSqGSIb3DQEHBqCCAbgwggG0AgEAMIIBrQYJKoZIhvcNAQcB
        MBwGCiqGSIb3DQEMAQYwDgQIVIwnvsDpWZYCAggAgIIBgFSMm7QFW29hjPU9BoYST6/aLjMVewVsQa6UdzrZXYGMQR73zAsa5gel
        YcAnjXGRlLK7JEKDbmLLrAHb56vBtXu6V0Sv9na48vniHXBfIbhOzXw4zrU/Su0lxO1qc8CWwWdzEjU7CqSZHeIf0BZyj34HdVl3
        PDTzgWM6tWpuraVNLllNIAOFSYAR0z1wl4AwTGiLezcWyVTuOlhIsDQueRP9+FatJBe/C3gogYLA4VXfBlXmK0ff2j6LnKcU14dp
        q0TAH3+Dm8wriI47CGz3wckx665kW+bwxRaJrcK/a6pjU94Pa9kLsh3RhT/b9MnhLPhqRDeuKqIJBlhH5BBEm9ua4jHnoBtgKZ5W
        GW9MBVDqymb2kFFT53NHyv/7EDjTGBHbE9/vrWPjsZe0YTiiRgxeF2iXvZ8hMqyUcUP1AgtAsGPmvxWQfWDpKbTAPHrtz/KO8ABs
        edcWHm1UL3FijCGqA6/ZzC1HEhWaiBqqrqtrdtxJpgnHs5qPjJ9CsAAtrjCCARgGCSqGSIb3DQEHAaCCAQkEggEFMIIBATCB/gYL
        KoZIhvcNAQwKAQKggbQwgbEwHAYKKoZIhvcNAQwBAzAOBAhKxaiwuMgc+gICCAAEgZAiderNmdMvtU2pX/S7PqYE6RbbHiLp9ksI
        wnvWGboO2k/xwbdEpEhCPhnwVffE3z10mbMCjIs2lWj/MfEjyvxMCop/CEq+V/VBGIV0d96EFMlHdAK+gbx+R4nurpqCySQLH9UT
        MaqYMzUMsiTQcZz1NDS+S3sa8Qup1RuWkxdfNtLajYnICFIE1x6raiU34tgxODARBgkqhkiG9w0BCRQxBB4CAHAwIwYJKoZIhvcN
        AQkVMRYEFFcn3qifM5jjxX+Uhpt0oOAvb8wtMDEwITAJBgUrDgMCGgUABBQjMUL7lX2cf8g9B60TdZJD7SbeqgQIxV/k7flkgq8C
        AggA
        """, options: .ignoreUnknownCharacters)!

    /// Documents the platform behaviour that makes the retry necessary.
    func testArchiveWithShortECScalarImportsWithoutAnIdentity() {
        XCTAssertThrowsError(try TLSIdentityStore.importIdentity(fromPKCS12: Self.shortScalarArchive)) { error in
            guard case TLSIdentityError.noIdentityInArchive = error else {
                return XCTFail("expected noIdentityInArchive, got \(error)")
            }
        }
    }

    func testGenerationIsRetriedWhenTheFreshArchiveHasNoUsableIdentity() throws {
        let store = try StateStore(directory: directory)
        var attempts = 0
        let identity = try TLSIdentityStore.loadOrCreate(in: store) { workDirectory in
            attempts += 1
            // The first two keys are of the unlucky kind; then a normal one.
            return attempts <= 2
                ? Self.shortScalarArchive
                : try TLSIdentityStore.generatePKCS12(workingIn: workDirectory)
        }
        XCTAssertEqual(attempts, 3)
        XCTAssertTrue(CertificateFingerprint.isWellFormed(identity.fingerprint))
        // What was persisted is the good archive, and it reloads to the same identity.
        XCTAssertNotEqual(store.read(StateStore.identityFile), Self.shortScalarArchive)
        XCTAssertEqual(try TLSIdentityStore.loadOrCreate(in: store).fingerprint, identity.fingerprint)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["identity.p12"])
    }

    func testGenerationGivesUpAfterABoundedNumberOfAttempts() throws {
        let store = try StateStore(directory: directory)
        var attempts = 0
        XCTAssertThrowsError(try TLSIdentityStore.loadOrCreate(in: store) { _ in
            attempts += 1
            return Self.shortScalarArchive
        })
        XCTAssertEqual(attempts, TLSIdentityStore.generationAttempts)
        XCTAssertNil(store.read(StateStore.identityFile), "a useless archive must never be persisted")
    }

    func testUnreadableArchiveIsSetAsideAndReplaced() throws {
        let store = try StateStore(directory: directory)
        try store.write(Data("definitely not PKCS#12".utf8), to: StateStore.identityFile)
        let identity = try TLSIdentityStore.loadOrCreate(in: store)
        XCTAssertTrue(CertificateFingerprint.isWellFormed(identity.fingerprint))
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
            ["identity.p12", "identity.p12.unreadable"])
        // And the replacement is stable from here on.
        XCTAssertEqual(try TLSIdentityStore.loadOrCreate(in: store).fingerprint, identity.fingerprint)
    }
}
