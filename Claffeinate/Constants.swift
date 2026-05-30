import Foundation

/// App-wide tunable constants. Kept in one place so behaviour can be changed
/// without touching logic (spec AC-4: the monitoring interval must be a
/// constant and adjustable in the future).
///
/// Helper-side timing (heartbeat / watchdog) and the Mach service name live in
/// `HelperConstants` so the app and the daemon can't drift apart.
enum Constants {
    /// How often the process list is scanned while monitoring is running.
    /// Default: 5 seconds.
    static let monitoringInterval: TimeInterval = 5

    /// Human-readable reason attached to the power management assertion.
    /// Shown by `pmset -g assertions`.
    static let assertionReason = "Claffeinate: Claude is running"

    /// Substring that marks a process as Claude-related.
    /// Matches `claude`, `Claude`, `claude-code` (case-insensitive), and is
    /// also looked for inside the arguments of `node` processes.
    static let claudeKeyword = "claude"

    /// Executable name of Node.js processes that may be running Claude Code.
    static let nodeExecutable = "node"

    // MARK: - Activity (processing) detection

    /// Minimum average CPU usage of the Claude process subtree, as a fraction of
    /// one core over a single `monitoringInterval`, for a scan to count as
    /// "Claude is actively processing" (spec AC-5a). Below this we treat the
    /// process as idle (e.g. sitting at the prompt waiting for input). Kept low
    /// so that even light streaming / rendering work counts; the grace period
    /// (below) is what bridges genuinely quiet model-response waits.
    static let activityCPUThreshold = 0.02

    /// Default idle grace period: how long the Claude subtree may show no CPU
    /// activity before we consider it idle and release sleep prevention. A
    /// generous default (30 min) so a long, locally-quiet model-response wait
    /// never lets the Mac sleep mid-task (spec §7 — false sleep is the worst
    /// case). User-adjustable from the menu (spec AC-4a).
    static let defaultActivityGracePeriod: TimeInterval = 30 * 60

    /// Selectable idle grace periods (minutes) offered in the menu (spec AC-4a).
    static let gracePeriodPresetsMinutes: [Int] = [5, 10, 15, 30, 60, 120]

    /// `UserDefaults` key the chosen idle grace period (in minutes) persists to,
    /// so the user's choice survives restarts (spec AC-4a).
    static let gracePeriodDefaultsKey = "activityGracePeriodMinutes"
}
