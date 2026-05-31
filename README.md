# Claffeinate

A macOS menu bar app that keeps your Mac awake **only while Claude / Claude Code is actively working** — and lets it sleep normally once Claude goes idle.

The name is **Claude + `caffeinate`**, after the macOS `caffeinate` command.

### ⬇︎ [Download the latest release](https://github.com/matwu/Claffeinate/releases/latest)

Grab the notarized `Claffeinate-<version>.zip` from the **[latest release](https://github.com/matwu/Claffeinate/releases/latest)**, unzip it, move **Claffeinate.app** to `/Applications`, and launch. Approve the one-time helper prompt and you're set — a cup icon appears in the menu bar. Requires **macOS 26 or later**. See [Install](#install) for the few details.

## Overview

When you hand a long task to Claude Code (a big build, a deep refactor, an investigation), you stop touching the keyboard — and your Mac drifts into sleep, stalling the work. You often also want to **close the lid and walk away** while the task runs. The usual workarounds are awkward: `caffeinate` only blocks *idle* sleep (the Mac still sleeps when you close the lid), and `sudo pmset -a disablesleep 1` needs root every time, is system-wide, and is easy to leave on.

Claffeinate sits in the menu bar, watches for Claude, and automatically prevents **system sleep — including lid-close (clamshell) sleep** — *only* while Claude is **actively working**. "Working" means a turn is in progress, not just that a process is running, so an idle Claude sitting at the prompt doesn't hold your Mac awake.

The most reliable way to know that is to ask Claude Code itself: with a one-click setup, Claffeinate installs **Claude Code hooks** that report exact turn and tool boundaries, so detection is precise — no guessing, no CPU heuristics, and a session blocked on a permission prompt is shown as "needs attention" rather than keeping the Mac awake. Without hooks, Claffeinate falls back to **transcript activity** (Claude streams its turn to a session log). Each session is judged **independently** (run several at once and any one working keeps the Mac awake). When nothing is working, sleep prevention is released and your Mac sleeps as usual.

Lid-close prevention is only possible via the `SleepDisabled` system setting (the same one `pmset disablesleep` writes), which requires root. Claffeinate gets there without repeated password prompts by installing a small **privileged helper** (an `SMAppService` launchd daemon) that you authorize **once**; the app then drives it over XPC. A heartbeat watchdog guarantees the setting is restored even if the app crashes (so the Mac never gets stuck awake).

## Features

- **Automatic** — detects Claude / Claude Code and toggles sleep prevention without intervention.
- **Precise, hook-based detection** — one click installs Claude Code hooks that report exact turn/tool boundaries, so "working" is known directly from Claude rather than inferred. Falls back to transcript activity when hooks aren't set up. No CPU heuristics (they false-positived on idle terminal rendering).
- **Three honest states** — **Busy** (keep awake), **Needs attention** (Claude is waiting for *you* — sleep is allowed but flagged), and **Idle**.
- **Multi-session aware** — every running Claude is judged on its own; one session's state can't mask another's. Headless `--enable-auto-mode` agents are protected too, so an unattended background run isn't cut short by sleep.
- **Lid-close aware** — keeps the *system* awake even with the lid shut; your display can still sleep (saves power).
- **Authorize once** — the privileged helper prompts a single time on first launch, never again.
- **Menu bar only** — no Dock icon, no window.
- **Transparent by design** — the panel shows *why* your Mac is awake: the state, what Claude is doing (`Running a tool`, `Answering a prompt`, …), how long the turn has run, the session breakdown, and a `Detection` tag showing whether precise hooks are active. Plus at-a-glance `Claude`, `Monitoring`, and `Helper` tags.
- **User control** — Pause / Resume monitoring, Refresh Now for an immediate scan, and Set Up Claude Hooks.
- **Crash-safe** — `SleepDisabled` is restored on quit, by a helper-side watchdog if the app dies, and on helper startup. The Mac never gets stuck awake.
- **No third-party dependencies** — standard libraries only (Swift / SwiftUI / AppKit / IOKit / ServiceManagement / XPC).

### How Claude is detected

Every few seconds (default **5 s**), Claffeinate scans the process list and treats a process as a Claude **session root** if either:

1. a process's executable name contains `claude` (covers `claude`, `claude-code`), **or**
2. a `node` process runs the Claude Code script (a path token named `claude` / `claude-code` on its command line).

To avoid false matches, the desktop **Claude.app** (a constantly-rendering Electron app that would never look idle) is excluded, as are `.claude/…` *config paths* — so the rule (2) `node` test matches the real CLI, not the claude-mem MCP server. Detection is read-only — Claffeinate never touches the processes it observes, and excludes its own process.

### When Claude counts as "working"

Presence isn't enough: a Claude sitting idle at the prompt shouldn't keep your Mac awake. CPU is a poor proxy — an idle terminal still burns a little (rendering, file watchers), while a session waiting on a model response burns almost none — so Claffeinate doesn't use it. It resolves activity from two signals, in priority order:

1. **Hooks (authoritative).** With the one-click setup, Claude Code runs a Claffeinate hook on each event. `UserPromptSubmit` opens a *turn lease*; `PreToolUse`/`PostToolUse` track a *tool lease*; `Stop` and `SessionEnd` close them; `Notification` marks a *needs-attention* state; `SessionStart` records a per-session coverage marker. Each lease is a small, expiring file tagged with the owning Claude PID (resolved as the first non-shell ancestor of the hook, since the CLI's process name is just a version string), so the Mac is kept awake exactly while a turn or tool is live — and a crash that skips the closing hook self-heals (the lease expires, and dies the moment its PID is gone). This is per session, so a hook-reporting session and a hook-less one coexist without masking each other.
2. **Transcript freshness (fallback).** For a session without hooks, Claude appends to its session transcript as a turn streams. A write within the last few seconds means a turn is progressing. Background writers (claude-mem observers, etc.) are excluded by path. (This is positive evidence only — it can't see a long, silent local tool run, which is one more reason to install hooks.)

The Mac is kept awake while **any** session is *busy*. A session that's only **waiting for you** (a permission prompt) is shown as *needs attention* and does **not** hold the Mac awake — you've stepped away. The menu panel always shows the deciding **reason** (`hook · turn`, `transcript`, …) and what Claude is doing, so "awake" is never a mystery. Installing hooks is strongly recommended — it makes detection exact and gap-free.

## Architecture

Two processes: a **non-privileged menu bar app** (UI / detection / monitoring) and a **privileged root helper** (the only thing that touches `SleepDisabled`), connected over XPC.

```
┌─ Claffeinate.app (non-privileged) ──────────────────────────────────────┐
│ ClaffeinateApp (@main, SwiftUI App + MenuBarExtra)                       │
│   └─ AppDelegate      setActivationPolicy(.accessory) · register helper  │
│        └─ AppState    isClaudeRunning · activityState/Reason/Since ·     │
│        │              isSleepAssertionActive · isMonitoringPaused ·      │
│        │              runningSessionCount · hasAutoModeSession ·         │
│        │              hooksActive · isHelperConnected                    │
│        └─ ProcessMonitor  Timer(5s) → detect → resolve → reconcile       │
│             ├─ ClaudeDetector   scans `ps` (pid/comm/args) → roots+livePIDs│
│             ├─ ActivityResolver hooks > transcript → ResolvedActivity     │
│             │     ├─ LeaseStore        reads hook leases (+PID liveness)  │
│             │     └─ TranscriptScanner ~/.claude transcript freshness     │
│             └─ SleepController  acquire()/release() → XPC + heartbeat     │
│                   └─ HelperClient  SMAppService register · NSXPCConnection│
│        └─ MenuContent  renders state + controls (Set Up Claude Hooks)    │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ XPC: setDisableSleep / ping / currentState
┌─ com.matwu.Claffeinate.Helper (root daemon) ─────────────────────────────┐
│ SleepDisabledManager  IOPMSetSystemPowerSetting("SleepDisabled", …)       │
│   · watchdog: restore false if heartbeat stops   · reset false on startup │
│ HelperListenerDelegate  accepts only the signed app (code requirement)    │
└───────────────────────────────────────────────────────────────────────────┘

  Claude Code  ──(hook: --claffeinate-hook <Event>)──▶  ~/.claffeinate/leases/*.json
  (UserPromptSubmit / PreToolUse / … / Stop)            (read by LeaseStore each scan)
```

Detection, activity judgement, and prevention stay deliberately separate. `ClaudeDetector` is a stateless scan (the session roots + the set of live PIDs). `ActivityResolver` combines the two signals in priority order — hook **leases** (written by the app's own `--claffeinate-hook` binary mode and read back by `LeaseStore`, with per-PID liveness) and **transcript** freshness — into a `ResolvedActivity` (state + reason). `reconcile()` applies only the *difference* between the latest **busy** judgement and the state actually held. `SleepController` keeps the `acquire()` / `release()` surface and never reports `Active` until the helper confirms the privileged write.


| Component             | File                                                    | Role                                                                             |
| --------------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------- |
| App entry / lifecycle | `Claffeinate/ClaffeinateApp.swift`                      | `@main` entry: routes hook invocations to `HookMode`, else starts the menu bar app |
| State                 | `Claffeinate/AppState.swift`                            | observable single source of truth (activity state / reason / session info)       |
| Monitor               | `Claffeinate/ProcessMonitor.swift`                      | timer loop, pause/resume/check-now, detect → resolve → reconcile                 |
| Detection             | `Claffeinate/ClaudeDetector.swift`                      | stateless process scan (pid/comm/args) → session roots + live-PID set            |
| Activity resolver     | `Claffeinate/ActivityResolver.swift`                    | combines hooks > transcript into `ResolvedActivity`                              |
| Hook leases           | `Claffeinate/ActivityLease.swift`                       | lease model + `LeaseStore` (read, expiry, per-PID liveness, safe cleanup)         |
| Hook writer           | `Claffeinate/HookMode.swift`                            | `--claffeinate-hook` binary mode: writes/clears leases from Claude's hook stdin   |
| Hook installer        | `Claffeinate/HookInstaller.swift`                       | non-destructive merge of Claffeinate hooks into `~/.claude/settings.json`         |
| Transcript fallback   | `Claffeinate/TranscriptScanner.swift`                   | `~/.claude/projects` transcript-freshness (background writers excluded)            |
| Sleep control         | `Claffeinate/SleepController.swift`                     | XPC-backed acquire/release + heartbeat                                           |
| Helper client         | `Claffeinate/HelperClient.swift`                        | `SMAppService` registration + XPC connection                                     |
| XPC contract          | `Claffeinate/HelperProtocol.swift`                      | shared protocol + identifiers/timings (also in helper target)                    |
| Helper daemon         | `ClaffeinateHelper/`                                    | root daemon: `SleepDisabled` write, watchdog, listener                           |
| IOKit SPI             | `ClaffeinateHelper/ClaffeinateHelper-Bridging-Header.h` | declares private `IOPMSetSystemPowerSetting`                                     |
| Menu UI               | `Claffeinate/MenuContent.swift`                         | hero, live state card (state · duration · reason), controls                      |
| Tunables              | `Claffeinate/Constants.swift`                           | interval, lease TTLs, transcript window, background markers, keywords            |


Specifications, design, and the task breakdown live in [`specs/`](./specs/).

## Install

Requires **macOS 26 or later**.

1. Download `Claffeinate-<version>.zip` from the **[latest release](https://github.com/matwu/Claffeinate/releases/latest)**.
2. Unzip it and move **Claffeinate.app** to `/Applications`.
3. Launch it. The build is Developer ID-signed and notarized, so it opens without a Gatekeeper warning.
4. Approve the **one-time helper prompt**. This installs the privileged helper that can prevent lid-close sleep — you'll never be asked again.
5. **Recommended:** click **Set Up Claude Hooks** in the panel. This merges Claffeinate's hooks into your `~/.claude/settings.json` (alongside any hooks you already have — a backup is saved), so *new* Claude Code sessions report exact turn/tool boundaries. The `Detection` tag flips to **Hooks** once they're active. Without this, Claffeinate still works via the transcript fallback.

A cup icon appears in the menu bar (filled while sleep is being prevented), and `Helper: Connected` in the panel confirms the helper registered. Claffeinate now watches for Claude automatically.

> Lid-close prevention requires the privileged helper, which `SMAppService` registers only from a **signed, notarized app bundle** — which the release build is. (A locally-built, unsigned bundle runs but shows `Helper: Not Connected` and engages no sleep prevention.)

## Verify

Confirm the system setting is actually applied while a Claude session is working:

```bash
pmset -g | grep -i SleepDisabled    # → 1 while active, 0 otherwise
```

Then **close the lid** — the Mac stays awake while Claude works, and sleeps normally once every session goes idle or you quit.

## Limitations

- **Hooks apply to new sessions** — installing hooks updates `settings.json`, which Claude Code reads at session start. Sessions already running keep using the transcript fallback until restarted.
- **Transcript fallback can't see silent tool runs** — without hooks, "working" is inferred from transcript writes, which go quiet during a long local tool run (a build/test). With no hook to keep the lease alive, the Mac could sleep mid-build. This is the main reason to install hooks: the tool lease covers exactly that gap.
- **Polling granularity** — state is re-evaluated every 5 seconds, so a turn that starts and ends within one interval may not register. Fine for the long-running tasks this app targets.
- **Detection is name-based** — a `node` process is matched only when its command line runs a `claude` / `claude-code` script (config paths under `.claude/…` are excluded), but an unrelated tool that ships a binary named `claude` would still match. A false positive only causes *extra* sleep prevention (fails safe), never the reverse.
- **Crash cleanup is TTL-bounded** — a hook lease is normally closed by `Stop`/`SessionEnd` and dies the instant its owning PID is gone. If Claude is force-killed *and* its PID can't be resolved, a stale lease lingers until its TTL (≤10 min) — extra awake time only, never a missed wake. The same 10-minute floor keeps the Mac awake through a long silent build between a tool's start and end hooks.
- **Watchdog window** — if the app is force-killed while active, `SleepDisabled` stays on until the helper's watchdog timeout (~35s) restores it. Normal quits release immediately.
- **Display sleep** — intentionally not prevented; the screen can still turn off.
- **Signing required** — the helper needs a Developer ID-signed (and ideally notarized) bundle to register; ad-hoc/self-signed works only with extra local setup.

## Future Work

- Settings UI (adjustable scan interval, watchdog timeout, custom detection keywords, lease TTLs).
- One-click hook *removal* (uninstall) from the menu.
- Launch-at-login (login item) registration.
- App Store distribution.
- Optional notifications when prevention turns on/off.

## License

[MIT](./LICENSE)