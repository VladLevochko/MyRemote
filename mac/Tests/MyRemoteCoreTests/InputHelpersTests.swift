import Foundation
import MyRemoteCore
import XCTest

final class TextTypingTests: XCTestCase {
    func testShortTextIsOneChunk() {
        XCTAssertEqual(TextTyping.steps(for: "hello"), [.unicode("hello")])
        XCTAssertEqual(TextTyping.steps(for: ""), [])
    }

    func testLongTextIsChunkedAtTwentyUTF16Units() {
        let text = String(repeating: "abcdefghij", count: 5)   // 50 units
        let steps = TextTyping.steps(for: text)
        XCTAssertEqual(steps, [
            .unicode("abcdefghijabcdefghij"), .unicode("abcdefghijabcdefghij"), .unicode("abcdefghij"),
        ])
    }

    func testChunksReassembleToTheOriginalAndRespectTheLimit() {
        let text = "Привіт, світ! 🎬 \"quoted\" — довгий рядок із емодзі 👨‍👩‍👧‍👦 та e\u{301} комбінованими знаками 🇺🇦🇺🇦🇺🇦"
        for limit in [1, 2, 3, 5, 20, 64] {
            var rebuilt = ""
            for step in TextTyping.steps(for: text, maxUTF16Units: limit) {
                guard case let .unicode(chunk) = step else { return XCTFail("unexpected key step") }
                XCTAssertFalse(chunk.isEmpty)
                // A chunk only exceeds the limit when it is a single grapheme that is longer.
                XCTAssertTrue(chunk.utf16.count <= limit || chunk.count == 1, "limit \(limit): \(chunk)")
                rebuilt += chunk
            }
            XCTAssertEqual(rebuilt, text, "limit \(limit)")
        }
    }

    func testGraphemeClustersAreNeverSplit() {
        // 19 ASCII units, then a surrogate pair that would straddle the 20-unit boundary.
        let text = String(repeating: "a", count: 19) + "🎬" + "b"
        XCTAssertEqual(TextTyping.steps(for: text), [.unicode(String(repeating: "a", count: 19)), .unicode("🎬b")])
        // A family emoji is 11 UTF-16 units and one Character.
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(TextTyping.steps(for: family, maxUTF16Units: 4), [.unicode(family)])
    }

    func testLineBreaksAndTabsBecomeKeys() {
        XCTAssertEqual(
            TextTyping.steps(for: "one\ntwo\r\nthree\rfour\tfive"),
            [.unicode("one"), .key(.enter), .unicode("two"), .key(.enter), .unicode("three"), .key(.enter),
             .unicode("four"), .key(.tab), .unicode("five")])
        XCTAssertEqual(TextTyping.steps(for: "\n\n"), [.key(.enter), .key(.enter)])
    }
}

final class ScrollAccumulatorTests: XCTestCase {
    func testWholePixelsPassThrough() {
        var accumulator = ScrollAccumulator()
        let pixels = accumulator.add(dx: 3, dy: -40)
        XCTAssertEqual(pixels.x, 3)
        XCTAssertEqual(pixels.y, -40)
    }

    func testFractionsAreCarriedNotLost() {
        var accumulator = ScrollAccumulator()
        var total: Int32 = 0
        for _ in 0..<10 {
            total += accumulator.add(dx: 0, dy: 0.25).y
        }
        XCTAssertEqual(total, 2)   // 2.5 px requested: 2 emitted, 0.5 pending
        total += accumulator.add(dx: 0, dy: 0.5).y
        XCTAssertEqual(total, 3)
    }

    func testFixtureScrollValue() {
        var accumulator = ScrollAccumulator()
        XCTAssertEqual(accumulator.add(dx: 0, dy: -40.5).y, -40)
        XCTAssertEqual(accumulator.add(dx: 0, dy: -40.5).y, -41)
    }

    func testAxesAreIndependentAndDirectionChangesWork() {
        var accumulator = ScrollAccumulator()
        var result = accumulator.add(dx: 0.6, dy: -0.6)
        XCTAssertEqual(result.x, 0)
        XCTAssertEqual(result.y, 0)
        result = accumulator.add(dx: 0.6, dy: -0.6)
        XCTAssertEqual(result.x, 1)
        XCTAssertEqual(result.y, -1)
        result = accumulator.add(dx: -1.2, dy: 1.2)
        XCTAssertEqual(result.x, -1)
        XCTAssertEqual(result.y, 1)
    }

    func testHugeValuesAreClamped() {
        var accumulator = ScrollAccumulator()
        let result = accumulator.add(dx: 1e12, dy: -1e12)
        XCTAssertEqual(result.x, 100_000)
        XCTAssertEqual(result.y, -100_000)
    }
}

final class PointerMathTests: XCTestCase {
    private let laptop = ScreenRect(x: 0, y: 0, width: 1512, height: 982)
    private let tv = ScreenRect(x: 1512, y: 0, width: 1920, height: 1080)

    func testPlainRelativeMove() {
        let result = PointerMath.move(from: (100, 100), dx: 12.5, dy: -3.25, displays: [laptop])
        XCTAssertEqual(result.x, 112.5)
        XCTAssertEqual(result.y, 96.75)
    }

    func testClampedToTheDisplayEdges() {
        var result = PointerMath.move(from: (5, 5), dx: -50, dy: -50, displays: [laptop])
        XCTAssertEqual(result.x, 0)
        XCTAssertEqual(result.y, 0)
        result = PointerMath.move(from: (1500, 970), dx: 500, dy: 500, displays: [laptop])
        XCTAssertEqual(result.x, 1511)
        XCTAssertEqual(result.y, 981)
    }

    func testCursorCanCrossToTheTV() {
        let result = PointerMath.move(from: (1500, 500), dx: 100, dy: 0, displays: [laptop, tv])
        XCTAssertEqual(result.x, 1600)
        XCTAssertEqual(result.y, 500)
    }

    func testMoveIntoTheVoidStaysOnTheStartingDisplay() {
        // Below the laptop panel but beside the taller TV: not on any display.
        let result = PointerMath.move(from: (700, 970), dx: 0, dy: 80, displays: [laptop, tv])
        XCTAssertEqual(result.x, 700)
        XCTAssertEqual(result.y, 981)
    }

    func testAbsurdDeltasAreBounded() {
        let result = PointerMath.move(from: (10, 10), dx: 1e300, dy: -1e300, displays: [laptop, tv])
        XCTAssertTrue(laptop.contains(x: result.x, y: result.y) || tv.contains(x: result.x, y: result.y))
    }

    func testNoDisplaysMeansNoClamping() {
        let result = PointerMath.move(from: (10, 10), dx: 5, dy: 5, displays: [])
        XCTAssertEqual(result.x, 15)
        XCTAssertEqual(result.y, 15)
    }
}
