import AppKit
import CoreGraphics
import Foundation
@testable import MyRemoteAgentKit
import MyRemoteCore
import XCTest

final class CLITests: XCTestCase {
    func testContractCommandLine() throws {
        let command = try CLI.parse(["--headless", "--dry-run", "--loopback", "--port", "0", "--state-dir", "/some/dir"])
        var expected = AgentOptions()
        expected.headless = true
        expected.dryRun = true
        expected.loopback = true
        expected.port = 0
        expected.stateDirectory = URL(fileURLWithPath: "/some/dir", isDirectory: true)
        XCTAssertEqual(command, .run(expected))
    }

    func testDefaults() throws {
        guard case let .run(options) = try CLI.parse([]) else { return XCTFail() }
        XCTAssertFalse(options.headless)
        XCTAssertFalse(options.dryRun)
        XCTAssertFalse(options.loopback)
        XCTAssertNil(options.port, "no --port means the default 47110")
        XCTAssertNil(options.stateDirectory, "no --state-dir means ~/Library/Application Support/MyRemote")
        XCTAssertNil(options.forcedProfile)
        XCTAssertTrue(options.advertise)
        XCTAssertTrue(StateStore.defaultDirectory.path.hasSuffix("/Library/Application Support/MyRemote"))
    }

    func testFlagsInAnyOrderAndEqualsForm() throws {
        guard case let .run(options) = try CLI.parse(["--port=50123", "--state-dir=~/x", "--headless"]) else {
            return XCTFail()
        }
        XCTAssertTrue(options.headless)
        XCTAssertEqual(options.port, 50123)
        XCTAssertEqual(options.stateDirectory?.path, NSHomeDirectory() + "/x")
    }

    func testExtensions() throws {
        guard case let .run(options) = try CLI.parse(["--headless", "--profile", "netflix", "--no-bonjour"]) else {
            return XCTFail()
        }
        XCTAssertEqual(options.forcedProfile, .netflix)
        XCTAssertFalse(options.advertise)
        XCTAssertEqual(try CLI.parse(["--help"]), .help)
    }

    func testErrors() {
        XCTAssertThrowsError(try CLI.parse(["--port"])) { XCTAssertEqual($0 as? CLIError, .missingValue("--port")) }
        XCTAssertThrowsError(try CLI.parse(["--port", "70000"])) {
            XCTAssertEqual($0 as? CLIError, .invalidValue(flag: "--port", value: "70000"))
        }
        XCTAssertThrowsError(try CLI.parse(["--port", "-1"]))
        XCTAssertThrowsError(try CLI.parse(["--state-dir"]))
        XCTAssertThrowsError(try CLI.parse(["--profile", "hulu"]))
        XCTAssertThrowsError(try CLI.parse(["--frobnicate"])) {
            XCTAssertEqual($0 as? CLIError, .unknownArgument("--frobnicate"))
        }
        XCTAssertThrowsError(try CLI.parse(["stray"]))
    }
}

final class DryRunInjectorTests: XCTestCase {
    func testPrintsOneInjectLinePerActionAndReportsTrusted() {
        var lines: [String] = []
        let injector = DryRunInjector(output: LineOutput { lines.append($0) })
        XCTAssertTrue(injector.isTrusted, "dry run: accessibility is true")
        XCTAssertEqual(injector.perform(.mediaKey(.playPause)), .ok)
        XCTAssertEqual(injector.perform(.key(.f, modifiers: [.command, .control])), .ok)
        XCTAssertEqual(injector.perform(.click(button: .left, count: 1)), .ok)
        XCTAssertEqual(injector.perform(.scroll(dx: 0, dy: -40.5)), .ok)
        XCTAssertEqual(injector.perform(.text("two\nlines")), .ok)
        XCTAssertEqual(lines, [
            #"INJECT {"key":"playPause","kind":"mediaKey"}"#,
            #"INJECT {"key":"f","keyCode":3,"kind":"key","modifiers":["control","command"]}"#,
            #"INJECT {"button":"left","count":1,"kind":"click"}"#,
            #"INJECT {"dx":0,"dy":-40.5,"kind":"scroll"}"#,
            #"INJECT {"kind":"text","text":"two\nlines"}"#,
        ])
    }
}

/// These tests only *construct* events and inspect them. Nothing is ever posted.
final class EventFactoryTests: XCTestCase {
    private let modifierMask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    func testPlainKeyStroke() {
        let events = EventFactory.keyStroke(.k, modifiers: [], source: nil)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        for event in events {
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 40)
            XCTAssertTrue(event.flags.intersection(modifierMask).isEmpty)
        }
    }

    func testModifiedKeyStroke() {
        let events = EventFactory.keyStroke(.f, modifiers: [.control, .command], source: nil)
        XCTAssertEqual(events.count, 2)
        for event in events {
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 3)
            XCTAssertEqual(event.flags.intersection(modifierMask), [.maskControl, .maskCommand])
        }
        let shifted = EventFactory.keyStroke(.n, modifiers: [.shift], source: nil)
        XCTAssertEqual(shifted[0].flags.intersection(modifierMask), [.maskShift])
        XCTAssertEqual(EventFactory.flags(for: [.option]), [.maskAlternate])
    }

    func testArrowKeysCarryTheHardwareFlags() {
        let events = EventFactory.keyStroke(.up, modifiers: [.command], source: nil)
        for event in events {
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 126)
            XCTAssertTrue(event.flags.contains(.maskNumericPad))
            XCTAssertTrue(event.flags.contains(.maskSecondaryFn))
            XCTAssertEqual(event.flags.intersection(modifierMask), [.maskCommand])
        }
        XCTAssertFalse(EventFactory.keyStroke(.space, modifiers: [], source: nil)[0].flags.contains(.maskSecondaryFn))
    }

    func testUnicodeKeyStrokeCarriesTheText() {
        let text = "Привіт 🎬"
        let events = EventFactory.unicodeKeyStroke(text, source: nil)
        XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        for event in events {
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 64)
            event.keyboardGetUnicodeString(maxStringLength: 64, actualStringLength: &length, unicodeString: &buffer)
            XCTAssertEqual(String(utf16CodeUnits: buffer, count: length), text)
            XCTAssertTrue(event.flags.intersection(modifierMask).isEmpty)
        }
    }

    func testEveryTypingChunkFitsOneEvent() {
        let text = String(repeating: "Довгий текст із емодзі 🎬🍿 і ще трохи. ", count: 8)
        var rebuilt = ""
        for step in TextTyping.steps(for: text) {
            guard case let .unicode(chunk) = step else { return XCTFail("unexpected key step") }
            let event = EventFactory.unicodeKeyStroke(chunk, source: nil)[0]
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 64)
            event.keyboardGetUnicodeString(maxStringLength: 64, actualStringLength: &length, unicodeString: &buffer)
            XCTAssertLessThanOrEqual(length, 20)
            rebuilt += String(utf16CodeUnits: buffer, count: length)
        }
        XCTAssertEqual(rebuilt, text)
    }

    func testMediaKeyEvents() throws {
        let cases: [(MediaKey, Int)] = [
            (.playPause, 16), (.next, 17), (.previous, 18), (.volumeUp, 0), (.volumeDown, 1), (.mute, 7),
        ]
        for (key, keyType) in cases {
            let events = EventFactory.mediaKeyStroke(key)
            XCTAssertEqual(events.count, 2, "\(key)")
            for (index, cgEvent) in events.enumerated() {
                let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
                XCTAssertEqual(event.type, .systemDefined)
                XCTAssertEqual(event.subtype.rawValue, 8)
                XCTAssertEqual((event.data1 & 0xFFFF_0000) >> 16, keyType, "\(key)")
                XCTAssertEqual((event.data1 & 0xFF00) >> 8, index == 0 ? 0xA : 0xB, "\(key) down/up")
            }
        }
    }

    func testClicks() {
        let point = CGPoint(x: 321, y: 123)
        let single = EventFactory.click(button: .left, count: 1, at: point, source: nil)
        XCTAssertEqual(single.map(\.type), [.leftMouseDown, .leftMouseUp])
        XCTAssertEqual(single.map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 1])
        XCTAssertEqual(single.map(\.location), [point, point])

        let double = EventFactory.click(button: .right, count: 2, at: point, source: nil)
        XCTAssertEqual(double.map(\.type), [.rightMouseDown, .rightMouseUp, .rightMouseDown, .rightMouseUp])
        XCTAssertEqual(double.map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 1, 2, 2])
        XCTAssertEqual(
            double.map { $0.getIntegerValueField(.mouseEventButtonNumber) },
            [Int64](repeating: Int64(CGMouseButton.right.rawValue), count: 4))
    }

    func testMouseMove() throws {
        let event = try XCTUnwrap(EventFactory.mouseMove(to: CGPoint(x: 100.5, y: 200.25), dx: 12.5, dy: -3.25, source: nil))
        XCTAssertEqual(event.type, .mouseMoved)
        XCTAssertEqual(event.location.x, 100.5, accuracy: 0.01)
        XCTAssertEqual(event.location.y, 200.25, accuracy: 0.01)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaX), 13)   // 12.5 rounds away from zero
        XCTAssertEqual(event.getIntegerValueField(.mouseEventDeltaY), -3)
    }

    /// Contract: positive dy = "like wheel down". CoreGraphics: negative axis-1 delta = wheel down.
    func testScrollDirectionAndUnits() throws {
        let down = try XCTUnwrap(EventFactory.scroll(pixelsX: 0, pixelsY: 40, source: nil))
        XCTAssertEqual(down.type, .scrollWheel)
        XCTAssertEqual(down.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -40)
        XCTAssertEqual(down.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 0)
        XCTAssertEqual(down.getIntegerValueField(.scrollWheelEventIsContinuous), 1, "pixel units")

        let upAndRight = try XCTUnwrap(EventFactory.scroll(pixelsX: 7, pixelsY: -40, source: nil))
        XCTAssertEqual(upAndRight.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 40)
        XCTAssertEqual(upAndRight.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), -7)

        XCTAssertNil(EventFactory.scroll(pixelsX: 0, pixelsY: 0, source: nil), "nothing to scroll, nothing to post")
    }

    func testDisplayBoundsAreReadable() {
        // Read-only query; on a headless CI machine the list may be empty.
        for bounds in RealInjector.displayBounds() {
            XCTAssertGreaterThan(bounds.width, 0)
            XCTAssertGreaterThan(bounds.height, 0)
        }
    }
}

final class QRCodeTests: XCTestCase {
    func testPairingURISurvivesTheQRCode() throws {
        let uri = try PairingURI.build(PairingInfo(
            host: "192.168.1.42", port: 47110, id: "0123456789abcdef", name: "Мій MacBook Pro",
            fp: String(repeating: "3b", count: 32), token: PairingToken.generate()))
        let image = try XCTUnwrap(QRCode.image(for: uri, pixelsPerModule: 8))
        XCTAssertEqual(image.width, image.height)
        XCTAssertGreaterThan(image.width, 200)
        XCTAssertEqual(QRCode.decode(image), [uri], "the QR code must scan back to exactly the pairing URI")
    }
}

final class HostInfoTests: XCTestCase {
    private func address(_ interface: String, _ address: String) -> HostInfo.InterfaceAddress {
        HostInfo.InterfaceAddress(interface: interface, address: address)
    }

    func testPrefersBuiltInInterfacesOverTunnelsAndBridges() {
        XCTAssertEqual(
            HostInfo.preferredLANAddress(from: [
                address("utun4", "10.8.0.2"), address("bridge100", "192.168.64.1"),
                address("en7", "192.168.1.60"), address("en0", "192.168.1.42"),
            ]),
            "192.168.1.42")
        XCTAssertEqual(
            HostInfo.preferredLANAddress(from: [address("utun4", "10.8.0.2"), address("bridge100", "192.168.64.1")]),
            "192.168.64.1")
        XCTAssertEqual(HostInfo.preferredLANAddress(from: [address("en10", "10.0.0.2"), address("en2", "10.0.0.1")]), "10.0.0.1")
        XCTAssertNil(HostInfo.preferredLANAddress(from: []))
    }

    func testPairingHost() {
        XCTAssertEqual(HostInfo.pairingHost(loopback: true), "127.0.0.1")
        let host = HostInfo.pairingHost(loopback: false)
        XCTAssertFalse(host.isEmpty)
        XCTAssertFalse(host.hasPrefix("127."))
        for entry in HostInfo.ipv4Addresses() {
            XCTAssertFalse(entry.address.hasPrefix("127."))
            XCTAssertFalse(entry.address.hasPrefix("169.254."))
            XCTAssertEqual(entry.address.split(separator: ".").count, 4)
        }
    }

    func testComputerNameIsUsable() throws {
        let name = HostInfo.computerName()
        XCTAssertFalse(name.isEmpty)
        // Whatever the name is, it must survive the pairing URI.
        let info = PairingInfo(
            host: "127.0.0.1", port: 1, id: "0123456789abcdef", name: name,
            fp: String(repeating: "ab", count: 32), token: PairingToken.generate())
        XCTAssertEqual(try PairingURI.parse(try PairingURI.build(info)).name, name)
    }
}

final class FrontAppTrackerTests: XCTestCase {
    private final class FakeProvider: FrontAppProvider {
        private let lock = NSLock()
        private var app: FrontAppSnapshot?
        private var titles: [pid_t: String] = [:]

        func set(app: FrontAppSnapshot?, title: String? = nil) {
            lock.withLock {
                self.app = app
                if let app { titles[app.processIdentifier] = title }
            }
        }

        func frontmostApplication() -> FrontAppSnapshot? { lock.withLock { app } }
        func focusedWindowTitle(of pid: pid_t) -> String? { lock.withLock { titles[pid] } }
    }

    func testSnapshotDerivesFrontAppAndProfile() {
        let chrome = FrontAppSnapshot(
            bundleId: "com.google.Chrome", name: "Google Chrome", processIdentifier: 10, windowTitle: "Cats - YouTube")
        XCTAssertEqual(chrome.frontApp, FrontApp(bundleId: "com.google.Chrome", name: "Google Chrome"))
        XCTAssertEqual(chrome.profile, .youtube)
        let unknown = FrontAppSnapshot(bundleId: nil, name: "mystery", processIdentifier: 11, windowTitle: "YouTube")
        XCTAssertNil(unknown.frontApp)
        XCTAssertEqual(unknown.profile, .generic)
    }

    func testReportsInitialStateAndEveryChangeOnce() {
        let provider = FakeProvider()
        let chrome = FrontAppSnapshot(bundleId: "com.google.Chrome", name: "Google Chrome", processIdentifier: 10, windowTitle: nil)
        provider.set(app: chrome, title: "Inbox - Gmail")

        var reported: [FrontAppSnapshot?] = []
        var expectation = self.expectation(description: "initial")
        let tracker = FrontAppTracker(provider: provider, interval: 0.02) { snapshot in
            reported.append(snapshot)
            expectation.fulfill()
        }
        tracker.start()
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(reported.last??.windowTitle, "Inbox - Gmail")
        XCTAssertEqual(reported.last??.profile, .generic)

        // Same app, new tab: only the window title changes.
        expectation = self.expectation(description: "tab switch")
        provider.set(app: chrome, title: "Lofi beats - YouTube")
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(reported.last??.profile, .youtube)

        // Another app.
        expectation = self.expectation(description: "app switch")
        provider.set(app: FrontAppSnapshot(bundleId: "com.apple.TV", name: "TV", processIdentifier: 20, windowTitle: nil))
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(reported.last??.profile, .appletv)
        XCTAssertEqual(reported.last??.frontApp, FrontApp(bundleId: "com.apple.TV", name: "TV"))

        // No frontmost app at all.
        expectation = self.expectation(description: "nothing in front")
        provider.set(app: nil)
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(reported.count, 4)
        XCTAssertNil(reported.last!)

        // Polling without changes reports nothing further.
        let quiet = self.expectation(description: "quiet")
        quiet.isInverted = true
        expectation = quiet
        wait(for: [quiet], timeout: 0.2)
        XCTAssertEqual(reported.count, 4)
        tracker.stop()
    }
}

final class PowerAssertionTests: XCTestCase {
    /// Takes the real assertion for a few milliseconds and releases it again.
    func testAssertionCanBeTakenAndReleasedIdempotently() {
        let assertion = PowerAssertion(reason: "MyRemote unit test")
        XCTAssertFalse(assertion.isActive)
        assertion.setActive(true)
        XCTAssertTrue(assertion.isActive)
        assertion.setActive(true)
        XCTAssertTrue(assertion.isActive)
        assertion.setActive(false)
        XCTAssertFalse(assertion.isActive)
        assertion.setActive(false)
        XCTAssertFalse(assertion.isActive)
    }
}
