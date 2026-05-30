import Foundation
import Combine

/// Single source of truth for the app's observable state.
///
/// State is held here as passive data and is never mixed: detection
/// (`isClaudeRunning`), prevention (`isSleepAssertionActive`) and monitoring
/// (`isMonitoringPaused`) are independent facts. `ProcessMonitor` updates
/// them; `MenuContent` renders them.
@MainActor
final class AppState: ObservableObject {
    /// Whether the most recent scan detected a Claude process at all
    /// (presence — the process exists). Drives the "Detected" status line.
    @Published var isClaudeRunning = false

    /// Whether Claude is actively *processing* — its process subtree showed CPU
    /// activity recently (within the idle grace period). This, not mere
    /// presence, is what drives sleep prevention (spec AC-5a, AC-9).
    @Published var isClaudeActive = false

    /// Whether a sleep-prevention assertion is currently held.
    @Published var isSleepAssertionActive = false

    /// Whether monitoring is paused by the user.
    @Published var isMonitoringPaused = false

    /// "PID <pid> <name>" of the last detected process, or nil.
    @Published var lastDetectedProcess: String?

    /// When Claude was last observed actively processing (the activity sampler's
    /// `lastActiveAt`). Drives the "Last activity: N min ago" status line.
    /// nil when Claude isn't running or no activity has been seen yet.
    @Published var lastActivityAt: Date?

    /// Whether the XPC connection to the privileged helper is up. Sleep
    /// prevention (lid-close) is only real while this is true (spec AC-12b).
    @Published var isHelperConnected = false

    /// User-chosen idle grace period in minutes (spec AC-4a). Persisted to
    /// `UserDefaults` so the choice survives restarts. Loaded on init; written
    /// back on every change.
    @Published var gracePeriodMinutes: Int {
        didSet {
            UserDefaults.standard.set(gracePeriodMinutes, forKey: Constants.gracePeriodDefaultsKey)
        }
    }

    init() {
        // Load the persisted grace period, falling back to the default when
        // unset (UserDefaults returns 0 for a missing integer key).
        let stored = UserDefaults.standard.integer(forKey: Constants.gracePeriodDefaultsKey)
        self.gracePeriodMinutes = stored > 0
            ? stored
            : Int(Constants.defaultActivityGracePeriod / 60)
    }

    /// The configured idle grace period as a `TimeInterval` (seconds).
    var gracePeriod: TimeInterval { TimeInterval(gracePeriodMinutes) * 60 }
}
