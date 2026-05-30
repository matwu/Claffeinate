# Claffeinate

A macOS menu bar app that keeps your Mac awake **only while Claude / Claude Code is running** — and lets it sleep normally the moment Claude stops.

The name is **Claude + `caffeinate`**, after the macOS `caffeinate` command.

## Overview

When you hand a long task to Claude Code (a big build, a deep refactor, an investigation), you stop touching the keyboard — and your Mac drifts into idle sleep, stalling the work. The usual workarounds are awkward: running `caffeinate` by hand is easy to forget to stop, and `sudo pmset -a disablesleep 1` needs root, is system-wide, and is easy to leave on.

Claffeinate sits in the menu bar, watches for Claude, and automatically prevents idle sleep **only** while Claude is running. When Claude exits, the assertion is released and your Mac sleeps as usual. No `sudo`, no leftover settings.

It uses the same standard macOS mechanism the built-in `caffeinate` command uses: a **Power Management Assertion** (`IOPMAssertionCreateWithName` / `IOPMAssertionRelease`).

## Features

- **Automatic** — detects Claude / Claude Code and toggles sleep prevention without intervention.
- **Idle-sleep only** — keeps the *system* awake; your display can still sleep (saves power).
- **Menu bar only** — no Dock icon, no window.
- **Transparent status** — see detection, prevention, and monitoring state at a glance:
  - `Claude: Detected / Not Detected`
  - `Sleep Prevention: Active / Inactive`
  - `Monitoring: Running / Paused`
- **User control** — Pause / Resume monitoring, and Check Now for an immediate scan.
- **Safe shutdown** — the assertion is always released on quit (no leftover sleep prevention).
- **No `sudo`, no third-party dependencies** — standard libraries only.

### How Claude is detected

Every few seconds (default **5 s**), Claffeinate scans the process list and treats Claude as running if either:

1. a process's executable name contains `claude` (covers `claude`, `Claude`, `claude-code`), **or**
2. a `node` process has `claude` in its command line (e.g. `node … claude …`).

Detection is read-only — Claffeinate never touches the processes it observes, and excludes its own process.

## Architecture

Single executable, single responsibility, with all state held in one place.

```
ClaffeinateApp (@main, SwiftUI App + MenuBarExtra)
  └─ AppDelegate         setActivationPolicy(.accessory) · release on terminate
       └─ AppState       isClaudeRunning · isSleepAssertionActive ·
       │                 isMonitoringPaused · lastDetectedProcess   (single source of truth)
       └─ ProcessMonitor Timer(5s) → detect → reconcile; pause / resume / check now
            ├─ ClaudeDetector   scans `ps` output, applies detection rules (stateless)
            └─ SleepAssertion   IOKit wrapper, idempotent acquire() / release()
       └─ MenuContent     renders status + controls
```

Detection and prevention are deliberately separate. Each tick, `reconcile()` applies only the *difference* between the latest detection result and the assertion actually held, so the displayed `Sleep Prevention` state always matches reality.

| Component | File | Role |
| --- | --- | --- |
| App entry / lifecycle | `Sources/Claffeinate/ClaffeinateApp.swift` | `@main`, menu bar scene, accessory policy, release-on-terminate |
| State | `Sources/Claffeinate/AppState.swift` | observable single source of truth |
| Monitor | `Sources/Claffeinate/ProcessMonitor.swift` | timer loop, pause/resume/check-now, reconcile |
| Detection | `Sources/Claffeinate/ClaudeDetector.swift` | stateless process scan + match rules |
| Sleep prevention | `Sources/Claffeinate/SleepAssertion.swift` | IOKit power assertion wrapper |
| Menu UI | `Sources/Claffeinate/MenuContent.swift` | status lines + controls |
| Tunables | `Sources/Claffeinate/Constants.swift` | interval, assertion text, keywords |

Specifications, design, and the task/issue breakdown live in [`specs/`](./specs/).

## Build

Requirements: macOS 13+ and a Swift 5.9+ toolchain (bundled with recent Xcode / Command Line Tools).

```bash
swift build
```

## Run

```bash
swift run
```

A cup icon appears in the menu bar (filled while sleep is being prevented). There is no Dock icon and no window — click the menu bar icon for status and controls.

To confirm the assertion is actually held while Claude runs:

```bash
pmset -g assertions | grep PreventUserIdleSystemSleep
```

You should see an entry named `Claffeinate: Claude is running` while Claude is detected, and it disappears when Claude stops or you quit the app.

## Limitations

- **Polling granularity** — the process list is scanned every 5 seconds, so Claude sessions that start and end within one interval may be missed. Fine for the long-running tasks this app targets.
- **Broad `node` match** — any `node` process with `claude` in its command line counts as Claude. A false positive only causes *extra* sleep prevention (fails safe), never the reverse.
- **Crash behaviour** — if the app crashes, the OS reclaims the assertion automatically when the process dies, so the Mac will not stay awake forever. Normal quits always release explicitly.
- **Idle sleep only** — display sleep is intentionally not prevented.
- **Local build** — no signed/notarized `.app` bundle or App Store distribution is included.

## Future Work

- Settings UI (adjustable interval, custom detection keywords).
- Launch-at-login (login item) registration.
- A packaged, signed `.app` bundle.
- Optional notifications when prevention turns on/off.
- Unit tests for the detection rules.

## License

Personal/internal use.
