import Foundation

/// A matched Claude **root** process. Activity is judged per root, so one busy
/// session can't be masked by idle ones and vice-versa.
struct DetectedRoot {
    let pid: Int32
    /// "<name>" of the matched executable (e.g. `claude`, `node (claude)`).
    let label: String
    /// Whether this is a headless `--enable-auto-mode` session. Surfaced in the
    /// UI so a long-running background agent isn't mistaken for "nothing".
    let isAutoMode: Bool
}

/// Result of a single detection pass.
struct DetectionResult {
    /// Whether any Claude-related process is currently running (presence).
    let isRunning: Bool
    /// "PID <pid> <name>" of the first matching process, or nil if none.
    let process: String?
    /// The matched Claude root processes (with per-root metadata).
    let roots: [DetectedRoot]
    /// Every PID seen this scan — the resolver uses it to expire a hook lease
    /// the instant its owning process is gone.
    let livePIDs: Set<Int32>
}

/// Detects whether Claude / Claude Code is running by inspecting the process
/// list. Stateless and side-effect free: it only reads, never touches the
/// processes it observes (Constitution §3.6).
struct ClaudeDetector {

    /// Scan running processes once and report whether Claude is detected.
    ///
    /// Detection rules (spec AC-5, AC-6, AC-8):
    ///  1. A process whose executable name contains "claude" (covers `claude`,
    ///     `Claude`, `claude-code`, case-insensitive).
    ///  2. A `node` process whose command line contains "claude".
    ///  3. This app's own process is always excluded.
    ///
    /// Returns the matched roots and the set of all live PIDs (used to expire
    /// hook leases whose owning process has gone). A pure, stateless scan.
    func detect() -> DetectionResult {
        let ownPID = ProcessInfo.processInfo.processIdentifier

        guard let output = runPS() else {
            // If `ps` cannot be run we report "not detected" so we fail safe by
            // releasing any assertion rather than holding it indefinitely.
            return DetectionResult(isRunning: false, process: nil, roots: [], livePIDs: [])
        }

        var livePIDs: Set<Int32> = []
        var roots: [DetectedRoot] = []
        var firstProcess: String?

        for line in output.split(separator: "\n") {
            // Columns (no headers): "<pid> <comm> <args...>". pid has no spaces
            // and comes first; comm has no spaces; args may.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let (pid, args) = parseRow(trimmed) else { continue }
            livePIDs.insert(pid)   // record every PID (incl. our own) for liveness

            guard pid != ownPID else { continue }

            // Match on `args` (the full command line), never `comm`: macOS
            // truncates the `comm` column to 16 chars, mangling any real path.
            // `args` keeps the full argv, so argv[0] is the genuine exe path.
            if let label = match(args: args) {
                let isAutoMode = args.lowercased().contains("--enable-auto-mode")
                roots.append(DetectedRoot(pid: pid, label: label, isAutoMode: isAutoMode))
                if firstProcess == nil { firstProcess = "PID \(pid) \(label)" }
            }
        }

        return DetectionResult(
            isRunning: !roots.isEmpty,
            process: firstProcess,
            roots: roots,
            livePIDs: livePIDs
        )
    }

    // MARK: - Parsing

    /// Split a `ps` row into `(pid, args)`. Returns nil for unparseable rows.
    private func parseRow(_ row: String) -> (Int32, String)? {
        // pid
        guard let pidEnd = row.firstIndex(of: " ") else { return nil }
        guard let pid = Int32(row[..<pidEnd]) else { return nil }

        // comm (single token) then args (remainder).
        let afterPid = row[row.index(after: pidEnd)...].drop { $0 == " " }
        guard let commEnd = afterPid.firstIndex(of: " ") else {
            return (pid, "")   // no args column (rare): only comm present
        }
        let args = String(afterPid[afterPid.index(after: commEnd)...])
        return (pid, args)
    }

    /// Apply the detection rules to a process's full command line (`args`).
    /// Returns the short executable label (e.g. `claude`, `node (claude)`) if it
    /// matches Claude Code, else nil. The caller prefixes the PID for display.
    ///
    /// Scope is Claude **Code** (the CLI), deliberately *not* the desktop
    /// Claude.app: a GUI Electron app renders constantly, so its subtree never
    /// looks idle and would pin sleep prevention on forever. We therefore skip
    /// anything whose executable lives inside a `.app` bundle.
    private func match(args: String) -> String? {
        // argv[0] is the genuine executable path (see the call site on why we
        // use `args`, not the 16-char-truncated `comm`).
        let tokens = args.split(separator: " ")
        guard let argv0 = tokens.first else { return nil }
        let exePath = String(argv0).lowercased()

        // Exclude GUI app bundles (desktop Claude.app and its `Claude Helper`
        // Electron children). Their constant rendering CPU is what made the
        // activity sampler read "active" forever.
        if exePath.contains(".app/") { return nil }

        let exeName = (exePath as NSString).lastPathComponent
        let keyword = Constants.claudeKeyword

        // Rule 1: the CLI binary — executable name contains "claude" (covers
        // `claude`, `claude-code`). `.app` helpers were already excluded above.
        if exeName.contains(keyword) {
            return exeName
        }

        // Rule 2: a node process running the Claude Code script. Match a later
        // path *token* whose file name is `claude` / `claude-code` — not a bare
        // "claude" substring, which would also hit `.claude/…` config paths
        // (e.g. the claude-mem MCP server) and falsely flag them as Claude.
        if exeName == Constants.nodeExecutable {
            let runsClaude = tokens.dropFirst().contains { token in
                let name = (String(token) as NSString).lastPathComponent.lowercased()
                return name == keyword || name.contains("claude-code")
            }
            if runsClaude { return "node (claude)" }
        }

        return nil
    }

    /// Run `/bin/ps -axo pid=,comm=,args=` and return its stdout.
    private func runPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -a all users' processes, -x include those without a controlling tty.
        // `=` suffix on each column suppresses headers. comm is parsed past but
        // unused (args carries the full, untruncated command line).
        process.arguments = ["-axo", "pid=,comm=,args="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return String(data: data, encoding: .utf8)
    }
}
