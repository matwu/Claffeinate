import Foundation

/// Installs (or refreshes) Claffeinate's hooks in the user's
/// `~/.claude/settings.json`, so Claude Code reports turn/tool boundaries to us
/// by invoking this same binary in `--claffeinate-hook` mode.
///
/// Non-destructive: it merges *alongside* any hooks the user already has,
/// removing only previous Claffeinate entries (identified by the hook flag) so
/// re-running updates the binary path without duplicating or clobbering.
enum HookInstaller {
    /// Claude Code hook events we register, each passed verbatim as the arg so
    /// `HookMode` can switch on it. (SubagentStart isn't a Claude event — the
    /// turn lease already covers a subagent's lifetime, so we don't need it.)
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Stop", "SubagentStop", "SessionEnd", "Notification",
    ]

    struct Result {
        let ok: Bool
        let message: String
    }

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Merge our hooks into settings.json. Returns a user-facing result.
    static func install() -> Result {
        guard let binary = Bundle.main.executablePath else {
            return Result(ok: false, message: "Couldn't locate the Claffeinate binary.")
        }

        let fm = FileManager.default
        let url = settingsURL

        // Load existing settings (or start fresh).
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return Result(ok: false,
                              message: "~/.claude/settings.json isn't valid JSON — not touching it.")
            }
            root = parsed
            // Back up before mutating, once per install.
            try? data.write(to: url.appendingPathExtension("claffeinate.bak"))
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        for event in events {
            let command = "\"\(binary)\" \(Constants.hookModeFlag) \(event)"
            var groups = (hooks[event] as? [[String: Any]]) ?? []
            // Strip only our *entries* (not whole groups), so a group where the
            // user added their own hook alongside ours keeps the user's hook.
            groups = groups.compactMap { group in
                var g = group
                var entries = (g["hooks"] as? [[String: Any]]) ?? []
                entries.removeAll { ($0["command"] as? String)?.contains(Constants.hookModeFlag) == true }
                if entries.isEmpty && (g["hooks"] != nil) { return nil }  // drop now-empty group
                g["hooks"] = entries
                return g
            }
            // Append ours as its own group, preserving everything already there.
            groups.append(["hooks": [["type": "command", "command": command]]])
            hooks[event] = groups
        }
        root["hooks"] = hooks

        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let out = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: url, options: .atomic)
        } catch {
            return Result(ok: false, message: "Couldn't write settings.json: \(error.localizedDescription)")
        }

        return Result(
            ok: true,
            message: "Installed Claffeinate hooks for \(events.count) Claude Code events. "
                + "New Claude sessions will report activity precisely; existing hooks were kept. "
                + "A backup was saved next to settings.json.")
    }

    /// Whether our hooks appear to be installed (any event references the flag).
    static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        for value in hooks.values {
            for group in (value as? [[String: Any]]) ?? [] {
                for entry in (group["hooks"] as? [[String: Any]]) ?? [] {
                    if (entry["command"] as? String)?.contains(Constants.hookModeFlag) == true {
                        return true
                    }
                }
            }
        }
        return false
    }
}
