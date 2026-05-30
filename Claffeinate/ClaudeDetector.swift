import Foundation

/// One process row from the scan: the parent link and cumulative CPU time used
/// to walk the Claude subtree and measure its activity (spec AC-5a).
struct ProcessSample {
    let pid: Int32
    let ppid: Int32
    /// Cumulative CPU time the process has used since it started, in seconds.
    let cpuSeconds: Double
}

/// Result of a single detection pass.
struct DetectionResult {
    /// Whether any Claude-related process is currently running (presence).
    let isRunning: Bool
    /// "PID <pid> <name>" of the first matching process, or nil if none.
    let process: String?
    /// PIDs of the matched Claude root processes. Their subtree's CPU activity
    /// decides whether Claude is actively processing (spec AC-5a).
    let rootPIDs: [Int32]
    /// Every observed process, keyed by PID, so the activity sampler can walk
    /// each root's descendants (tool subprocesses: builds, tests, greps).
    let table: [Int32: ProcessSample]
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
    /// Also returns the matched root PIDs and the full process table so the
    /// caller can measure whether the Claude subtree is actively using CPU
    /// (spec AC-5a). Presence and activity are kept separate: this remains a
    /// pure, stateless scan; the activity judgement lives in `ActivitySampler`.
    func detect() -> DetectionResult {
        let ownPID = ProcessInfo.processInfo.processIdentifier

        guard let output = runPS() else {
            // If `ps` cannot be run we report "not detected" so we fail safe by
            // releasing any assertion rather than holding it indefinitely.
            return DetectionResult(isRunning: false, process: nil, rootPIDs: [], table: [:])
        }

        var table: [Int32: ProcessSample] = [:]
        var rootPIDs: [Int32] = []
        var firstProcess: String?

        for line in output.split(separator: "\n") {
            // Columns (no headers): "<pid> <ppid> <cputime> <comm> <args...>".
            // pid/ppid/cputime have no spaces and come first; comm has no
            // spaces; args may. We parse the three leading numeric-ish columns,
            // then comm, then the remainder as args.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let (pid, ppid, cpuSeconds, comm, args) = parseRow(trimmed) else { continue }

            // Record every row (including our own) so subtree walks are complete.
            table[pid] = ProcessSample(pid: pid, ppid: ppid, cpuSeconds: cpuSeconds)

            guard pid != ownPID else { continue }

            if let label = match(comm: comm, args: args, pid: pid) {
                rootPIDs.append(pid)
                if firstProcess == nil { firstProcess = label }
            }
        }

        return DetectionResult(
            isRunning: !rootPIDs.isEmpty,
            process: firstProcess,
            rootPIDs: rootPIDs,
            table: table
        )
    }

    // MARK: - Parsing

    /// Split a `ps` row into `(pid, ppid, cpuSeconds, comm, args)`.
    /// Returns nil for rows we can't parse (treated as "not Claude").
    private func parseRow(_ row: String) -> (Int32, Int32, Double, String, String)? {
        // pid
        guard let pidEnd = row.firstIndex(of: " ") else { return nil }
        guard let pid = Int32(row[..<pidEnd]) else { return nil }

        let afterPid = row[row.index(after: pidEnd)...].drop { $0 == " " }
        // ppid
        guard let ppidEnd = afterPid.firstIndex(of: " ") else { return nil }
        guard let ppid = Int32(afterPid[..<ppidEnd]) else { return nil }

        let afterPpid = afterPid[afterPid.index(after: ppidEnd)...].drop { $0 == " " }
        // cputime
        guard let cpuEnd = afterPpid.firstIndex(of: " ") else { return nil }
        let cpuSeconds = parseCPUTime(String(afterPpid[..<cpuEnd]))

        let afterCPU = afterPpid[afterPpid.index(after: cpuEnd)...].drop { $0 == " " }
        // comm (single token, as in the original parser) + args (remainder).
        if let commEnd = afterCPU.firstIndex(of: " ") {
            let comm = String(afterCPU[..<commEnd])
            let args = String(afterCPU[afterCPU.index(after: commEnd)...])
            return (pid, ppid, cpuSeconds, comm, args)
        }
        // No args column (rare): the whole remainder is comm.
        return (pid, ppid, cpuSeconds, String(afterCPU), "")
    }

    /// Parse a `ps` CPU-time field into seconds. macOS formats it as
    /// `[DD-]HH:MM:SS` or `MM:SS.cc` (e.g. `0:01.23`, `12:34.56`, `1:02:03`,
    /// `1-02:03:04`). Returns 0 on anything unexpected.
    private func parseCPUTime(_ field: String) -> Double {
        var days = 0.0
        var rest = Substring(field)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        // Components are H:M:S or M:S; the last carries fractional seconds.
        let parts = rest.split(separator: ":").map { Double($0) ?? 0 }
        guard !parts.isEmpty else { return days * 86_400 }
        var seconds = 0.0
        for value in parts { seconds = seconds * 60 + value }
        return days * 86_400 + seconds
    }

    /// Apply the detection rules to a single process row. Returns the display
    /// label if it matches, else nil.
    private func match(comm: String, args: String, pid: Int32) -> String? {
        let executable = (comm as NSString).lastPathComponent.lowercased()
        let keyword = Constants.claudeKeyword

        // Rule 1: executable name contains "claude".
        if executable.contains(keyword) {
            return "PID \(pid) \(comm)"
        }

        // Rule 2: a node process whose arguments mention claude.
        if executable == Constants.nodeExecutable,
           args.lowercased().contains(keyword) {
            return "PID \(pid) node (claude)"
        }

        return nil
    }

    /// Run `/bin/ps -axo pid=,ppid=,cputime=,comm=,args=` and return its stdout.
    private func runPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -a all users' processes, -x include those without a controlling tty.
        // `=` suffix on each column suppresses headers. ppid/cputime added so we
        // can walk each Claude subtree and measure its CPU activity (AC-5a).
        process.arguments = ["-axo", "pid=,ppid=,cputime=,comm=,args="]

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
