import Foundation
import Darwin

/// Headless mode: when the app binary is invoked as a Claude Code hook
/// (`Claffeinate --claffeinate-hook <EventName>`), it never starts the UI — it
/// reads the hook's JSON from stdin, updates the lease files, and exits. This is
/// the authoritative "is Claude working" signal; everything else is a fallback.
///
/// Hooks run on Claude's critical path, so this path must stay cheap: no AppKit,
/// a single sysctl walk to find the owning Claude PID, one small file write.
enum HookMode {
    /// Entry hook from `main`. Returns true if this was a hook invocation (the
    /// caller must then exit without starting the UI).
    static func handleIfNeeded(_ arguments: [String]) -> Bool {
        guard let flagIndex = arguments.firstIndex(of: Constants.hookModeFlag) else {
            return false
        }
        let event = flagIndex + 1 < arguments.count ? arguments[flagIndex + 1] : ""
        run(event: event, stdin: readStdin())
        return true
    }

    // MARK: - Core

    static func run(event: String, stdin: [String: Any]) {
        let sessionId = (stdin["session_id"] as? String) ?? ""
        guard !sessionId.isEmpty else { return }   // nothing to key a lease on
        let transcript = stdin["transcript_path"] as? String
        let cwd = stdin["cwd"] as? String
        let pid = owningClaudePID()

        // Every event (except the session ending) refreshes the coverage marker,
        // so this session's PID stays known as "hook-reporting" — that's what
        // lets the CPU/transcript fallback stand down for it while it's idle.
        if event != "SessionEnd" {
            write(.session, sessionId, transcript, cwd, pid, Constants.sessionLeaseTTL)
        }

        switch event {
        case "SessionStart":
            break   // coverage marker above is the whole job
        case "UserPromptSubmit":
            write(.turn, sessionId, transcript, cwd, pid, Constants.turnLeaseTTL)
        case "PreToolUse":
            // A tool is starting: claim the tool, and keep the turn alive (a
            // tool-heavy turn must not let the turn lease lapse).
            write(.tool, sessionId, transcript, cwd, pid, Constants.toolLeaseTTL)
            refreshTurn(sessionId, transcript, cwd, pid)
        case "PostToolUse":
            remove(.tool, sessionId)
        case "SubagentStart":
            write(.subagent, sessionId, transcript, cwd, pid, Constants.subagentLeaseTTL)
        case "SubagentStop":
            remove(.subagent, sessionId)
        case "Notification":
            write(.attention, sessionId, transcript, cwd, pid, Constants.attentionLeaseTTL)
        case "Stop":
            // The main turn finished: drop all work leases (a fresh prompt opens
            // a new turn). Leave nothing holding the Mac awake.
            remove(.turn, sessionId); remove(.tool, sessionId)
            remove(.subagent, sessionId); remove(.attention, sessionId)
        case "SessionEnd":
            for kind in LeaseKind.allCases { remove(kind, sessionId) }
        default:
            break
        }
    }

    // MARK: - Lease file I/O

    private static func write(
        _ kind: LeaseKind, _ sessionId: String, _ transcript: String?,
        _ cwd: String?, _ pid: Int32?, _ ttl: TimeInterval
    ) {
        ensureDirectory()
        let now = Date().timeIntervalSince1970
        let lease = ActivityLease(
            kind: kind, sessionId: sessionId, transcriptPath: transcript,
            cwd: cwd, claudePid: pid, startedAt: now, expiresAt: now + ttl)
        guard let data = try? JSONEncoder().encode(lease) else { return }
        try? data.write(to: LeasePaths.file(sessionId: sessionId, kind: kind), options: .atomic)
    }

    /// Extend the turn lease's expiry while preserving its original start time,
    /// so "busy for Ns" reflects the whole turn, not the latest tool.
    private static func refreshTurn(
        _ sessionId: String, _ transcript: String?, _ cwd: String?, _ pid: Int32?
    ) {
        let url = LeasePaths.file(sessionId: sessionId, kind: .turn)
        let now = Date().timeIntervalSince1970
        let started = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(ActivityLease.self, from: $0) }?
            .startedAt ?? now
        ensureDirectory()
        let lease = ActivityLease(
            kind: .turn, sessionId: sessionId, transcriptPath: transcript,
            cwd: cwd, claudePid: pid, startedAt: started, expiresAt: now + Constants.turnLeaseTTL)
        if let data = try? JSONEncoder().encode(lease) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func remove(_ kind: LeaseKind, _ sessionId: String) {
        try? FileManager.default.removeItem(
            at: LeasePaths.file(sessionId: sessionId, kind: kind))
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: LeasePaths.directory, withIntermediateDirectories: true)
    }

    // MARK: - Stdin

    private static func readStdin() -> [String: Any] {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    // MARK: - Owning Claude PID

    /// Shell / wrapper executables Claude Code interposes between itself and a
    /// hook command — skipped when locating the owning session.
    private static let shellComms: Set<String> = [
        "sh", "zsh", "bash", "dash", "fish", "ksh", "tcsh", "csh", "login", "env",
    ]

    /// Walk up the process tree from this hook process to the Claude session that
    /// spawned it (Claude → shell → us), so the lease can be invalidated the
    /// instant Claude dies.
    ///
    /// We can't rely on the ancestor's `comm` containing "claude": the real CLI
    /// often reports a version string (e.g. `2.1.157`) as its process name. So we
    /// take the **first non-shell ancestor** — the process that ran our command,
    /// which is Claude — preferring an explicit `claude`/`node` match if we see
    /// one. Returns nil only if the whole walk is shells (then the lease relies on
    /// its TTL and the Stop/SessionEnd hooks).
    private static func owningClaudePID() -> Int32? {
        var pid = getppid()
        var firstNonShell: Int32?
        for _ in 0..<16 {
            guard pid > 1, let info = procInfo(pid) else { break }
            let comm = info.comm.lowercased()
            if comm.contains("claude") || comm == "node" { return pid }  // strongest
            let base = comm.hasPrefix("-") ? String(comm.dropFirst()) : comm
            if firstNonShell == nil, !shellComms.contains(base), base != "claffeinate" {
                firstNonShell = pid
            }
            pid = info.ppid
        }
        return firstNonShell
    }

    private static func procInfo(_ pid: Int32) -> (ppid: Int32, comm: String)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, 4, &info, &size, nil, 0)
        guard rc == 0, size > 0 else { return nil }
        let comm = withUnsafeBytes(of: &info.kp_proc.p_comm) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: Array(bytes) + [0])
        }
        return (info.kp_eproc.e_ppid, comm)
    }
}
