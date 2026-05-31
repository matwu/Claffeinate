import Foundation

/// The three states the user actually cares about. Only `.busy` keeps the Mac
/// awake; `.needsAttention` means Claude is blocked waiting for *you*, so the
/// Mac is allowed to sleep (you're away) but the menu flags it.
enum ActivityState {
    case busy
    case needsAttention
    case idle
}

/// Why we reached the current state — shown in the UI so "awake" is never a
/// mystery, and ordered by trustworthiness (hooks are exact; the transcript is a
/// best-effort fallback for sessions without hooks).
enum ActivityReason {
    case hookTurn
    case hookTool
    case hookSubagent
    case hookAttention
    case transcript

    var label: String {
        switch self {
        case .hookTurn:      return "hook · turn"
        case .hookTool:      return "hook · tool"
        case .hookSubagent:  return "hook · subagent"
        case .hookAttention: return "hook · attention"
        case .transcript:    return "transcript"
        }
    }
}

/// Resolved activity for one scan: the decision plus the bits the UI shows.
struct ResolvedActivity {
    let state: ActivityState
    let reason: ActivityReason?
    let since: Date?
    let runningRoots: Int
    let hasAutoModeSession: Bool
    /// Whether hook leases exist at all — i.e. Claude Code is reporting turns to
    /// us. When false, we're on the transcript fallback and the UI nudges the
    /// user to install hooks for precise detection.
    let hooksActive: Bool

    var isActive: Bool { state == .busy }
}

/// Combines the detection signals in priority order — **hooks > transcript** —
/// into a single decision. Hooks are authoritative when present (exact turn/tool
/// boundaries); the transcript catches model-response streaming for sessions
/// without hooks. (There is no CPU heuristic: it produced false positives from
/// idle terminal rendering, so hooks — and, failing those, transcript activity —
/// are the only signals. Install hooks for precise, gap-free coverage.)
@MainActor
final class ActivityResolver {
    private let leaseStore = LeaseStore()
    private let transcripts = TranscriptScanner()

    func resolve(
        roots: [DetectedRoot],
        livePIDs: Set<Int32>,
        now: Date = Date()
    ) -> ResolvedActivity {
        // Liveness is judged against every live PID (not just detector roots) so
        // a hook that recorded a wrapper/node PID isn't falsely treated as dead.
        let leases = leaseStore.read(now: now, livePids: livePIDs)

        func result(_ state: ActivityState, _ reason: ActivityReason?, since: Date?) -> ResolvedActivity {
            ResolvedActivity(
                state: state, reason: reason, since: since,
                runningRoots: roots.count,
                hasAutoModeSession: roots.contains(where: \.isAutoMode),
                hooksActive: leases.hooksActive)
        }

        // No Claude at all → nothing to keep awake (also avoids a stray nil-PID
        // lease lingering past its session).
        guard !roots.isEmpty else { return result(.idle, nil, since: nil) }

        // 1. A live work lease anywhere is authoritative: Claude is working.
        if leases.hasWork {
            let reason: ActivityReason =
                leases.workKinds.contains(.tool) ? .hookTool :
                leases.workKinds.contains(.subagent) ? .hookSubagent : .hookTurn
            return result(.busy, reason, since: leases.workSince)
        }

        // 2. Fallback applies only to roots NOT covered by hooks — a hook-covered
        //    idle session stays idle, while a hook-less session is judged by
        //    transcript freshness. (Hooks dominate per-session, so one session's
        //    leases can't mask or fake another's.)
        let uncoveredRootExists = roots.contains { !leases.coveredPids.contains($0.pid) }
        if uncoveredRootExists,
           transcripts.hasFreshInteractiveWrite(now: now, window: Constants.transcriptFreshWindow) {
            return result(.busy, .transcript, since: nil)
        }

        // 3. Nothing working. A hook-reported wait for the user is "needs
        //    attention" (sleep allowed); otherwise idle.
        if leases.attentionActive {
            return result(.needsAttention, .hookAttention, since: nil)
        }
        return result(.idle, nil, since: nil)
    }
}
