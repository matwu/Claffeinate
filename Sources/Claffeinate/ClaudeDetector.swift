import Foundation

/// Result of a single detection pass.
struct DetectionResult {
    /// Whether any Claude-related process is currently running.
    let isRunning: Bool
    /// "PID <pid> <name>" of the first matching process, or nil if none.
    let process: String?
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
    func detect() -> DetectionResult {
        let ownPID = ProcessInfo.processInfo.processIdentifier

        guard let output = runPS() else {
            // If `ps` cannot be run we report "not detected" so we fail safe by
            // releasing any assertion rather than holding it indefinitely.
            return DetectionResult(isRunning: false, process: nil)
        }

        for line in output.split(separator: "\n") {
            // Columns: "<pid> <comm> <args...>". `comm` has no spaces; `args`
            // may. We requested `pid=,comm=,args=` so there are no headers.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let pidEnd = trimmed.firstIndex(of: " ") else { continue }
            let pidString = String(trimmed[..<pidEnd])
            guard let pid = Int32(pidString), pid != ownPID else { continue }

            let rest = trimmed[trimmed.index(after: pidEnd)...]
                .trimmingCharacters(in: .whitespaces)
            guard let commEnd = rest.firstIndex(of: " ") else {
                // No args column (rare): treat the whole remainder as comm.
                if let match = match(comm: rest, args: "", pid: pid) {
                    return match
                }
                continue
            }

            let comm = String(rest[..<commEnd])
            let args = String(rest[rest.index(after: commEnd)...])

            if let match = match(comm: comm, args: args, pid: pid) {
                return match
            }
        }

        return DetectionResult(isRunning: false, process: nil)
    }

    /// Apply the detection rules to a single process row.
    private func match(comm: String, args: String, pid: Int32) -> DetectionResult? {
        let executable = (comm as NSString).lastPathComponent.lowercased()
        let keyword = Constants.claudeKeyword

        // Rule 1: executable name contains "claude".
        if executable.contains(keyword) {
            return DetectionResult(isRunning: true, process: "PID \(pid) \(comm)")
        }

        // Rule 2: a node process whose arguments mention claude.
        if executable == Constants.nodeExecutable,
           args.lowercased().contains(keyword) {
            return DetectionResult(isRunning: true, process: "PID \(pid) node (claude)")
        }

        return nil
    }

    /// Run `/bin/ps -axo pid=,comm=,args=` and return its stdout.
    private func runPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -a all users' processes, -x include those without a controlling tty.
        // `=` suffix on each column suppresses headers.
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
