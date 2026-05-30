---
spec_id: claffeinate
type: implementation-plan
title: Claffeinate Implementation Plan & Tasks
status: in-progress
owner: "@matwu"
created: 2026-05-30
updated: 2026-05-30
related_spec: ./spec.md
related_design: ./design.md
---

# Claffeinate Implementation Plan & Tasks

> [spec.md](./spec.md)（What）と [design.md](./design.md)（How）を、実装可能な粒度の Issue に分解したもの。
> 各 Issue は `./issues/00N-*.md` に GitHub 貼り付け可能な形で起こしてある。GitHub Issue を作成した場合は下表の「GitHub Issue」列にリンクする。

## タスク一覧と依存関係

| # | タスク | 主な成果物 | 対応 AC | 依存 | Issue 草案 | GitHub Issue |
| --- | --- | --- | --- | --- | --- | --- |
| 001 | メニューバーアプリ基盤 | `Package.swift`, `ClaffeinateApp.swift`, `AppDelegate`, `Constants.swift` | AC-1, AC-2, AC-3 | なし | [001](./issues/001-menu-bar-app-skeleton.md) | #1 |
| 002 | Claude 検出ロジック | `ClaudeDetector.swift` | AC-5, AC-6, AC-7, AC-8 | 001 | [002](./issues/002-claude-detection.md) | #2 |
| 003 | スリープ抑止 (IOKit) | `SleepAssertion.swift` | AC-9, AC-10, AC-11, AC-12 | 001 | [003](./issues/003-sleep-assertion.md) | #3 |
| 004 | プロセス監視と状態管理 | `ProcessMonitor.swift`, `AppState.swift`, `reconcile()` | AC-4, AC-13〜16 | 002, 003 | [004](./issues/004-process-monitor-and-state.md) | #4 |
| 005 | メニュー UI と終了時解除 | `MenuContent.swift`, 終了処理 | AC-17, AC-18, AC-19, AC-20 | 004 | [005](./issues/005-menu-ui-and-lifecycle.md) | #5 |

### 依存グラフ

```
001 (基盤)
 ├─► 002 (検出) ─┐
 └─► 003 (抑止) ─┴─► 004 (監視+状態) ─► 005 (UI+終了)
```

## 実装順序

1. **001** — ビルドが通る空のメニューバーアプリ（Dock 非表示）を立ち上げる。
2. **002 / 003** — 検出と抑止を独立に実装（互いに非依存、並行可能）。
3. **004** — 002/003 を Timer と AppState で結線し、reconcile で状態を実体に一致させる。
4. **005** — メニューに状態を表示、Pause/Resume/Check Now/Quit を結線、終了時解除を保証。

## 実装とコードの対応関係

| Issue | ソースファイル |
| --- | --- |
| 001 | `Package.swift`, `Sources/Claffeinate/ClaffeinateApp.swift`, `Sources/Claffeinate/Constants.swift` |
| 002 | `Sources/Claffeinate/ClaudeDetector.swift` |
| 003 | `Sources/Claffeinate/SleepAssertion.swift` |
| 004 | `Sources/Claffeinate/ProcessMonitor.swift`, `Sources/Claffeinate/AppState.swift` |
| 005 | `Sources/Claffeinate/MenuContent.swift`, `ClaffeinateApp.swift`（`applicationWillTerminate`） |

## 検証手順（completion gate）

`swift build` 成功後、`swift run` で起動し以下を確認する（詳細は各 Issue の Acceptance Criteria）。

1. メニューバーにアイコンが出る / Dock に出ない（AC-1, AC-2）。
2. Claude Code を起動 → メニューが `Claude: Detected` / `Sleep Prevention: Active` になる（AC-5/6, AC-9）。
3. ターミナルで `pmset -g assertions | grep PreventUserIdleSystemSleep` が立つ（AC-11）。
4. Claude 終了 → `Not Detected` / `Inactive` になりアサーションが消える（AC-10）。
5. Pause → 監視停止＆解除、Resume → 即時再検出、Check Now → 即時更新（AC-13〜15）。
6. Quit → アサーション解除後に終了（`pmset -g assertions` から消える）（AC-19/20）。

## ステータス

- [x] 001 メニューバーアプリ基盤
- [x] 002 Claude 検出ロジック
- [x] 003 スリープ抑止 (IOKit)
- [x] 004 プロセス監視と状態管理
- [x] 005 メニュー UI と終了時解除
