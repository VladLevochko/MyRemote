import CoreGraphics
import Foundation
import MyRemoteAgentKit
import MyRemoteCore
import XCTest

/// Opt-in, and never run automatically: this is the only test that posts real
/// events into the live session.
///
///     MYREMOTE_TEST_REAL_INJECTION=1 swift test --filter RealInjectionSmokeTests
///
/// It needs the Accessibility permission for whatever runs the tests (Terminal,
/// Xcode). What it does is deliberately harmless: it nudges the mouse pointer by
/// a few points and puts it back. It never types, clicks, scrolls or presses a
/// media key.
final class RealInjectionSmokeTests: XCTestCase {
    func testPointerNudgeAndBack() throws {
        guard ProcessInfo.processInfo.environment["MYREMOTE_TEST_REAL_INJECTION"] == "1" else {
            throw XCTSkip("set MYREMOTE_TEST_REAL_INJECTION=1 to post real pointer events")
        }
        let injector = RealInjector()
        guard injector.isTrusted else {
            XCTAssertEqual(injector.perform(.pointer(dx: 1, dy: 1)), .accessibilityDenied)
            throw XCTSkip("no Accessibility permission: the injector correctly refused to post")
        }
        let before = try XCTUnwrap(CGEvent(source: nil)?.location)
        XCTAssertEqual(injector.perform(.pointer(dx: 7, dy: 5)), .ok)
        usleep(100_000)
        let moved = try XCTUnwrap(CGEvent(source: nil)?.location)
        XCTAssertEqual(injector.perform(.pointer(dx: -7, dy: -5)), .ok)
        usleep(100_000)
        let after = try XCTUnwrap(CGEvent(source: nil)?.location)

        // At a screen edge the move is clamped, so only require "moved, then back".
        XCTAssertNotEqual(moved, before, "the pointer did not move")
        XCTAssertEqual(after.x, before.x, accuracy: 8)
        XCTAssertEqual(after.y, before.y, accuracy: 8)
    }
}
