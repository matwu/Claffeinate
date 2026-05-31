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

    // MARK: - Activity leases (hook-driven detection)
    //
    // The authoritative "is Claude working" signal comes from Claude Code's own
    // hooks (a turn/tool boundary is exact). Each hook invocation writes a
    // short-lived *lease* file; the app treats Claude as busy while any lease is
    // live (and its owning process is still alive). Transcript freshness is the
    // only fallback, for sessions without hooks.

    /// Directory (under the user's home) holding one file per active lease.
    /// Written by the `--claffeinate-hook` binary mode, read by `LeaseStore`.
    static let leaseDirectoryName = ".claffeinate/leases"

    /// Per-kind lease lifetimes (seconds). A lease is ignored once expired even
    /// if its closing hook (Stop/PostToolUse) never fired — the TTL plus the
    /// owning-PID liveness check make stale leases self-healing.
    ///
    /// Work-lease TTLs are floored at **10 minutes** so a single quiet stretch
    /// during a turn (e.g. a long silent build between `PreToolUse` and
    /// `PostToolUse`) keeps the Mac awake even with no intervening hook. Cleanup
    /// is normally immediate (the closing hook removes the lease) and crash-safe
    /// (PID death drops it); the TTL only bounds the rare "alive but closing hook
    /// skipped" case, e.g. a Ctrl-C interrupt where `Stop` doesn't fire.
    static let turnLeaseTTL: TimeInterval = 600        // UserPromptSubmit … Stop
    static let toolLeaseTTL: TimeInterval = 600        // PreToolUse … PostToolUse
    static let subagentLeaseTTL: TimeInterval = 600    // SubagentStart … SubagentStop
    static let attentionLeaseTTL: TimeInterval = 300   // Notification (needs input)
    /// Coverage marker: marks a session's PID as hook-reporting so the fallback
    /// stands down for it even while idle. Long-lived (the owning-PID liveness
    /// check and SessionEnd retire it); refreshed by every hook event.
    static let sessionLeaseTTL: TimeInterval = 24 * 60 * 60

    /// CLI flag that switches the app binary into headless hook-writer mode
    /// before any UI starts. Invoked by the installed Claude Code hooks.
    static let hookModeFlag = "--claffeinate-hook"

    // MARK: - Transcript fallback

    /// A session transcript written within this window counts as "a turn is
    /// progressing" when no hook lease exists. Kept tight: it's positive
    /// evidence only (a long local tool run writes nothing, so CPU bridges).
    static let transcriptFreshWindow: TimeInterval = 20

    /// Path fragments marking a transcript as background (claude-mem observers,
    /// etc.) rather than an interactive session — excluded from the fallback.
    static let backgroundTranscriptMarkers = ["observer", "claude-mem"]

    // MARK: - Updates

    /// GitHub repository ("owner/name") the on-demand update check queries.
    static let githubRepo = "matwu/Claffeinate"

    /// GitHub API endpoint for the latest published (non-draft, non-prerelease)
    /// release. Returns 404 when no release has been published yet.
    static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/latest")!

    /// Human-facing Releases page, opened when an update is available.
    static let releasesPageURL = URL(string: "https://github.com/\(githubRepo)/releases")!
}
