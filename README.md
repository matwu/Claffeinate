# Claffeinate

A macOS menu bar app that keeps your Mac awake **only while Claude / Claude Code is actively working** — and lets it sleep normally once Claude goes idle.

The name is **Claude + `caffeinate`**, after the macOS `caffeinate` command.

## Overview

When you hand a long task to Claude Code (a big build, a deep refactor, an investigation), you stop touching the keyboard — and your Mac drifts into sleep, stalling the work. You often also want to **close the lid and walk away** while the task runs. The usual workarounds are awkward: `caffeinate` only blocks *idle* sleep (the Mac still sleeps when you close the lid), and `sudo pmset -a disablesleep 1` needs root every time, is system-wide, and is easy to leave on.

Claffeinate sits in the menu bar, watches for Claude, and automatically prevents **system sleep — including lid-close (clamshell) sleep** — *only* while Claude is **actively processing**. "Active" means more than just a running process: Claffeinate watches the CPU activity of Claude's process tree, so an idle Claude sitting at the prompt doesn't hold your Mac awake. Quiet stretches (e.g. waiting on a model response, when local CPU drops to near zero) are bridged by a configurable **idle grace period** (default **30 minutes**) so a long task is never cut short by a false sleep. When Claude goes idle past the grace period, sleep prevention is released and your Mac sleeps as usual.

Lid-close prevention is only possible via the `SleepDisabled` system setting (the same one `pmset disablesleep` writes), which requires root. Claffeinate gets there without repeated password prompts by installing a small **privileged helper** (an `SMAppService` launchd daemon) that you authorize **once**; the app then drives it over XPC. A heartbeat watchdog guarantees the setting is restored even if the app crashes (so the Mac never gets stuck awake).

## Features

- **Automatic** — detects Claude / Claude Code and toggles sleep prevention without intervention.
- **Activity-aware** — keeps the Mac awake only while Claude's process tree is actually using CPU, not merely running. A configurable idle grace period (default 30 min) bridges quiet model-response waits so long tasks aren't cut short.
- **Lid-close aware** — keeps the *system* awake even with the lid shut; your display can still sleep (saves power).
- **Authorize once** — the privileged helper prompts a single time on first launch, never again.
- **Menu bar only** — no Dock icon, no window.
- **Transparent status** — see detection, prevention, monitoring, and helper state at a glance:
  - `Claude: Detected (Active) / Detected (Idle) / Not Detected`
  - `Sleep Prevention: Active / Inactive`
  - `Monitoring: Running / Paused`
  - `Helper: Connected / Not Connected`
- **User control** — Pause / Resume monitoring, Check Now for an immediate scan, and an adjustable **idle grace period** (persisted across restarts).
- **Crash-safe** — `SleepDisabled` is restored on quit, by a helper-side watchdog if the app dies, and on helper startup. The Mac never gets stuck awake.
- **No third-party dependencies** — standard libraries only (Swift / SwiftUI / AppKit / IOKit / ServiceManagement / XPC).

### How Claude is detected

Every few seconds (default **5 s**), Claffeinate scans the process list and treats a process as Claude if either:

1. a process's executable name contains `claude` (covers `claude`, `Claude`, `claude-code`), **or**
2. a `node` process has `claude` in its command line (e.g. `node … claude …`).

Detection is read-only — Claffeinate never touches the processes it observes, and excludes its own process.

### When Claude counts as "active"

Presence isn't enough: a Claude process sitting idle at the prompt shouldn't keep your Mac awake. So each scan also measures the **CPU time** consumed by the matched process **and its descendants** (the tool subprocesses Claude spawns — builds, tests, greps) since the previous scan:

- If that subtree's CPU usage clears a small threshold, Claude counts as **active** and the activity clock resets.
- If it's quiet, Claude still counts as active while within the **idle grace period** of the last activity — this bridges model-response waits where local CPU drops to near zero, the case where a false "idle" would be most damaging (your Mac sleeping mid-task).
- Once the subtree has been quiet for the whole grace period, Claude is **idle** and sleep prevention is released.

The grace period defaults to **30 minutes** and is selectable from the menu (`Idle grace period`); the choice is persisted in `UserDefaults`. A longer period makes a mid-task false sleep less likely at the cost of keeping the Mac awake a bit longer after Claude truly stops — a trade you control. Sleep prevention is driven by this **active** judgement, not by mere presence.

## Architecture

Two processes: a **non-privileged menu bar app** (UI / detection / monitoring) and a **privileged root helper** (the only thing that touches `SleepDisabled`), connected over XPC.

```
┌─ Claffeinate.app (non-privileged) ──────────────────────────────────────┐
│ ClaffeinateApp (@main, SwiftUI App + MenuBarExtra)                       │
│   └─ AppDelegate      setActivationPolicy(.accessory) · register helper  │
│        └─ AppState    isClaudeRunning · isClaudeActive ·                 │
│        │              isSleepAssertionActive · isMonitoringPaused ·      │
│        │              lastDetectedProcess · isHelperConnected ·          │
│        │              gracePeriodMinutes (persisted)  (single source of truth)│
│        └─ ProcessMonitor  Timer(5s) → detect → sample → reconcile        │
│             ├─ ClaudeDetector  scans `ps` (pid/ppid/cputime), match rules│
│             ├─ ActivitySampler subtree CPU delta + idle grace (stateful) │
│             └─ SleepController  acquire()/release() → XPC + heartbeat     │
│                   └─ HelperClient  SMAppService register · NSXPCConnection│
│        └─ MenuContent  renders status + controls                         │
└──────────────────────────────┬───────────────────────────────────────────┘
                               │ XPC: setDisableSleep / ping / currentState
┌─ com.matwu.Claffeinate.Helper (root daemon) ─────────────────────────────┐
│ SleepDisabledManager  IOPMSetSystemPowerSetting("SleepDisabled", …)       │
│   · watchdog: restore false if heartbeat stops   · reset false on startup │
│ HelperListenerDelegate  accepts only the signed app (code requirement)    │
└───────────────────────────────────────────────────────────────────────────┘
```

Detection, activity judgement, and prevention stay deliberately separate. `ClaudeDetector` is a stateless scan (presence + process table); `ActivitySampler` is the one stateful piece (it remembers the previous scan's CPU times and the last-activity timestamp to apply the grace period); `reconcile()` applies only the *difference* between the latest **active** judgement and the state actually held. `SleepController` keeps the `acquire()` / `release()` surface and never reports `Active` until the helper confirms the privileged write.


| Component             | File                                                    | Role                                                                             |
| --------------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------- |
| App entry / lifecycle | `Claffeinate/ClaffeinateApp.swift`                      | `@main`, menu bar scene, accessory policy, register helper, release-on-terminate |
| State                 | `Claffeinate/AppState.swift`                            | observable single source of truth                                                |
| Monitor               | `Claffeinate/ProcessMonitor.swift`                      | timer loop, pause/resume/check-now, detect → sample → reconcile                  |
| Detection             | `Claffeinate/ClaudeDetector.swift`                      | stateless process scan (pid/ppid/cputime) + match rules                          |
| Activity              | `Claffeinate/ActivitySampler.swift`                     | subtree CPU-delta + idle grace period → active judgement (stateful)              |
| Sleep control         | `Claffeinate/SleepController.swift`                     | XPC-backed acquire/release + heartbeat                                           |
| Helper client         | `Claffeinate/HelperClient.swift`                        | `SMAppService` registration + XPC connection                                     |
| XPC contract          | `Claffeinate/HelperProtocol.swift`                      | shared protocol + identifiers/timings (also in helper target)                    |
| Helper daemon         | `ClaffeinateHelper/`                                    | root daemon: `SleepDisabled` write, watchdog, listener                           |
| IOKit SPI             | `ClaffeinateHelper/ClaffeinateHelper-Bridging-Header.h` | declares private `IOPMSetSystemPowerSetting`                                     |
| Menu UI               | `Claffeinate/MenuContent.swift`                         | status lines + controls                                                          |
| Tunables              | `Claffeinate/Constants.swift`                           | interval, reason text, keywords                                                  |


Specifications, design, and the task breakdown live in [`specs/`](./specs/).

## Build

Requirements: macOS 26+ and Xcode. The repo is an Xcode project (`Claffeinate.xcodeproj`) with two targets — the menu bar **app** and the privileged **helper** daemon — sharing the `HelperProtocol.swift` XPC contract.

Open `Claffeinate.xcodeproj`, select your signing team under the **Claffeinate** and **ClaffeinateHelper** targets' Signing & Capabilities, then build the **Claffeinate** scheme in Xcode (⌘B), or:

```bash
xcodebuild -project Claffeinate.xcodeproj -scheme Claffeinate build
```

> ⚠️ Lid-close prevention needs the privileged helper, which `SMAppService`
> registers from a **signed `.app` bundle**. An unsigned/sandboxed build runs but
> the helper won't register (the menu shows `Helper: Not Connected` and no sleep
> prevention engages). A Developer ID-signed (and ideally notarized) build is
> needed to register the helper; a self-signed identity works for local dev.

## Run & verify

After installing the signed bundle, launch it and approve the
one-time helper prompt. A cup icon appears in the menu bar (filled while sleep
is being prevented). Confirm the system setting is actually applied while Claude
runs:

```bash
pmset -g | grep -i SleepDisabled    # → 1 while active, 0 otherwise
```

Then **close the lid** — the Mac stays awake while Claude runs, and sleeps
normally once Claude stops or you quit.

## Limitations

- **Polling granularity** — the process list is scanned every 5 seconds, so Claude sessions that start and end within one interval may be missed. Fine for the long-running tasks this app targets.
- **Broad `node` match** — any `node` process with `claude` in its command line counts as Claude. A false positive only causes *extra* sleep prevention (fails safe), never the reverse.
- **Activity is a heuristic** — "active" is inferred from process-tree CPU usage, so a genuinely quiet stretch longer than the idle grace period reads as idle. The default 30-min grace makes this very unlikely mid-task; raise it if needed. The cost of a generous grace is only *extra* awake time after Claude stops (fails safe).
- **Watchdog window** — if the app is force-killed while active, `SleepDisabled` stays on until the helper's watchdog timeout (~35s) restores it. Normal quits release immediately.
- **Display sleep** — intentionally not prevented; the screen can still turn off.
- **Signing required** — the helper needs a Developer ID-signed (and ideally notarized) bundle to register; ad-hoc/self-signed works only with extra local setup.

## Future Work

- Settings UI (adjustable interval, watchdog timeout, custom detection keywords, CPU threshold). The idle grace period is already adjustable from the menu.
- Launch-at-login (login item) registration.
- App Store distribution.
- Optional notifications when prevention turns on/off.
- Unit tests for the detection rules.

## License

[MIT](./LICENSE)