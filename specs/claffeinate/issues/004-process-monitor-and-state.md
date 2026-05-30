# [004] プロセス監視と状態管理

**spec:** claffeinate · **対応 AC:** AC-4, AC-13, AC-14, AC-15, AC-16 · **依存:** 002, 003

## 概要

検出（002）と抑止（003）を Timer と中心状態 `AppState` に結線する。検出結果と抑止状態を `reconcile()` で一致させ、Pause / Resume / Check Now を提供する。

## やること

- [ ] `Sources/Claffeinate/AppState.swift`: `@MainActor` `ObservableObject`
  - `@Published isClaudeRunning / isSleepAssertionActive / isMonitoringPaused / lastDetectedProcess`
  - 状態は受動的データとして保持し、混在させない
- [ ] `Sources/Claffeinate/ProcessMonitor.swift`: `@MainActor`
  - `Timer`（`Constants.monitoringInterval`、デフォルト 5 秒）で定期走査
  - `start()` / `pause()` / `checkNow()`
  - 各 tick: `ClaudeDetector.detect()` → `AppState` 更新 → `reconcile()`
  - `reconcile()`: `isClaudeRunning && !active → acquire`、`!isClaudeRunning && active → release`、結果を `isSleepAssertionActive` に反映
  - `pause()`: Timer 無効化 + アサーション解除 + `isMonitoringPaused = true`
  - `start()` / resume: Timer 起動 + 即時 `checkNow()` + `isMonitoringPaused = false`
  - paused 中は走査・検出更新を行わない

## Acceptance Criteria

- 監視中、デフォルト 5 秒間隔で走査する。間隔は定数で将来変更可能（**AC-4**）。
- Pause で監視停止＆保有アサーション解除（**AC-13**）。
- Resume で監視再開＋即時 1 回検出（**AC-14**）。
- Check Now で間隔を待たず即時検出・状態更新（**AC-15**）。
- Paused 中は定期走査せず検出状態を更新しない（**AC-16**）。
- `isSleepAssertionActive` が常に実際のアサーション保有と一致する（**AC-12** 再掲）。

## メモ

- 「検出」と「抑止」を分離し、reconcile は差分のみ反映（design §2）。
- ps 実行は短時間のため同期実行で可。
