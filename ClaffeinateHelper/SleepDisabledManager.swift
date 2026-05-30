import Foundation
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
                return write(false)
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
            _ = self.write(false)
        }
        timer.resume()
        watchdog = timer
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }
}
