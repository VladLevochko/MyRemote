import Foundation
import IOKit.pwr_mgt

/// Something that can keep the display awake; a protocol so tests can count calls.
public protocol DisplaySleepPreventing: AnyObject {
    /// Idempotent in both directions.
    func setActive(_ active: Bool)
}

/// Prevents display sleep (and with it idle system sleep) while held. Used while at
/// least one authenticated client is connected, so the TV does not go dark in the
/// middle of a film just because nobody touched the Mac.
public final class PowerAssertion: DisplaySleepPreventing {
    private let reason: String
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    public init(reason: String = "MyRemote: a remote control is connected") {
        self.reason = reason
    }

    deinit {
        setActive(false)
    }

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assertionID != IOPMAssertionID(kIOPMNullAssertionID)
    }

    public func setActive(_ active: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let held = assertionID != IOPMAssertionID(kIOPMNullAssertionID)
        if active, !held {
            var id = IOPMAssertionID(kIOPMNullAssertionID)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id)
            if result == kIOReturnSuccess {
                assertionID = id
            } else {
                Log.error("could not create the display-sleep assertion (IOReturn \(result))")
            }
        } else if !active, held {
            IOPMAssertionRelease(assertionID)
            assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        }
    }
}
