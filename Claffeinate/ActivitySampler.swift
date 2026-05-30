import Foundation

/// Decides whether the detected Claude process is actually *processing* (vs.
/// just sitting idle at the prompt) by measuring the CPU time its process
/// subtree burns between scans (spec AC-5a).
///
/// Stateful by design — it must remember the previous scan's cumulative CPU
/// times to compute a per-interval delta, and the last time activity was seen
/// to apply the idle grace period. `ProcessMonitor` owns the single instance
/// and calls `sample(...)` once per tick.
///
/// Why a grace period: while Claude waits on a model response the *local*
/// process can be near-idle (no tool running, just network I/O). Releasing
/// sleep prevention then would let the Mac sleep mid-task — the worst case
/// (spec §7). So once we see activity we keep reporting "active" until the
/// subtree has been quiet for the whole grace period.
@MainActor
final class ActivitySampler {
    /// Cumulative CPU seconds per PID, captured on the previous scan.
    private var previous: [Int32: Double] = [:]
    /// When activity was last observed (CPU over threshold, or first sighting).
    /// Exposed read-only so the UI can show "time since Claude's last activity".
    /// nil when no activity has been seen since the last reset / Claude exit.
    private(set) var lastActiveAt: Date?

    /// Report whether the Claude subtree is currently active.
    ///
    /// - Parameters:
    ///   - rootPIDs: matched Claude root processes (from `ClaudeDetector`).
    ///   - table: the full process table for this scan.
    ///   - gracePeriod: how long the subtree may stay quiet before it counts as
    ///     idle (user-configurable, spec AC-4a).
    ///   - now: current time (injectable for testing).
    /// - Returns: true while Claude is processing or within the grace period of
    ///   its last activity.
    func sample(
        rootPIDs: [Int32],
        table: [Int32: ProcessSample],
        gracePeriod: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        // No Claude at all: clear state so the next sighting starts fresh.
        guard !rootPIDs.isEmpty else {
            previous = [:]
            lastActiveAt = nil
            return false
        }

        let subtree = subtreePIDs(roots: rootPIDs, table: table)

        // Sum the CPU-time delta over the subtree, but only for PIDs we also saw
        // last scan — otherwise a brand-new child's whole-lifetime CPU would
        // look like a one-interval spike. Snapshot current totals for next time.
        var deltaSeconds = 0.0
        var snapshot: [Int32: Double] = [:]
        var hasBaseline = false
        for pid in subtree {
            guard let sample = table[pid] else { continue }
            snapshot[pid] = sample.cpuSeconds
            if let prior = previous[pid] {
                hasBaseline = true
                let delta = sample.cpuSeconds - prior
                if delta > 0 { deltaSeconds += delta }
            }
        }
        previous = snapshot

        // First scan after Claude (re)appeared: no baseline to diff against.
        // Treat as active and start the grace clock — fail safe toward awake.
        guard hasBaseline else {
            lastActiveAt = now
            return true
        }

        let cpuFraction = deltaSeconds / Constants.monitoringInterval
        if cpuFraction >= Constants.activityCPUThreshold {
            lastActiveAt = now
            return true
        }

        // Quiet this scan: stay active while still inside the grace period so a
        // locally-idle model-response wait doesn't trigger sleep.
        if let last = lastActiveAt, now.timeIntervalSince(last) < gracePeriod {
            return true
        }
        return false
    }

    /// Reset all sampling state. Called when monitoring pauses so a later resume
    /// re-establishes a fresh baseline (spec AC-13/AC-14).
    func reset() {
        previous = [:]
        lastActiveAt = nil
    }

    // MARK: - Private

    /// All PIDs in the roots' subtrees (roots + every descendant), so tool
    /// subprocesses Claude spawns (builds, tests, greps) count as its activity.
    private func subtreePIDs(roots: [Int32], table: [Int32: ProcessSample]) -> Set<Int32> {
        // children[ppid] = [child pids]
        var children: [Int32: [Int32]] = [:]
        for sample in table.values {
            children[sample.ppid, default: []].append(sample.pid)
        }

        var result = Set<Int32>()
        var stack = roots
        while let pid = stack.popLast() {
            guard result.insert(pid).inserted else { continue }
            if let kids = children[pid] { stack.append(contentsOf: kids) }
        }
        return result
    }
}
