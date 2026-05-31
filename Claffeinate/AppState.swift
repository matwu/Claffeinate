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

    /// The resolved activity state — `.busy` (keep awake), `.needsAttention`
    /// (Claude is waiting for the user; sleep is allowed but flagged) or `.idle`.
    /// Resolved from hooks → transcript, in that priority (spec AC-5a).
    @Published var activityState: ActivityState = .idle

    /// Why we're in the current state (`hook · turn`, `transcript`, …), shown so
    /// "awake" is never a mystery. nil when idle.
    @Published var activityReason: ActivityReason?

    /// When the current turn began (hook turn start), for the "for 12s" elapsed
    /// readout. nil when idle / unknown / transcript-only.
    @Published var activitySince: Date?

    /// Whether Claude Code hooks are reporting to us. When false we're on the
    /// transcript fallback, and the UI nudges the user to install hooks.
    @Published var hooksActive = false

    /// Whether a sleep-prevention assertion is currently held.
    @Published var isSleepAssertionActive = false

    /// Whether monitoring is paused by the user.
    @Published var isMonitoringPaused = false

    /// "PID <pid> <name>" of the last detected process, or nil.
    @Published var lastDetectedProcess: String?

    /// How many Claude root sessions are currently running (presence). Lets the
    /// UI explain *why* the Mac is awake when several sessions exist.
    @Published var runningSessionCount = 0

    /// Whether any running session is a headless `--enable-auto-mode` agent —
    /// surfaces the common surprise of a background agent keeping the Mac awake.
    @Published var hasAutoModeSession = false

    /// Whether the XPC connection to the privileged helper is up. Sleep
    /// prevention (lid-close) is only real while this is true (spec AC-12b).
    @Published var isHelperConnected = false

    /// Convenience for the sleep-prevention path: only `.busy` holds the Mac
    /// awake (`.needsAttention` does not — the user has stepped away).
    var isClaudeActive: Bool { activityState == .busy }

    /// User-chosen idle grace period in minutes — how long a Claude work lease
    /// keeps the Mac awake after its last hook event when the closing hook never
    /// fires. Floored at `Constants.minGracePeriodMinutes`. Persisted so the
    /// headless hook binary (same defaults domain) reads it at lease-write time.
    @Published var gracePeriodMinutes: Int {
        didSet {
            UserDefaults.standard.set(gracePeriodMinutes, forKey: Constants.gracePeriodDefaultsKey)
        }
    }

    init() {
        // Load the persisted grace period, falling back to the default (and
        // honouring the floor) when nothing valid is stored yet.
        let stored = UserDefaults.standard.integer(forKey: Constants.gracePeriodDefaultsKey)
        self.gracePeriodMinutes = stored > 0
            ? max(stored, Constants.minGracePeriodMinutes)
            : Constants.defaultGracePeriodMinutes
    }
}
