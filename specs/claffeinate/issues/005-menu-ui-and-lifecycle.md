# [005] メニュー UI と終了時のアサーション解除

**spec:** claffeinate · **対応 AC:** AC-17, AC-18, AC-19, AC-20 · **依存:** 004

## 概要

メニューに現在の状態を表示し、Pause / Resume / Check Now / Quit を結線する。アプリ終了時にアサーションを確実に解除する。

## やること

- [ ] `Sources/Claffeinate/MenuContent.swift`: `MenuBarExtra` の content View
  - タイトル `Claffeinate`
  - Status 3 行:
    - `Claude: Detected / Not Detected`（`isClaudeRunning`）
    - `Sleep Prevention: Active / Inactive`（`isSleepAssertionActive`）
    - `Monitoring: Running / Paused`（`isMonitoringPaused`）
  - `Pause Monitoring` / `Resume Monitoring`（状態に応じて出し分け or トグル）
  - `Check Now`
  - `Quit`
- [ ] メニューバーアイコンを抑止状態で出し分け（active 時に視覚的に分かる）
- [ ] Quit は `NSApplication.terminate(nil)` を呼ぶ（直接 exit しない）
- [ ] `AppDelegate.applicationWillTerminate` で `SleepAssertion.release()`

## Acceptance Criteria

- メニューに検出 / 抑止 / 監視の 3 状態が表示される（**AC-17**）。
- メニューを開くたびに最新状態が反映される（**AC-18**）。
- Quit / OS 終了の両経路でアサーションを解除してから終了する（**AC-19**）。
- クラッシュを除き、終了後にアサーションが残らない（**AC-20**）。検証: 終了後 `pmset -g assertions` から `PreventUserIdleSystemSleep` が消える。

## メモ

- 終了経路を `applicationWillTerminate` に一元化し解除漏れを防ぐ（design §5）。
