import Foundation
import MyRemoteCore
import XCTest

final class MessageTests: XCTestCase {
    private func parse(_ json: String) -> ClientParseResult {
        ClientMessage.parse(Data(json.utf8))
    }

    func testUnknownFieldsAreIgnored() {
        XCTAssertEqual(
            parse(#"{"type":"cmd","action":"playPause","id":3,"future":{"a":[1,2]},"x":null}"#),
            .message(.cmd(action: "playPause", id: 3)))
        XCTAssertEqual(
            parse(#"{"future":true,"type":"ping","t":5}"#),
            .message(.ping(t: 5)))
    }

    func testUnknownTypeIsReportedAsSuch() {
        XCTAssertEqual(parse(#"{"type":"teleport","x":1}"#), .unknownType("teleport"))
    }

    func testMalformedFrames() {
        XCTAssertEqual(parse("not json"), .malformed)
        XCTAssertEqual(parse(""), .malformed)
        XCTAssertEqual(parse("[1,2,3]"), .malformed)
        XCTAssertEqual(parse(#""cmd""#), .malformed)
        XCTAssertEqual(parse(#"{"action":"playPause"}"#), .malformed)   // no type
        XCTAssertEqual(parse(#"{"type":7}"#), .malformed)               // type is not a string
    }

    func testKnownTypeWithBadFieldsKeepsTheIdForTheAck() {
        XCTAssertEqual(parse(#"{"type":"cmd","id":4}"#), .invalid(kind: .cmd, id: 4))
        XCTAssertEqual(parse(#"{"type":"cmd","action":5,"id":4}"#), .invalid(kind: .cmd, id: 4))
        XCTAssertEqual(parse(#"{"type":"key"}"#), .invalid(kind: .key, id: nil))
        XCTAssertEqual(parse(#"{"type":"text","text":[],"id":11}"#), .invalid(kind: .text, id: 11))
        XCTAssertEqual(parse(#"{"type":"cmd","action":"playPause","id":"seven"}"#), .invalid(kind: .cmd, id: nil))
        XCTAssertEqual(parse(#"{"type":"cmd","action":"playPause","id":1.5}"#), .invalid(kind: .cmd, id: nil))
    }

    func testClickValidation() {
        XCTAssertEqual(parse(#"{"type":"click","button":"left","count":2}"#), .message(.click(button: .left, count: 2)))
        XCTAssertEqual(parse(#"{"type":"click","button":"middle","count":1}"#), .invalid(kind: .click, id: nil))
        XCTAssertEqual(parse(#"{"type":"click","button":"left","count":3}"#), .invalid(kind: .click, id: nil))
        XCTAssertEqual(parse(#"{"type":"click","button":"left","count":0}"#), .invalid(kind: .click, id: nil))
        XCTAssertEqual(parse(#"{"type":"click","button":"left"}"#), .invalid(kind: .click, id: nil))
    }

    func testNumbersMayBeIntegralOrFractional() {
        XCTAssertEqual(parse(#"{"type":"pointer","dx":3,"dy":-0.5}"#), .message(.pointer(dx: 3, dy: -0.5)))
        XCTAssertEqual(parse(#"{"type":"scroll","dx":1e1,"dy":0}"#), .message(.scroll(dx: 10, dy: 0)))
        XCTAssertEqual(parse(#"{"type":"pointer","dx":"3","dy":1}"#), .invalid(kind: .pointer, id: nil))
        XCTAssertEqual(parse(#"{"type":"ping","t":1.5}"#), .invalid(kind: .ping, id: nil))
    }

    func testHelloDeviceIsOptionalOnInput() {
        XCTAssertEqual(parse(#"{"type":"hello","v":1,"token":"abc"}"#), .message(.hello(v: 1, token: "abc", device: nil)))
        XCTAssertEqual(parse(#"{"type":"hello","v":1}"#), .invalid(kind: .hello, id: nil))
    }

    func testProbeVersion() {
        XCTAssertEqual(ClientMessage.probeVersion(Data(#"{"type":"hello","v":2,"auth":{}}"#.utf8)), 2)
        XCTAssertNil(ClientMessage.probeVersion(Data(#"{"type":"hello","v":"2"}"#.utf8)))
        XCTAssertNil(ClientMessage.probeVersion(Data(#"{"type":"hello"}"#.utf8)))
    }

    func testAckCarriesErrorOnlyWhenNotOK() throws {
        let ok = try JSONSerialization.jsonObject(with: WireJSON.encode(ServerMessage.ackOK(1))) as! [String: Any]
        XCTAssertEqual(Set(ok.keys), ["type", "id", "ok"])
        // Even a (nonsensical) ok ack constructed with an error must not put it on the wire.
        let odd = try JSONSerialization.jsonObject(
            with: WireJSON.encode(ServerMessage.ack(id: 1, ok: true, error: .unsupported))) as! [String: Any]
        XCTAssertNil(odd["error"])
        let failed = try JSONSerialization.jsonObject(
            with: WireJSON.encode(ServerMessage.ackFailed(2, .unsupported))) as! [String: Any]
        XCTAssertEqual(failed["error"] as? String, "unsupported")
        XCTAssertEqual(failed["ok"] as? Bool, false)
    }

    func testStateAlwaysCarriesFrontAppKey() throws {
        let data = WireJSON.encode(ServerMessage.state(RemoteState(frontApp: nil, profile: .generic, accessibility: true)))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let state = object["state"] as! [String: Any]
        XCTAssertTrue(state["frontApp"] is NSNull)
    }

    func testWireJSONIsASingleLine() {
        let text = WireJSON.string(ServerMessage.error(code: .badRequest, message: "line one\nline two"))
        XCTAssertFalse(text.contains("\n"))
        let inject = WireJSON.string(InputAction.text("a\nb\u{2028}c"))
        XCTAssertFalse(inject.contains("\n"))
    }

    func testWireVocabulary() {
        XCTAssertEqual(AckError.allCases.map(\.rawValue), ["accessibility_denied", "unsupported", "bad_request"])
        XCTAssertEqual(ErrorCode.allCases.map(\.rawValue), ["unauthorized", "unsupported_version", "bad_request"])
        XCTAssertEqual(Profile.allCases.map(\.rawValue), ["youtube", "netflix", "appletv", "generic"])
        XCTAssertEqual(
            CmdAction.allCases.map(\.rawValue),
            ["playPause", "seekBackward", "seekForward", "volumeUp", "volumeDown", "toggleMute",
             "toggleFullscreen", "nextItem", "previousItem", "skip", "toggleSubtitles"])
        XCTAssertEqual(
            RemoteKey.allCases.map(\.rawValue),
            ["up", "down", "left", "right", "enter", "escape", "space", "tab", "backspace"])
    }

    func testInjectLineShapes() throws {
        func object(_ action: InputAction) throws -> NSDictionary {
            try JSONSerialization.jsonObject(with: WireJSON.encode(action)) as! NSDictionary
        }
        XCTAssertEqual(
            try object(.key(.k)),
            ["kind": "key", "key": "k", "keyCode": 40, "modifiers": [String]()] as NSDictionary)
        XCTAssertEqual(
            try object(.key(.f, modifiers: [.command, .control])),
            ["kind": "key", "key": "f", "keyCode": 3, "modifiers": ["control", "command"]] as NSDictionary)
        XCTAssertEqual(try object(.mediaKey(.playPause)), ["kind": "mediaKey", "key": "playPause"] as NSDictionary)
        XCTAssertEqual(
            try object(.pointer(dx: 12.5, dy: -3.25)),
            ["kind": "pointer", "dx": 12.5, "dy": -3.25] as NSDictionary)
        XCTAssertEqual(
            try object(.click(button: .right, count: 2)),
            ["kind": "click", "button": "right", "count": 2] as NSDictionary)
        XCTAssertEqual(try object(.scroll(dx: 0, dy: -40.5)), ["kind": "scroll", "dx": 0, "dy": -40.5] as NSDictionary)
        XCTAssertEqual(try object(.text("Привіт 🎬")), ["kind": "text", "text": "Привіт 🎬"] as NSDictionary)
        // Keys are sorted, so the text of a line is deterministic.
        XCTAssertEqual(
            WireJSON.string(InputAction.key(.k)), #"{"key":"k","keyCode":40,"kind":"key","modifiers":[]}"#)
    }
}
