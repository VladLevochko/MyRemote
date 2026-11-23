import Foundation

/// Pure helpers used by the real injector, kept here so they are unit-testable
/// without touching CoreGraphics.

public enum TextTyping {
    /// One step of typing a string.
    public enum Step: Equatable, Sendable {
        /// Characters delivered through a synthetic key event's Unicode string.
        case unicode(String)
        /// A line break or tab, sent as the real key so that fields and forms react
        /// the way they do to a keyboard.
        case key(VirtualKey)
    }

    /// `CGEventKeyboardSetUnicodeString` is only reliable for short strings; 20 UTF-16
    /// code units per event is the commonly used safe limit.
    public static let defaultChunkSize = 20

    /// Splits `text` into steps. Chunks never exceed `maxUTF16Units` unless a single
    /// grapheme cluster is longer than that, and never split a grapheme cluster
    /// (so surrogate pairs, combining marks and ZWJ emoji stay intact).
    public static func steps(for text: String, maxUTF16Units: Int = defaultChunkSize) -> [Step] {
        precondition(maxUTF16Units > 0)
        var steps: [Step] = []
        var current = ""
        var currentUnits = 0

        func flush() {
            if !current.isEmpty {
                steps.append(.unicode(current))
                current = ""
                currentUnits = 0
            }
        }

        for character in text {
            // "\r\n" is a single Character in Swift.
            if character == "\n" || character == "\r" || character == "\r\n" {
                flush()
                steps.append(.key(.enter))
                continue
            }
            if character == "\t" {
                flush()
                steps.append(.key(.tab))
                continue
            }
            let units = character.utf16.count
            if currentUnits + units > maxUTF16Units {
                flush()
            }
            current.append(character)
            currentUnits += units
        }
        flush()
        return steps
    }
}

/// Carries the fractional part of scroll deltas between events, because the system
/// scroll event takes whole pixels.
public struct ScrollAccumulator: Sendable {
    private var remainderX = 0.0
    private var remainderY = 0.0

    public init() {}

    /// Returns the whole pixels to emit now for the given fractional deltas.
    public mutating func add(dx: Double, dy: Double) -> (x: Int32, y: Int32) {
        remainderX += dx
        remainderY += dy
        let wholeX = remainderX.rounded(.towardZero)
        let wholeY = remainderY.rounded(.towardZero)
        remainderX -= wholeX
        remainderY -= wholeY
        return (Self.clampToInt32(wholeX), Self.clampToInt32(wholeY))
    }

    private static func clampToInt32(_ value: Double) -> Int32 {
        Int32(max(-100_000, min(100_000, value)))
    }
}

/// Plain rectangle/point so that pointer math is testable without CoreGraphics.
public struct ScreenRect: Equatable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }

    public func clamp(x px: Double, y py: Double) -> (x: Double, y: Double) {
        (max(x, min(x + width - 1, px)), max(y, min(y + height - 1, py)))
    }
}

public enum PointerMath {
    /// Largest single relative move that is honoured, in points.
    public static let maxDelta = 10_000.0

    /// New cursor position after a relative move. A destination on any display is
    /// accepted as is (so the cursor can cross between displays); a destination in
    /// the void is clamped to the edge of the display the cursor started on.
    public static func move(
        from current: (x: Double, y: Double), dx: Double, dy: Double, displays: [ScreenRect]
    ) -> (x: Double, y: Double) {
        let target = (
            x: current.x + max(-maxDelta, min(maxDelta, dx)),
            y: current.y + max(-maxDelta, min(maxDelta, dy))
        )
        guard !displays.isEmpty else { return target }
        if displays.contains(where: { $0.contains(x: target.x, y: target.y) }) {
            return target
        }
        let home = displays.first(where: { $0.contains(x: current.x, y: current.y) }) ?? displays[0]
        return home.clamp(x: target.x, y: target.y)
    }
}
