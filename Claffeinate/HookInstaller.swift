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
            // Strip only *this build's* entries (matched on the exact flag token),
            // so a Release install never removes a Debug entry or vice versa, and
            // a group where the user added their own hook alongside ours keeps it.
            groups = groups.compactMap { group in
                var g = group
                var entries = (g["hooks"] as? [[String: Any]]) ?? []
                entries.removeAll { isOurCommand(($0["command"] as? String) ?? "") }
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

    /// Remove every Claffeinate hook entry — this build's, the other build's, and
    /// any old residue (matched on the `--claffeinate` marker) — leaving the
    /// user's own hooks untouched. Cleans up the `~/.claude/settings.json` clutter
    /// and any stale entries from past experiments. Returns a user-facing result.
    static func uninstall() -> Result {
        let url = settingsURL
        guard let data = try? Data(contentsOf: url) else {
            return Result(ok: true, message: "No ~/.claude/settings.json — nothing to remove.")
        }
        guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Result(ok: false,
                          message: "~/.claude/settings.json isn't valid JSON — not touching it.")
        }
        var root = parsed
        try? data.write(to: url.appendingPathExtension("claffeinate.bak"))

        guard var hooks = root["hooks"] as? [String: Any] else {
            return Result(ok: true, message: "No Claffeinate hooks were present.")
        }

        var removed = 0
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let pruned: [[String: Any]] = groups.compactMap { group in
                var g = group
                var entries = (g["hooks"] as? [[String: Any]]) ?? []
                let before = entries.count
                entries.removeAll { isAnyClaffeinateCommand(($0["command"] as? String) ?? "") }
                removed += before - entries.count
                if entries.isEmpty && (g["hooks"] != nil) { return nil }  // drop now-empty group
                g["hooks"] = entries
                return g
            }
            if pruned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = pruned }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }

        do {
            let out = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: url, options: .atomic)
        } catch {
            return Result(ok: false, message: "Couldn't write settings.json: \(error.localizedDescription)")
        }

        return Result(
            ok: true,
            message: removed == 0
                ? "No Claffeinate hooks were present."
                : "Removed \(removed) Claffeinate hook entr\(removed == 1 ? "y" : "ies"). "
                    + "Running Claude sessions keep using hooks until they restart. "
                    + "Your own hooks were kept; a backup was saved next to settings.json.")
    }

    /// Whether *this build's* hooks appear to be installed (an event references
    /// our exact flag token).
    static func isInstalled() -> Bool { anyHook(isOurCommand) }

    /// Whether *any* Claffeinate hooks are present (this build, the other build,
    /// or old residue). Gates the "Remove" action so it can clean up entries even
    /// when the running build didn't install them.
    static func isAnyInstalled() -> Bool { anyHook(isAnyClaffeinateCommand) }

    /// True if any installed hook command satisfies `predicate`.
    private static func anyHook(_ predicate: (String) -> Bool) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        for value in hooks.values {
            for group in (value as? [[String: Any]]) ?? [] {
                for entry in (group["hooks"] as? [[String: Any]]) ?? [] {
                    if predicate((entry["command"] as? String) ?? "") { return true }
                }
            }
        }
        return false
    }

    // MARK: - Ownership matching

    /// True if a hook command is one of *ours for this build*, matched on the
    /// exact flag token (space-delimited). This is why `--claffeinate-hook` never
    /// matches `--claffeinate-develop-hook` or vice versa — substring matching
    /// would, and that ambiguity is what we must avoid.
    private static func isOurCommand(_ command: String) -> Bool {
        command.contains(" \(Constants.hookModeFlag) ")
    }

    /// True if a hook command belongs to *any* Claffeinate build, including old
    /// residue from past experiments. Used only by `uninstall()`.
    private static func isAnyClaffeinateCommand(_ command: String) -> Bool {
        command.contains("--claffeinate")
    }
}
