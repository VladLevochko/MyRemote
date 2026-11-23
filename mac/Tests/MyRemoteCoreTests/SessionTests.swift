import Foundation
import MyRemoteCore
import XCTest

/// The session state machine, driven with a fake clock and a fake injector.
/// No real time passes and nothing is injected anywhere.
final class SessionTests: XCTestCase {
    private let token = "q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA"
    private let agent = AgentInfo(id: "0123456789abcdef", name: "MacBook Pro")

    private var injector: FakeInjector!
    private var state: RemoteState!
    private var validToken: String!
    private var now: TimeInterval = 1000

    override func setUp() {
        super.setUp()
        injector = FakeInjector()
        state = RemoteState(
            frontApp: FrontApp(bundleId: "com.google.Chrome", name: "Google Chrome"),
            profile: .youtube, accessibility: true)
        validToken = token
        now = 1000
    }

    private func makeSession(config: SessionConfig = SessionConfig()) -> Session {
        let environment = SessionEnvironment(
            agent: agent,
            verifyToken: { [unowned self] in PairingToken.constantTimeEquals($0, self.validToken) },
            currentState: { [unowned self] in self.state },
            injector: injector)
        return Session(config: config, environment: environment, now: now)
    }

    private func send(_ session: Session, _ json: String) -> [SessionEffect] {
        session.receiveText(Data(json.utf8), now: now)
    }

    private func hello(_ session: Session, token: String? = nil, v: Int = 1) -> [SessionEffect] {
        send(session, #"{"type":"hello","v":\#(v),"token":"\#(token ?? self.token)","device":"Galaxy S24"}"#)
    }

    private func authenticated(config: SessionConfig = SessionConfig()) -> Session {
        let session = makeSession(config: config)
        _ = hello(session)
        XCTAssertTrue(session.isAuthenticated)
        return session
    }

    private let unauthorizedClose = SessionEffect.close(code: 4401)

    // MARK: Handshake

    func testHelloWithValidTokenIsWelcomed() {
        let session = makeSession()
        XCTAssertEqual(session.phase, .awaitingHello)
        XCTAssertEqual(hello(session), [.send(.welcome(v: 1, agent: agent, state: state))])
        XCTAssertEqual(session.phase, .authenticated(device: "Galaxy S24"))
        XCTAssertEqual(session.device, "Galaxy S24")
    }

    func testFixtureHelloIsAccepted() throws {
        let session = makeSession()
        let effects = session.receiveText(try Fixtures.data("client/hello.json"), now: now)
        XCTAssertEqual(effects, [.send(.welcome(v: 1, agent: agent, state: state))])
    }

    func testWrongTokenIsUnauthorized() {
        let session = makeSession()
        let effects = hello(session, token: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertEqual(effects, [.send(.error(code: .unauthorized, message: "invalid token")), unauthorizedClose])
        XCTAssertEqual(session.phase, .closed)
        XCTAssertTrue(injector.actions.isEmpty)
    }

    func testEmptyAndNearMissTokensAreUnauthorized() {
        for bad in ["", String(token.dropLast()), token + "A", token.lowercased()] {
            let session = makeSession()
            XCTAssertEqual(hello(session, token: bad).last, unauthorizedClose, bad)
        }
    }

    func testNonHelloFirstIsUnauthorized() {
        let frames = [
            #"{"type":"cmd","action":"playPause","id":1}"#,
            #"{"type":"ping","t":1}"#,
            #"{"type":"pointer","dx":1,"dy":1}"#,
            #"{"type":"somethingNew"}"#,
            "garbage",
            "{}",
        ]
        for frame in frames {
            let session = makeSession()
            let effects = send(session, frame)
            XCTAssertEqual(effects.count, 2, frame)
            guard case .send(.error(code: .unauthorized, _)) = effects[0] else { return XCTFail(frame) }
            XCTAssertEqual(effects[1], unauthorizedClose, frame)
            XCTAssertEqual(session.phase, .closed)
        }
        XCTAssertTrue(injector.actions.isEmpty, "nothing may be injected before authentication")
    }

    func testMalformedHelloIsUnauthorized() {
        let session = makeSession()
        let effects = send(session, #"{"type":"hello","v":1}"#)
        XCTAssertEqual(effects.last, unauthorizedClose)
    }

    func testUnsupportedVersion() {
        let session = makeSession()
        let effects = hello(session, v: 2)
        XCTAssertEqual(effects.count, 2)
        guard case .send(.error(code: .unsupportedVersion, _)) = effects[0] else { return XCTFail("\(effects)") }
        XCTAssertEqual(effects[1], .close(code: 4400))
        XCTAssertEqual(session.phase, .closed)
    }

    func testUnsupportedVersionWinsOverTokenCheckAndOverUnknownHelloShape() {
        // Wrong token and wrong version: the version is what the client must learn about.
        var session = makeSession()
        XCTAssertEqual(hello(session, token: "nope", v: 0).last, .close(code: 4400))
        // A future hello that no longer has a `token` at all.
        session = makeSession()
        let effects = send(session, #"{"type":"hello","v":2,"auth":{"scheme":"new"}}"#)
        guard case .send(.error(code: .unsupportedVersion, _)) = effects.first else { return XCTFail("\(effects)") }
        XCTAssertEqual(effects.last, .close(code: 4400))
    }

    func testHelloTimeout() {
        let session = makeSession()
        XCTAssertEqual(session.deadline, 1005)
        XCTAssertEqual(session.tick(now: 1004.999), [])
        XCTAssertEqual(session.phase, .awaitingHello)
        let effects = session.tick(now: 1005)
        XCTAssertEqual(effects.count, 2)
        guard case .send(.error(code: .unauthorized, _)) = effects[0] else { return XCTFail("\(effects)") }
        XCTAssertEqual(effects[1], unauthorizedClose)
        XCTAssertEqual(session.phase, .closed)
        XCTAssertNil(session.deadline)
        // Nothing more comes out of a closed session.
        XCTAssertEqual(session.tick(now: 2000), [])
        XCTAssertEqual(hello(session), [])
    }

    func testHelloArrivingAfterTheDeadlineIsStillTooLate() {
        let session = makeSession()
        now = 1005.5   // the timer has not fired yet, but 5 s are over
        XCTAssertEqual(hello(session).last, unauthorizedClose)
        XCTAssertFalse(session.isAuthenticated)
    }

    func testHelloJustBeforeTheDeadlineIsAccepted() {
        let session = makeSession()
        now = 1004.9
        XCTAssertEqual(hello(session), [.send(.welcome(v: 1, agent: agent, state: state))])
    }

    func testBinaryFramesAreIgnoredAndDoNotCountAsFirstMessage() {
        let session = makeSession()
        XCTAssertEqual(session.receiveBinary(), [])
        XCTAssertEqual(session.phase, .awaitingHello)
        XCTAssertEqual(hello(session), [.send(.welcome(v: 1, agent: agent, state: state))])
        XCTAssertEqual(session.receiveBinary(), [])
        XCTAssertTrue(session.isAuthenticated)
    }

    func testSecondHelloIsABadRequestNotAReauthentication() {
        let session = authenticated()
        let effects = hello(session, token: "wrong")
        XCTAssertEqual(effects.count, 1)
        guard case .send(.error(code: .badRequest, _)) = effects[0] else { return XCTFail("\(effects)") }
        XCTAssertTrue(session.isAuthenticated)
    }

    // MARK: cmd

    func testCmdWithIdIsAckedAndMappedThroughTheCurrentProfile() {
        let session = authenticated()
        XCTAssertEqual(send(session, #"{"type":"cmd","action":"playPause","id":7}"#), [.send(.ackOK(7))])
        XCTAssertEqual(injector.actions, [.key(.k)])

        state.profile = .generic   // the user switched apps; the open session must follow
        XCTAssertEqual(send(session, #"{"type":"cmd","action":"playPause","id":8}"#), [.send(.ackOK(8))])
        XCTAssertEqual(injector.actions, [.key(.k), .mediaKey(.playPause)])
    }

    func testCmdWithoutIdIsNotAcked() {
        let session = authenticated()
        XCTAssertEqual(send(session, #"{"type":"cmd","action":"seekForward"}"#), [])
        XCTAssertEqual(injector.actions, [.key(.l)])
    }

    func testEveryActionInEveryProfileIsAckedAccordingToTheMap() {
        for profile in Profile.allCases {
            state.profile = profile
            for (index, action) in CmdAction.allCases.enumerated() {
                let session = authenticated()
                let before = injector.actions.count
                let effects = send(session, #"{"type":"cmd","action":"\#(action.rawValue)","id":\#(index)}"#)
                if let mapped = ProfileMap.action(for: action, profile: profile) {
                    XCTAssertEqual(effects, [.send(.ackOK(index))], "\(profile).\(action)")
                    XCTAssertEqual(injector.actions.last, mapped)
                    XCTAssertEqual(injector.actions.count, before + 1)
                } else {
                    XCTAssertEqual(effects, [.send(.ackFailed(index, .unsupported))], "\(profile).\(action)")
                    XCTAssertEqual(injector.actions.count, before, "unsupported must not inject")
                }
            }
        }
    }

    func testUnsupportedActionWithoutIdIsSilent() {
        let session = authenticated()
        XCTAssertEqual(send(session, #"{"type":"cmd","action":"skip"}"#), [])
        XCTAssertTrue(injector.actions.isEmpty)
    }

    func testUnknownActionIsAckedBadRequest() {
        let session = authenticated()
        XCTAssertEqual(
            send(session, #"{"type":"cmd","action":"selfDestruct","id":5}"#), [.send(.ackFailed(5, .badRequest))])
        XCTAssertEqual(send(session, #"{"type":"cmd","action":"selfDestruct"}"#), [])
        XCTAssertEqual(send(session, #"{"type":"cmd","action":"PlayPause","id":6}"#), [.send(.ackFailed(6, .badRequest))])
        XCTAssertTrue(injector.actions.isEmpty)
        XCTAssertTrue(session.isAuthenticated)
    }

    func testCmdWithMissingActionButReadableIdIsAckedBadRequest() {
        let session = authenticated()
        XCTAssertEqual(send(session, #"{"type":"cmd","id":5}"#), [.send(.ackFailed(5, .badRequest))])
        XCTAssertTrue(session.isAuthenticated)
    }

    func testAccessibilityDenied() {
        let session = authenticated()
        injector.isTrusted = false
        XCTAssertEqual(
            send(session, #"{"type":"cmd","action":"playPause","id":7}"#),
            [.send(.ackFailed(7, .accessibilityDenied))])
        XCTAssertEqual(send(session, #"{"type":"key","key":"enter","id":8}"#), [.send(.ackFailed(8, .accessibilityDenied))])
        XCTAssertEqual(send(session, #"{"type":"text","text":"hi","id":9}"#), [.send(.ackFailed(9, .accessibilityDenied))])
        XCTAssertEqual(send(session, #"{"type":"cmd","action":"playPause"}"#), [])
        // Unacknowledged kinds stay silent even when denied.
        XCTAssertEqual(send(session, #"{"type":"pointer","dx":1,"dy":1}"#), [])
        XCTAssertEqual(send(session, #"{"type":"click","button":"left","count":1}"#), [])
        XCTAssertEqual(send(session, #"{"type":"scroll","dx":0,"dy":3}"#), [])
        XCTAssertTrue(injector.actions.isEmpty)
        // `unsupported` is decided before the permission matters.
        XCTAssertEqual(send(session, #"{"type":"cmd","action":"skip","id":10}"#), [.send(.ackFailed(10, .unsupported))])
    }

    // MARK: key / text / pointer / click / scroll

    func testEveryNamedKey() {
        let session = authenticated()
        for (index, key) in RemoteKey.allCases.enumerated() {
            XCTAssertEqual(
                send(session, #"{"type":"key","key":"\#(key.rawValue)","id":\#(index)}"#), [.send(.ackOK(index))])
            XCTAssertEqual(injector.actions.last, .key(key.virtualKey))
        }
        XCTAssertEqual(injector.actions.count, RemoteKey.allCases.count)
        // Named keys do not depend on the profile.
        state.profile = .appletv
        XCTAssertEqual(send(session, #"{"type":"key","key":"enter"}"#), [])
        XCTAssertEqual(injector.actions.last, .key(.enter))
    }

    func testUnknownKeyIsAckedBadRequest() {
        let session = authenticated()
        XCTAssertEqual(send(session, #"{"type":"key","key":"f13","id":1}"#), [.send(.ackFailed(1, .badRequest))])
        XCTAssertEqual(send(session, #"{"type":"key","key":"f13"}"#), [])
        XCTAssertTrue(injector.actions.isEmpty)
    }

    func testFixtureMessagesProduceTheRightInjection() throws {
        let session = authenticated()
        func feed(_ name: String) throws -> [SessionEffect] {
            session.receiveText(try Fixtures.data("client/\(name).json"), now: now)
        }
        XCTAssertEqual(try feed("cmd_with_id"), [.send(.ackOK(7))])
        XCTAssertEqual(try feed("cmd_without_id"), [])
        XCTAssertEqual(try feed("key"), [.send(.ackOK(8))])
        XCTAssertEqual(try feed("pointer"), [])
        XCTAssertEqual(try feed("click_left"), [])
        XCTAssertEqual(try feed("click_right_double"), [])
        XCTAssertEqual(try feed("scroll"), [])
        XCTAssertEqual(try feed("text"), [.send(.ackOK(9))])
        XCTAssertEqual(try feed("ping"), [.send(.pong(t: 1_790_000_000_123))])
        XCTAssertEqual(injector.actions, [
            .key(.k),
            .key(.l),
            .key(.enter),
            .pointer(dx: 12.5, dy: -3.25),
            .click(button: .left, count: 1),
            .click(button: .right, count: 2),
            .scroll(dx: 0, dy: -40.5),
            .text("Привіт, світ! 🎬 \"quoted\""),
        ])
    }

    func testTextWithoutIdIsTypedButNotAcked() {
        let session = authenticated()
        XCTAssertEqual(send(session, #"{"type":"text","text":"hello"}"#), [])
        XCTAssertEqual(injector.actions, [.text("hello")])
    }

    func testEmptyTextIsAckedWithoutInjecting() {
        let session = authenticated()
        XCTAssertEqual(send(session, #"{"type":"text","text":"","id":3}"#), [.send(.ackOK(3))])
        XCTAssertTrue(injector.actions.isEmpty)
    }

    func testOverlongTextIsRejected() {
        let session = authenticated(config: SessionConfig(maxTextLength: 8))
        XCTAssertEqual(send(session, #"{"type":"text","text":"12345678","id":1}"#), [.send(.ackOK(1))])
        XCTAssertEqual(send(session, #"{"type":"text","text":"123456789","id":2}"#), [.send(.ackFailed(2, .badRequest))])
        XCTAssertEqual(injector.actions, [.text("12345678")])
    }

    func testPointerClickScrollAreNeverAcked() {
        let session = authenticated()
        // An `id` on these is an unknown field and is ignored.
        XCTAssertEqual(send(session, #"{"type":"pointer","dx":1.5,"dy":-2,"id":1}"#), [])
        XCTAssertEqual(send(session, #"{"type":"click","button":"left","count":2,"id":2}"#), [])
        XCTAssertEqual(send(session, #"{"type":"scroll","dx":0,"dy":10,"id":3}"#), [])
        XCTAssertEqual(injector.actions, [
            .pointer(dx: 1.5, dy: -2), .click(button: .left, count: 2), .scroll(dx: 0, dy: 10),
        ])
    }

    func testInvalidUnackedMessagesGetProtocolErrorAndStayOpen() {
        let session = authenticated()
        for frame in [
            #"{"type":"click","button":"middle","count":1}"#,
            #"{"type":"click","button":"left","count":5}"#,
            #"{"type":"pointer","dx":"a","dy":1}"#,
            #"{"type":"scroll","dy":1}"#,
            #"{"type":"ping"}"#,
            #"{"type":"cmd"}"#,
        ] {
            let effects = send(session, frame)
            XCTAssertEqual(effects.count, 1, frame)
            guard case .send(.error(code: .badRequest, _)) = effects[0] else { return XCTFail(frame) }
        }
        XCTAssertTrue(session.isAuthenticated)
        XCTAssertTrue(injector.actions.isEmpty)
    }

    // MARK: ping, unknown type, malformed

    func testPingPong() {
        let session = authenticated()
        XCTAssertEqual(send(session, #"{"type":"ping","t":1790000000123}"#), [.send(.pong(t: 1_790_000_000_123))])
        XCTAssertEqual(send(session, #"{"type":"ping","t":0}"#), [.send(.pong(t: 0))])
    }

    func testUnknownTypeGivesBadRequestWithoutClosing() {
        let session = authenticated()
        let effects = send(session, #"{"type":"warpDrive","id":3}"#)
        XCTAssertEqual(effects.count, 1)
        guard case .send(.error(code: .badRequest, _)) = effects[0] else { return XCTFail("\(effects)") }
        XCTAssertTrue(session.isAuthenticated)
        // The connection is fully usable afterwards.
        XCTAssertEqual(send(session, #"{"type":"cmd","action":"toggleMute","id":4}"#), [.send(.ackOK(4))])
        XCTAssertEqual(injector.actions, [.key(.m)])
    }

    func testMalformedJSONGivesBadRequestWithoutClosing() {
        let session = authenticated()
        for frame in ["", "nope", "[]", "{\"type\":", #"{"noType":1}"#] {
            let effects = send(session, frame)
            XCTAssertEqual(effects.count, 1, frame)
            guard case .send(.error(code: .badRequest, _)) = effects[0] else { return XCTFail(frame) }
        }
        XCTAssertTrue(session.isAuthenticated)
    }

    // MARK: idle timeout, state push, revoke

    func testIdleTimeoutClosesAfterThirtySecondsOfSilence() {
        let session = authenticated()
        XCTAssertEqual(session.deadline, 1030)
        XCTAssertEqual(session.tick(now: 1029.9), [])
        XCTAssertEqual(session.tick(now: 1030), [.close(code: 1001)])
        XCTAssertEqual(session.phase, .closed)
    }

    func testAnyClientMessageResetsTheIdleTimer() {
        let session = authenticated()
        now = 1025
        _ = send(session, #"{"type":"ping","t":1}"#)
        XCTAssertEqual(session.deadline, 1055)
        XCTAssertEqual(session.tick(now: 1030), [])
        now = 1050
        _ = send(session, #"{"type":"pointer","dx":1,"dy":0}"#)
        XCTAssertEqual(session.deadline, 1080)
        now = 1070
        _ = send(session, #"{"type":"mystery"}"#)   // even an unknown one is a sign of life
        XCTAssertEqual(session.deadline, 1100)
        XCTAssertEqual(session.tick(now: 1099), [])
        XCTAssertEqual(session.tick(now: 1100), [.close(code: 1001)])
    }

    func testBinaryFramesDoNotResetTheIdleTimer() {
        let session = authenticated()
        _ = session.receiveBinary()
        XCTAssertEqual(session.deadline, 1030)
    }

    func testStatePushOnlyAfterAuthentication() {
        let newState = RemoteState(
            frontApp: FrontApp(bundleId: "com.apple.TV", name: "TV"), profile: .appletv, accessibility: true)
        let pending = makeSession()
        XCTAssertEqual(pending.stateDidChange(newState), [])
        let session = authenticated()
        XCTAssertEqual(session.stateDidChange(newState), [.send(.state(newState))])
    }

    func testWelcomeCarriesTheStateAtTheTimeOfHello() {
        state = RemoteState(frontApp: nil, profile: .generic, accessibility: false)
        let session = makeSession()
        XCTAssertEqual(hello(session), [.send(.welcome(v: 1, agent: agent, state: state))])
    }

    func testRevokeClosesWithUnauthorized() {
        let session = authenticated()
        let effects = session.revoke()
        XCTAssertEqual(effects.count, 2)
        guard case .send(.error(code: .unauthorized, _)) = effects[0] else { return XCTFail("\(effects)") }
        XCTAssertEqual(effects[1], unauthorizedClose)
        XCTAssertEqual(session.phase, .closed)
        XCTAssertEqual(session.revoke(), [])
        XCTAssertEqual(send(session, #"{"type":"cmd","action":"playPause","id":1}"#), [])
        XCTAssertTrue(injector.actions.isEmpty)
    }

    func testTokenResetIsSeenByNewHandshakes() {
        let before = makeSession()
        validToken = PairingToken.generate()
        XCTAssertEqual(hello(before).last, unauthorizedClose, "the old token must stop working immediately")
        let after = makeSession()
        XCTAssertEqual(hello(after, token: validToken), [.send(.welcome(v: 1, agent: agent, state: state))])
    }

    func testNothingHappensAfterTransportClosed() {
        let session = authenticated()
        session.transportClosed()
        XCTAssertEqual(send(session, #"{"type":"cmd","action":"playPause","id":1}"#), [])
        XCTAssertEqual(session.tick(now: 5000), [])
        XCTAssertEqual(session.stateDidChange(state), [])
        XCTAssertTrue(injector.actions.isEmpty)
    }
}
