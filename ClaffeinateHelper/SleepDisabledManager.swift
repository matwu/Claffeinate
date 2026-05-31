import Foundation
import IOKit
import IOKit.pwr_mgt
// IOPMSetSystemPowerSetting is declared in ClaffeinateHelper-Bridging-Header.h
// (private IOKit SPI, no public header). HelperConstants / HelperProtocol are
// compiled directly into this target — no module import needed.

/// Owns the privileged `SleepDisabled` write and the watchdog that guarantees
/// it is restored even if the app dies (spec AC-22 / AC-23, design ADR-T7).
///
/// All state is funnelled through a single serial queue, so the class is safe
/// to call from arbitrary XPC connection threads (`@unchecked Sendable`).
final class SleepDisabledManager: @unchecked Sendable {

    private let queue = DispatchQueue(label: "\(HelperConstants.machServiceName).state")
    private var watchdog: DispatchSourceTimer?

    /// Last value we successfully wrote. Reported back via `currentState`.
    private var disabled = false

    /// `pmset disablesleep` writes this exact system power setting.
    private let key = "SleepDisabled" as CFString

    // MARK: - Public API (thread-safe)

    /// Apply `SleepDisabled = on`. Arms the watchdog while on, cancels it while
    /// off. Returns whether the privileged write succeeded.
    func setDisableSleep(_ on: Bool) -> Bool {
        queue.sync {
            if on {
                let ok = write(true)
                if ok { armWatchdog() }
                return ok
            } else {
                cancelWatchdog()
                return turnOff()
            }
        }
    }

    /// Heartbeat from the app: re-arm the watchdog so it doesn't trip while the
    /// app is healthy (spec AC-21).
    func ping() {
        queue.sync {
            if disabled { armWatchdog() }
        }
    }

    func currentState() -> Bool {
        queue.sync { disabled }
    }

    /// Clear any residual `SleepDisabled` left over from a previous crash. Run
    /// once at daemon startup (spec AC-23).
    func resetOnStartup() {
        queue.sync {
            cancelWatchdog()
            _ = write(false)
        }
    }

    // MARK: - Private (must run on `queue`)

    /// Clear `SleepDisabled`, then — if the lid is shut right now — trigger
    /// sleep ourselves. macOS evaluates "lid closed → sleep" only at the moment
    /// the lid moves; while we held the assertion it vetoed that sleep, and
    /// simply writing `SleepDisabled=false` afterwards does **not** make it
    /// re-evaluate. So with the lid still closed the Mac would stay awake (music
    /// keeps playing) until the next lid event. Forcing sleep here is what makes
    /// Decaf honour the user's "sleep when the lid is closed" setting on the spot.
    @discardableResult
    private func turnOff() -> Bool {
        let ok = write(false)
        if ok && isLidClosed() { requestSleep() }
        return ok
    }

    /// True when the built-in display lid is shut (`AppleClamshellState`).
    private func isLidClosed() -> Bool {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOPMrootDomain")
        guard entry != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(entry) }
        guard let prop = IORegistryEntryCreateCFProperty(
            entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return false }
        return (prop as? Bool) ?? false
    }

    /// Force the system to sleep now (root-only; equivalent to `pmset sleepnow`).
    private func requestSleep() {
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        guard port != IO_OBJECT_NULL else {
            NSLog("Claffeinate helper: IOPMFindPowerManagement failed; cannot sleep")
            return
        }
        defer { IOServiceClose(port) }
        let result = IOPMSleepSystem(port)
        if result != kIOReturnSuccess {
            NSLog("Claffeinate helper: IOPMSleepSystem failed (0x%08x)", result)
        }
    }

    @discardableResult
    private func write(_ on: Bool) -> Bool {
        let value: CFTypeRef = on ? kCFBooleanTrue : kCFBooleanFalse
        let result = IOPMSetSystemPowerSetting(key, value)
        let ok = (result == kIOReturnSuccess)
        if ok {
            disabled = on
        } else {
            NSLog("Claffeinate helper: IOPMSetSystemPowerSetting failed (0x%08x)", result)
        }
        return ok
    }

    private func armWatchdog() {
        cancelWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + HelperConstants.watchdogTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            NSLog("Claffeinate helper: watchdog fired — restoring SleepDisabled=false")
            self.cancelWatchdog()
            _ = self.turnOff()
        }
        timer.resume()
        watchdog = timer
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }
}
