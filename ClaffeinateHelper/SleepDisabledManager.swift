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

    /// `IOPMrootDomain` user-client selector `kPMSetClamshellSleepState`
    /// (`IOKit/pwr_mgt/IOPMLibDefs.h`). Takes one scalar input: `1` disables
    /// lid-close (clamshell) sleep, `0` re-enables it. The kernel re-evaluates a
    /// shut lid (`kLocalEvalClamshellCommand`) the instant the bit goes 1 → 0 —
    /// see `setDisableSleep` for why that re-evaluation is the whole point.
    private let kPMSetClamshellSleepState: UInt32 = 12

    // MARK: - Public API (thread-safe)

    /// Apply `SleepDisabled = on`. Arms the watchdog while on, cancels it while
    /// off. Returns whether the privileged write succeeded.
    ///
    /// `SleepDisabled` alone *blocks* lid-close sleep, but clearing it does NOT
    /// make macOS re-evaluate a lid that is already shut — the Mac stays awake
    /// (music keeps playing) until the next physical lid event (the 0.3.3 bug).
    /// macOS only re-evaluates closed-lid sleep when the runtime clamshell-disable
    /// bit transitions 1 → 0. That bit is *separate* state from `SleepDisabled`,
    /// so we mirror it on **both** edges: set it on acquire (establishing the `1`
    /// state) and clear it on release, which fires the re-evaluation and lets a
    /// closed-lid Mac sleep on the spot. `IOPMSleepSystem` (0.3.3) was the wrong
    /// layer — it returns success without actually sleeping here.
    func setDisableSleep(_ on: Bool) -> Bool {
        queue.sync {
            if on {
                let ok = write(true)
                if ok {
                    setClamshellSleepDisabled(true)
                    armWatchdog()
                }
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
    /// once at daemon startup (spec AC-23). Also clears the runtime clamshell
    /// bit: if a crashed instance left it set and the lid is shut, this lets the
    /// Mac sleep instead of staying awake forever (at a normal boot the bit is
    /// already 0, so the call is a harmless no-op).
    func resetOnStartup() {
        queue.sync {
            cancelWatchdog()
            _ = write(false)
            setClamshellSleepDisabled(false)
        }
    }

    // MARK: - Private (must run on `queue`)

    /// Clear `SleepDisabled`, then clear the runtime clamshell-disable bit. The
    /// 1 → 0 transition is what makes macOS re-evaluate a lid that is already
    /// shut and finally sleep (see `setDisableSleep`). Order matters:
    /// `SleepDisabled` must be false first so the re-evaluation sees nothing
    /// blocking sleep. Clearing the bit while the lid is open is a no-op for
    /// sleep — the kernel only re-evaluates when the clamshell is closed — so we
    /// don't gate on lid state (and avoid depending on a possibly-stale
    /// `AppleClamshellState` read).
    @discardableResult
    private func turnOff() -> Bool {
        let ok = write(false)
        setClamshellSleepDisabled(false)
        return ok
    }

    /// Drive `kPMSetClamshellSleepState` on the `IOPMrootDomain` user client.
    /// `disable == true` blocks lid-close sleep; `false` re-enables it and makes
    /// the kernel re-evaluate a shut lid. Logs on both success and failure,
    /// including the lid snapshot, so a failed repro still yields diagnostics.
    private func setClamshellSleepDisabled(_ disable: Bool) {
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        guard port != IO_OBJECT_NULL else {
            NSLog("Claffeinate helper: IOPMFindPowerManagement failed; clamshell %@ skipped",
                  disable ? "disable" : "enable")
            return
        }
        defer { IOServiceClose(port) }
        var input: UInt64 = disable ? 1 : 0
        let result = IOConnectCallScalarMethod(port, kPMSetClamshellSleepState, &input, 1, nil, nil)
        let lid = isLidClosed() ? "closed" : "open"
        if result == kIOReturnSuccess {
            NSLog("Claffeinate helper: clamshell sleep %@ (input=%llu, lid=%@)",
                  disable ? "disabled" : "re-enabled/re-evaluated", input, lid)
        } else {
            NSLog("Claffeinate helper: kPMSetClamshellSleepState failed (0x%08x, input=%llu, lid=%@)",
                  result, input, lid)
        }
    }

    /// True when the built-in display lid is shut (`AppleClamshellState`). Used
    /// only for diagnostic logging — not as a gate on the sleep path.
    private func isLidClosed() -> Bool {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOPMrootDomain")
        guard entry != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(entry) }
        guard let prop = IORegistryEntryCreateCFProperty(
            entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return false }
        return (prop as? Bool) ?? false
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
