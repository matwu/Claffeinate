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

### マイルストーン 2: lid-close（蓋閉じ）スリープ抑止（constitution v2.0.0）

> Power Management Assertion ではアイドルスリープしか止まらないため、特権 helper 経由の `SleepDisabled` に刷新する。詳細は [design.md §2〜§5](./design.md), [ADR-T5/T6/T7](./design.md)。

| # | タスク | 主な成果物 | 対応 AC | 依存 | Issue 草案 | GitHub Issue |
| --- | --- | --- | --- | --- | --- | --- |
| 006 | `.app` バンドル化（基盤移行） | Xcode プロジェクト / `.app` ターゲット、Info.plist、エンタイトルメント | ADR-T6 | 005 | （Issue 化済み） | [#7](https://github.com/matwu/Claffeinate/issues/7)（CLOSED・配線済み） |
| 007 | 特権 helper（root daemon） | `HelperProtocol.swift`, `ClaffeinateHelper`（XPC リスナ + `IOPMSetSystemPowerSetting` + watchdog + 起動時リセット + 接続元検証） | AC-11, AC-22, AC-23 | 006 | TBD | — |
| 008 | helper 登録 + XPC クライアント | `HelperClient.swift`（`SMAppService` 登録、`NSXPCConnection`、heartbeat） | AC-12a, AC-12b, AC-21 | 007 | TBD | — |
| 009 | 抑止機構の差し替え | `SleepController.swift`（旧 `SleepAssertion` を API 互換で置換、`reconcile()` 結線） | AC-9, AC-10, AC-12 | 008 | TBD | — |
| 010 | UI 反映 + 署名・公証 | `MenuContent`（helper 状態表示）、Developer ID 署名 + 公証、配布検証 | AC-17, AC-19, AC-20 | 009 | （Issue 化済み） | [#6](https://github.com/matwu/Claffeinate/issues/6)（OPEN・runbook） |

### マイルストーン 3: 処理中（アクティブ）判定

> 「稼働中」を「処理中」に厳密化。プロセスの存在ではなく CPU 活動でアイドル/処理中を区別し、アイドル猶予期間（デフォルト 30 分）をユーザー設定可能にする。詳細は [design.md ADR-T8](./design.md)。

| # | タスク | 主な成果物 | 対応 AC | 依存 | Issue 草案 | GitHub Issue |
| --- | --- | --- | --- | --- | --- | --- |
| 011 | 処理中判定 + 猶予期間設定 | `ActivitySampler.swift`（新規）、`ClaudeDetector`（ppid/cputime＋rootPIDs/table）、`AppState`（`isClaudeActive`/`gracePeriodMinutes`）、`ProcessMonitor`（サンプラー結線・reconcile 基準変更）、`MenuContent`（Active/Idle 表示・猶予期間 Picker）、`Constants` | AC-4a, AC-5a, AC-9, AC-10, AC-17 | 002, 004, 005 | [011](./issues/011-activity-detection.md) | — |

### 依存グラフ

```
マイルストーン 1（完了）:
001 (基盤)
 ├─► 002 (検出) ─┐
 └─► 003 (抑止) ─┴─► 004 (監視+状態) ─► 005 (UI+終了)

マイルストーン 2（lid-close）:
005 ─► 006 (.app化) ─► 007 (helper) ─► 008 (登録+XPC) ─► 009 (SleepController) ─► 010 (UI+署名公証)

マイルストーン 3（処理中判定）:
002 + 004 + 005 ─► 011 (アクティブ判定 + 猶予期間設定)
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
| 011 | `Claffeinate/ActivitySampler.swift`（新規）, `ClaudeDetector.swift`, `AppState.swift`, `ProcessMonitor.swift`, `MenuContent.swift`, `Constants.swift` |

## 検証手順（completion gate）

### マイルストーン 1（IOKit 版・参考）

1. メニューバーにアイコンが出る / Dock に出ない（AC-1, AC-2）。
2. Claude Code を起動 → メニューが `Claude: Detected` / `Sleep Prevention: Active` になる（AC-5/6）。
3. Pause → 監視停止＆解除、Resume → 即時再検出、Check Now → 即時更新（AC-13〜15）。

### マイルストーン 2（lid-close 版・正式）

ビルド成功後、`.app` を起動し以下を確認する（詳細は各 Issue の Acceptance Criteria）。

1. 初回起動で helper 登録の認証ダイアログが一度だけ出る。承認後は再表示されない（AC-12a）。
2. Claude を起動 → メニューが `Sleep Prevention: Active` / `Helper: Connected` になり、`pmset -g | grep -i SleepDisabled` が `1`（AC-9, AC-11）。
3. **ノートの蓋を閉じても眠らない**（電源/外部ディスプレイ不要で継続。AC-11）。
4. Claude 終了 → `Inactive` になり `SleepDisabled` が `0`（AC-10）。
5. 抑止中に app を `kill -9` → watchdog タイムアウト後に `SleepDisabled` が `0` に戻る（AC-22）。
6. Quit → `SleepDisabled` が `0` に戻って終了（AC-19/20）。
7. helper 未接続状態ではメニューに未接続表示が出て、抑止が「Active」と偽表示されない（AC-12b）。

### マイルストーン 3（処理中判定）

1. Claude Code を起動して入力待ち（アイドル）にする → 一定時間（猶予期間）経過後にメニューが `Claude: Detected (Idle)` になり、`Sleep Prevention: Inactive` / `SleepDisabled` が `0`（AC-5a, AC-10）。
2. Claude に処理（ビルド・調査等）をさせる → `Claude: Detected (Active)` になり `Sleep Prevention: Active` / `SleepDisabled` が `1`（AC-5a, AC-9）。
3. 処理が一段落しモデル応答待ちでローカル CPU がほぼゼロになっても、猶予期間内は `Active` を維持しスリープしない（誤スリープ回避）。
4. メニューの「Idle grace period」を変更 → 表示が更新され、アプリ再起動後も選択値が保持される（AC-4a）。
5. 猶予期間を短く（例 5 分）設定し、Claude をアイドルのまま放置 → 猶予期間経過で `Inactive` に落ちる（AC-5a）。

## ステータス

### マイルストーン 1（完了）
- [x] 001 メニューバーアプリ基盤
- [x] 002 Claude 検出ロジック
- [x] 003 スリープ抑止 (IOKit) — ※ lid-close 非対応のため 006〜010 で刷新
- [x] 004 プロセス監視と状態管理
- [x] 005 メニュー UI と終了時解除

### マイルストーン 2: lid-close 抑止（コード実装完了 / 署名・実機検証はユーザー側）
- [x] 006 `.app` バンドル化 — **Xcode プロジェクト**（ルートの `Claffeinate.xcodeproj`）に一本化。SwiftPM（`Package.swift`/`Sources/`/`build.sh`）は撤去。helper ターゲット配線・Copy Files 埋め込み・App Sandbox 無効化まで適用済み（`ClaffeinateHelper` ターゲット存在を確認）。一度きりのセットアップ手順は [#7](https://github.com/matwu/Claffeinate/issues/7) に Issue 化のうえ Close（旧 `XCODE_SETUP.md`）
- [x] 007 特権 helper（`ClaffeinateHelper`: `SleepDisabledManager`/`HelperService`/listener、watchdog、起動時リセット、IOKit SPI shim）
- [x] 008 helper 登録 + XPC クライアント（`HelperClient`: `SMAppService` 登録、`NSXPCConnection`、heartbeat）
- [x] 009 抑止機構の差し替え（`SleepController` が旧 `SleepAssertion` を API 互換で置換、`ProcessMonitor` 無改修）
- [~] 010 UI 反映（`MenuContent` に Helper 状態表示・完了）+ 署名・公証（**Developer ID 必須・ユーザー側で実施**。手順は runbook [#6](https://github.com/matwu/Claffeinate/issues/6)）

> app ターゲットは `xcodebuild` でクリーンビルド確認済み、helper ソースは `swiftc`（bridging header + IOKit リンク）でコンパイル・リンク確認済み。helper ターゲット配線・署名・公証・daemon 登録・蓋閉じ実挙動は Developer ID と実機が必要なため未検証（runbook [#6](https://github.com/matwu/Claffeinate/issues/6) §8）。

### マイルストーン 3: 処理中（アクティブ）判定（コード実装完了 / 実機の挙動検証はユーザー側）
- [x] 011 処理中判定 + 猶予期間設定（`ActivitySampler` 新設、`ClaudeDetector` 拡張、`AppState`/`ProcessMonitor`/`MenuContent`/`Constants` 改修）

> app ターゲットは `xcodebuild -scheme Claffeinate` でクリーンビルド確認済み（`** BUILD SUCCEEDED **`）。CPU しきい値・猶予期間の実利用での妥当性（アイドル誤判定・誤スリープが起きないか）は実機での観察が必要。
