import Foundation

/// Fallback signal for sessions that have *no* hooks wired up: Claude Code
/// appends to a session transcript (`~/.claude/projects/<cwd>/<uuid>.jsonl`) as a
/// turn streams — assistant tokens, tool calls, tool results. A very recent
/// write therefore means "a turn is progressing right now".
///
/// This is **positive evidence only**: during a long local tool run the
/// transcript can stay silent for minutes, so the resolver still needs CPU to
/// bridge those gaps. Background writers (claude-mem observers, etc.) are
/// excluded by path so their churn doesn't read as interactive work.
struct TranscriptScanner {
    private var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// True if any interactive session transcript was written within `window`.
    /// Early-exits on the first hit, so an actively-writing session is cheap to
    /// detect; a fully idle tree is the only case that walks everything.
    func hasFreshInteractiveWrite(now: Date, window: TimeInterval) -> Bool {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            let path = url.path.lowercased()
            if Constants.backgroundTranscriptMarkers.contains(where: path.contains) {
                continue
            }
            guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else {
                continue
            }
            if now.timeIntervalSince(modified) <= window {
                return true     // a turn is actively writing — done
            }
        }
        return false
    }
}
