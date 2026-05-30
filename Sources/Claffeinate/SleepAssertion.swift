import Foundation
import IOKit.pwr_mgt

/// Thin wrapper around the macOS Power Management Assertion API.
///
/// Prevents *idle system sleep* while held — the standard, sudo-free way to
/// keep the Mac awake (the same mechanism the `caffeinate` command uses).
/// Display sleep is intentionally NOT prevented (design ADR-T2).
///
/// acquire()/release() are idempotent so the caller can reconcile freely
/// without tracking the underlying state itself (spec AC-12).
final class SleepAssertion {

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)

    /// True while a sleep-prevention assertion is held.
    private(set) var isActive = false

    /// Create the assertion if not already held.
    func acquire() {
        guard !isActive else { return }

        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Constants.assertionReason as CFString,
            &id
        )

        if result == kIOReturnSuccess {
            assertionID = id
            isActive = true
        }
    }

    /// Release the assertion if currently held.
    func release() {
        guard isActive else { return }

        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isActive = false
    }
}
