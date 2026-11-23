import Foundation
import MyRemoteAgentKit
import MyRemoteCore
import XCTest

/// Spawns the built `MyRemoteAgent` executable in headless dry-run mode, exactly as
/// PROTOCOL.md section 6 describes, and talks to it like the Android tests will:
/// read `PAIRING`, connect with the pinned fingerprint, send commands, read `INJECT`.
final class HeadlessCLITests: XCTestCase {
    /// Collects the child's stdout as lines.
    private final class LineReader: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var lines: [String] = []

        func feed(_ data: Data) {
            lock.withLock {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
        }

        var all: [String] { lock.withLock { lines } }
    }

    private var directory: URL!
    private var process: Process?
    private var clients: [TestClient] = []

    override func setUpWithError() throws {
        directory = try TestDirectories.make("cli")
    }

    override func tearDown() {
        clients.forEach { $0.close() }
        clients = []
        if let process {
            Self.stop(process)
        }
        process = nil
        TestDirectories.remove(directory)
    }

    /// SIGTERM, then wait for the exit by polling. (`Process.waitUntilExit` spins a
    /// nested run loop and does not return when called from XCTest's main-thread
    /// tear-down, so it is avoided here.)
    private static func stop(_ process: Process, timeout: TimeInterval = 5) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            usleep(200_000)
        }
    }

    /// The executable SwiftPM built next to the test bundle.
    private func executableURL() throws -> URL {
        let url = Bundle(for: HeadlessCLITests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("MyRemoteAgent")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("MyRemoteAgent executable not found at \(url.path)")
        }
        return url
    }

    /// `--no-bonjour` is the one addition to the contract's command line: a test
    /// run must not advertise a service on the LAN (or cause a Local Network
    /// prompt when the tests are started from an IDE).
    private func launch(_ extraArguments: [String] = []) throws -> LineReader {
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = [
            "--headless", "--dry-run", "--loopback", "--port", "0", "--state-dir", directory.path, "--no-bonjour",
        ] + extraArguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let reader = LineReader()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                reader.feed(data)
            }
        }
        try process.run()
        self.process = process
        return reader
    }

    private func waitForLine(
        in reader: LineReader, timeout: TimeInterval = 15, where predicate: (String) -> Bool
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let line = reader.all.first(where: predicate) { return line }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw TestClientError(description: "no matching stdout line within \(timeout) s; got \(reader.all)")
    }

    private func pairing(from reader: LineReader) async throws -> PairingInfo {
        let line = try await waitForLine(in: reader) { $0.hasPrefix("PAIRING ") }
        XCTAssertEqual(reader.all.first, line, "PAIRING must be the first stdout line")
        return try PairingURI.parse(String(line.dropFirst("PAIRING ".count)))
    }

    private func connect(_ pairing: PairingInfo) async throws -> (TestClient, RemoteState) {
        let client = TestClient(port: UInt16(pairing.port), pinnedFingerprint: pairing.fp)
        clients.append(client)
        try await client.connect()
        XCTAssertEqual(client.servedFingerprint, pairing.fp)
        guard case let .welcome(v, agent, state) = try await client.hello(token: pairing.token) else {
            throw TestClientError(description: "no welcome")
        }
        XCTAssertEqual(v, 1)
        XCTAssertEqual(agent, AgentInfo(id: pairing.id, name: pairing.name))
        return (client, state)
    }

    func testPairingLineThenCommandProducesInjectLine() async throws {
        let reader = try launch(["--profile", "youtube"])
        let pairing = try await pairing(from: reader)
        XCTAssertEqual(pairing.host, "127.0.0.1", "--loopback")
        XCTAssertNotEqual(pairing.port, 47110, "--port 0 must not pick the default port")

        let (client, state) = try await connect(pairing)
        XCTAssertEqual(state, RemoteState(frontApp: nil, profile: .youtube, accessibility: true))

        try await client.send(.cmd(action: "playPause", id: 7))
        let ack = try await client.receiveMessage()
        XCTAssertEqual(ack, .ack(id: 7, ok: true, error: nil))
        let inject = try await waitForLine(in: reader) { $0.hasPrefix("INJECT ") }
        XCTAssertEqual(inject, #"INJECT {"key":"k","keyCode":40,"kind":"key","modifiers":[]}"#)
    }

    /// The contract's own flags, nothing pinned: the profile follows whatever app is
    /// frontmost on this machine, so the assertions only use profile-independent
    /// messages plus the mapping of the profile the agent itself reported.
    func testContractCommandLineWithLiveProfile() async throws {
        let reader = try launch()
        let pairing = try await pairing(from: reader)
        let (client, state) = try await connect(pairing)
        XCTAssertTrue(state.accessibility, "dry run reports accessibility=true")
        // Whatever is frontmost on this machine, state must be self-consistent.
        XCTAssertEqual(
            state.profile == .appletv, state.frontApp?.bundleId == "com.apple.TV",
            "profile \(state.profile) does not fit front app \(String(describing: state.frontApp))")

        try await client.send(.key(key: "enter", id: 1))
        try await client.send(.pointer(dx: 12.5, dy: -3.25))
        try await client.send(.click(button: .right, count: 2))
        try await client.send(.scroll(dx: 0, dy: -40.5))
        try await client.send(.text(text: "Привіт, світ! 🎬 \"quoted\"", id: 2))
        // The profile is live here, so a `state` push may arrive at any moment.
        func nextNonStateMessage() async throws -> ServerMessage {
            while true {
                let message = try await client.receiveMessage()
                if case .state = message { continue }
                return message
            }
        }
        let firstAck = try await nextNonStateMessage()
        let secondAck = try await nextNonStateMessage()
        XCTAssertEqual(firstAck, .ack(id: 1, ok: true, error: nil))
        XCTAssertEqual(secondAck, .ack(id: 2, ok: true, error: nil))

        _ = try await waitForLine(in: reader) { $0.contains(#""kind":"text""#) }
        let injected = reader.all.filter { $0.hasPrefix("INJECT ") }
        XCTAssertEqual(injected, [
            #"INJECT {"key":"enter","keyCode":36,"kind":"key","modifiers":[]}"#,
            #"INJECT {"dx":12.5,"dy":-3.25,"kind":"pointer"}"#,
            #"INJECT {"button":"right","count":2,"kind":"click"}"#,
            #"INJECT {"dx":0,"dy":-40.5,"kind":"scroll"}"#,
            #"INJECT {"kind":"text","text":"Привіт, світ! 🎬 \"quoted\""}"#,
        ])
        // Every stdout line is PAIRING or INJECT; diagnostics go to stderr.
        XCTAssertTrue(reader.all.allSatisfy { $0.hasPrefix("PAIRING ") || $0.hasPrefix("INJECT ") }, "\(reader.all)")
        // Each INJECT payload is one JSON object.
        for line in injected {
            let payload = Data(line.dropFirst("INJECT ".count).utf8)
            XCTAssertTrue(try JSONSerialization.jsonObject(with: payload) is [String: Any], line)
        }
    }

    func testRestartOnTheSameStateDirKeepsIdentityIdAndToken() async throws {
        var reader = try launch()
        let first = try await pairing(from: reader)
        let firstProcess = try XCTUnwrap(process)
        Self.stop(firstProcess)
        XCTAssertFalse(firstProcess.isRunning)
        XCTAssertEqual(firstProcess.terminationStatus, 0, "SIGTERM is a clean shutdown")

        reader = try launch()
        let second = try await pairing(from: reader)
        XCTAssertEqual(second.fp, first.fp)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.token, first.token)
        XCTAssertEqual(second.name, first.name)
        _ = try await connect(second)
    }

    func testBadArgumentsExitWithUsageError() throws {
        let process = Process()
        process.executableURL = try executableURL()
        process.arguments = ["--headless", "--port", "not-a-number"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 64)
        XCTAssertTrue(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty, "nothing on stdout for a usage error")
    }
}
