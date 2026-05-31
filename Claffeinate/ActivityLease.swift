import Foundation

/// What a lease represents. Work kinds (`turn`/`tool`/`subagent`) keep the Mac
/// awake; `attention` does not — it marks a session blocked waiting for the user
/// (a permission prompt), which is "needs attention", not "busy".
enum LeaseKind: String, Codable, CaseIterable {
    case turn        // a prompt is being answered (UserPromptSubmit … Stop)
    case tool        // a tool is running (PreToolUse … PostToolUse)
    case subagent    // a subagent is running (SubagentStart … SubagentStop)
    case grace       // a turn just ended; hold the Mac awake through the idle
                     // grace period (Stop … next prompt / TTL expiry)
    case attention   // Claude needs the user (Notification)
    case session     // coverage marker: this session reports via hooks at all

    /// Whether holding this lease should keep the Mac awake. `attention` (the
    /// user is needed) and `session` (a mere coverage marker) do not. `grace`
    /// does — it's the post-turn cool-down the user asked the Mac to stay awake
    /// through.
    var isWork: Bool {
        switch self {
        case .turn, .tool, .subagent, .grace: return true
        case .attention, .session:            return false
        }
    }
}

/// A short-lived claim that a Claude session is doing something. Written by the
/// hook binary mode, read by `LeaseStore`. Time-bounded (`expiresAt`) and tied
/// to the owning Claude PID so a crash/kill that skips the closing hook can't
/// leave the Mac stuck awake.
struct ActivityLease: Codable {
    let kind: LeaseKind
    let sessionId: String
    let transcriptPath: String?
    let cwd: String?
    let claudePid: Int32?
    let startedAt: Double      // epoch seconds
    let expiresAt: Double      // epoch seconds
}

/// Filesystem locations for leases, shared by the writer (hook mode) and the
/// reader (the running app) so they can't drift.
enum LeasePaths {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Constants.leaseDirectoryName, isDirectory: true)
    }

    /// One file per (session, kind). Session ids are UUIDs but we sanitise
    /// defensively so a hostile value can't escape the directory.
    static func file(sessionId: String, kind: LeaseKind) -> URL {
        let safe = sessionId.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" ? ch : "_"
        }
        return directory.appendingPathComponent("\(String(safe)).\(kind.rawValue).json")
    }
}

/// Rolled-up view of the currently-live leases, for the resolver. Coverage is
/// tracked per Claude PID so hook authority applies only to the sessions that
/// actually report — a hook-less session running alongside is never masked.
struct LeaseSummary {
    /// Live work-lease kinds (excludes `attention`/`session`; includes `grace`).
    let workKinds: Set<LeaseKind>
    /// Any live `attention` lease (a session is waiting for the user).
    let attentionActive: Bool
    /// Start time of the longest-running live *active* work lease — turn/tool/
    /// subagent only (for "busy 12s"). A post-turn `grace` lease is excluded so
    /// the elapsed readout doesn't keep climbing after the turn has ended.
    let workSince: Date?
    /// Expiry of the latest live `grace` lease (for the "winding down — awake N
    /// more min" countdown). nil when no grace lease is live.
    let graceUntil: Date?
    /// Claude PIDs that have *any* live lease — these sessions are hook-covered,
    /// so the CPU/transcript fallback must stand down for their roots.
    let coveredPids: Set<Int32>
    /// Whether any live lease exists — i.e. hooks are wired up and firing.
    let hooksActive: Bool

    static let none = LeaseSummary(
        workKinds: [], attentionActive: false, workSince: nil, graceUntil: nil,
        coveredPids: [], hooksActive: false)

    var hasWork: Bool { !workKinds.isEmpty }
}

/// Reads the lease directory and reduces it to a `LeaseSummary`, ignoring leases
/// that have expired and dropping those whose owning process is gone.
///
/// Deletion is deliberately limited to **dead-PID** leases: that session's
/// process is gone for good and its `session_id`-keyed file will never be
/// rewritten, so removing it can't race a writer. Expired-but-alive leases are
/// only *ignored* (a concurrent hook may be atomically replacing the very file
/// we'd otherwise delete — deleting it would erase the fresh lease, TOCTOU).
struct LeaseStore {
    private let decoder = JSONDecoder()

    /// - Parameters:
    ///   - now: current time.
    ///   - livePids: every PID alive this scan (the full process table). A lease
    ///     whose `claudePid` isn't among them is dead. Checking the whole table
    ///     (not just detector roots) avoids false deaths when the hook recorded a
    ///     wrapper/`node` PID the detector doesn't classify as a Claude root.
    func read(now: Date, livePids: Set<Int32>) -> LeaseSummary {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: LeasePaths.directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return .none
        }

        var workKinds: Set<LeaseKind> = []
        var attentionActive = false
        var workSince: Date?
        var graceUntil: Date?
        var coveredPids: Set<Int32> = []
        var hooksActive = false
        let nowEpoch = now.timeIntervalSince1970

        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let lease = try? decoder.decode(ActivityLease.self, from: data) else {
                continue
            }

            if let pid = lease.claudePid, !livePids.contains(pid) {
                try? fm.removeItem(at: url)   // owner gone — safe, race-free cleanup
                continue
            }
            if lease.expiresAt <= nowEpoch { continue }   // ignore, never delete here

            hooksActive = true
            if let pid = lease.claudePid { coveredPids.insert(pid) }

            switch lease.kind {
            case .turn, .tool, .subagent:
                workKinds.insert(lease.kind)
                let started = Date(timeIntervalSince1970: lease.startedAt)
                workSince = min(workSince ?? started, started)
            case .grace:
                // Counts as work (keeps the Mac awake) but feeds a countdown to
                // expiry, not the climbing "busy for Ns" elapsed time.
                workKinds.insert(.grace)
                let until = Date(timeIntervalSince1970: lease.expiresAt)
                graceUntil = max(graceUntil ?? until, until)
            case .attention:
                attentionActive = true
            case .session:
                break   // coverage only
            }
        }

        return LeaseSummary(
            workKinds: workKinds,
            attentionActive: attentionActive,
            workSince: workSince,
            graceUntil: graceUntil,
            coveredPids: coveredPids,
            hooksActive: hooksActive
        )
    }
}
