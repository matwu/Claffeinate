import Foundation

/// App-wide tunable constants. Kept in one place so behaviour can be changed
/// without touching logic (spec AC-4: the monitoring interval must be a
/// constant and adjustable in the future).
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
}
