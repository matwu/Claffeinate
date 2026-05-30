---
spec_id: claffeinate
type: technical-design
title: Claffeinate Technical Design
status: approved
owner: "@matwu"
created: 2026-05-30
updated: 2026-05-30
related_spec: ./spec.md
---

# Claffeinate Technical Design

> [spec.md](./spec.md) の **What** に対する **How**。技術スタック・アーキテクチャ・主要アルゴリズム・技術的意思決定（ADR 相当）を記録する。

---

## 1. 技術スタック

| 項目 | 採用 | 理由 |
| --- | --- | --- |
| 言語 | Swift 6.2（Swift 6 言語モード / strict concurrency） | macOS ネイティブ標準。`Package.swift` は `swift-tools-version: 6.2` を宣言 |
| UI | SwiftUI + `MenuBarExtra` | メニューバー常駐アプリの標準。最小コードで実現（macOS 13+） |
| 常駐制御 | AppKit `NSApplication.setActivationPolicy(.accessory)` | Dock 非表示・メニューバー常駐 |
| スリープ抑止 | IOKit Power Management（`IOPMAssertionCreateWithName` / `IOPMAssertionRelease`） | OS 標準・sudo 不要・プロセス終了時 OS が自動回収 |
| プロセス検出 | `/bin/ps` を `Process` で実行しパース | 追加権限・依存不要で全プロセスのコマンドラインを取得可能 |
| 依存ライブラリ | なし | Constitution §3.5 |
| ビルド | Swift Package Manager（executable target） | Xcode 不要でビルド・実行可能。`swift run` で起動検証できる |

## 2. アーキテクチャ概要

単一プロセス・単一責務。状態を 1 箇所（`AppState`）に集約し、各コンポーネントは単方向に依存する。

```
            ┌────────────────────────────────────────────┐
            │              ClaffeinateApp                 │
            │  @main SwiftUI App + MenuBarExtra scene     │
            │  AppDelegate: setActivationPolicy(.accessory)│
            │              applicationWillTerminate ──────┼──► release
            └───────────────┬─────────────────────────────┘
                            │ owns
                            ▼
            ┌────────────────────────────────────────────┐
            │                 AppState                    │  ← ObservableObject（状態の SSoT）
            │  isClaudeRunning / isSleepAssertionActive   │
            │  isMonitoringPaused / lastDetectedProcess   │
            └───┬───────────────────┬─────────────────┬───┘
                │ drives            │ uses            │ renders
                ▼                   ▼                 ▼
       ┌───────────────┐   ┌────────────────┐  ┌──────────────┐
       │ ProcessMonitor│   │ SleepAssertion │  │  MenuContent │
       │ Timer(5s)     │   │ IOKit wrapper  │  │  SwiftUI View│
       │ → ClaudeDetector  │ create/release │  │  メニュー項目 │
       └──────┬────────┘   └────────────────┘  └──────────────┘
              │ uses
              ▼
       ┌───────────────┐
       │ ClaudeDetector│  ps 実行 + 検出判定（純粋ロジック）
       └───────────────┘
```

### 制御の流れ（1 tick）

```
Timer fires (5s)  or  Check Now  or  Resume
        │
        ▼
 isMonitoringPaused == true ? ──yes──► 何もしない（検出更新なし）
        │ no
        ▼
 ClaudeDetector.detect()  → (found: Bool, process: String?)
        │
        ▼
 AppState.isClaudeRunning = found ; lastDetectedProcess = process
        │
        ▼
 reconcile():
   found && !active  → SleepAssertion.acquire() ; isSleepAssertionActive = true
  !found &&  active  → SleepAssertion.release() ; isSleepAssertionActive = false
```

「検出」と「抑止」を分離し、`reconcile()` が `isClaudeRunning` と `isSleepAssertionActive` の差分のみを実体に反映する。これにより状態と実体の不一致（AC-12）を防ぐ。

## 3. コンポーネント設計

### 3.1 `Constants.swift`
- `monitoringInterval: TimeInterval = 5`（AC-4。定数化・将来変更可能）
- `assertionReason = "Claffeinate: Claude is running"`
- 検出キーワード定義（`claude`, `claude-code`, `node` + `claude`）

### 3.2 `AppState.swift`（`@MainActor` `ObservableObject`）
- `@Published var isClaudeRunning`, `isSleepAssertionActive`, `isMonitoringPaused`, `lastDetectedProcess`
- 状態の唯一の持ち主。View / Monitor から参照・更新される。
- 状態遷移メソッドは持たず、Monitor 側のロジックが更新する（状態は受動的なデータ）。

### 3.3 `ClaudeDetector.swift`（状態を持たない純粋ロジック）
- `func detect() -> DetectionResult`
- `/bin/ps -axo pid=,comm=,args=` を `Process` で実行し、各行を `(pid, comm, args)` にパース。
- 判定:
  1. `comm` の basename を小文字化 → `claude` を含む（`claude` / `Claude` / `claude-code` を網羅）なら検出。
  2. または basename が `node` で `args`（小文字化）に `claude` を含むなら検出。
  3. 自 PID（`ProcessInfo.processInfo.processIdentifier`）は除外（AC-8）。
- 最初に一致したプロセスを `lastDetectedProcess = "PID 名称"` として返す。
- ※ `claffeinate` は `claude`（c-l-a-u-d-e）を部分文字列として含まないため自己誤検出しない。加えて自 PID も除外。

### 3.4 `SleepAssertion.swift`（IOKit ラッパ）
- `private var assertionID: IOPMAssertionID = IOPMAssertionID(0)` と `private(set) var isActive`
- `func acquire()`: 未保有なら `IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep, kIOPMAssertionLevelOn, reason, &assertionID)`。成功時 `isActive = true`。
- `func release()`: 保有中なら `IOPMAssertionRelease(assertionID)`。`isActive = false`、`assertionID = 0`。
- 二重 acquire / 二重 release を内部でガードし冪等にする（AC-12 / AC-9 / AC-10）。

### 3.5 `ProcessMonitor.swift`（`@MainActor`）
- `Timer.scheduledTimer(withTimeInterval: Constants.monitoringInterval, repeats: true)`
- `func start()` / `func pause()` / `func checkNow()`
- 各 tick で 3.3 を呼び、結果を `AppState` に反映し `reconcile()` を呼ぶ。
- `pause()` 時は Timer 無効化＋アサーション解除（AC-13）。
- `start()` / `resume()` 時は Timer 起動＋即時 1 回 `checkNow()`（AC-14）。
- ps 実行は短時間のため同期実行で十分（5 秒間隔・サブ秒で完了）。UI スレッドブロックを避けたい将来要件のため、実行部は差し替え可能に薄く保つ。

### 3.6 `MenuContent.swift`（SwiftUI View）
- `MenuBarExtra` の content。`@EnvironmentObject`（または `@ObservedObject`）で `AppState` を参照。
- 表示: タイトル、Status 3 行、区切り、Pause/Resume（状態に応じtrueトグル）、Check Now、区切り、Quit。
- Quit は「解除してから terminate」を行うアクションに紐づける。

### 3.7 `ClaffeinateApp.swift`（`@main`）
- `MenuBarExtra("Claffeinate", systemImage: ...) { MenuContent() }`
- `@NSApplicationDelegateAdaptor` で `AppDelegate` を接続:
  - `applicationDidFinishLaunching`: `setActivationPolicy(.accessory)`（Dock 非表示・AC-2）、Monitor 起動。
  - `applicationWillTerminate`: `SleepAssertion.release()`（AC-19/20）。
- メニューバーアイコンは抑止状態に応じて見た目を変える（active 時はハイライト系シンボル）。

## 4. 技術的意思決定（ADR 相当）

### ADR-T1: スリープ抑止に IOPMAssertion を採用（pmset を不採用）
- **決定**: `IOPMAssertionCreateWithName` + `kIOPMAssertionTypeNoIdleSleep` を使用。
- **理由**: sudo 不要、ユーザー単位、プロセス終了で OS が自動回収（解除漏れに強い）、`caffeinate` コマンドと同等の正攻法。`pmset -a disablesleep` は sudo 必須・システム全体・戻し忘れリスクがあり Constitution §3.1 に反する。
- **代替案**: `caffeinate` を subprocess 起動 → プロセス管理が二重になり、子プロセス残留リスク。不採用。

### ADR-T2: 抑止タイプは `NoIdleSleep`（`NoDisplaySleep` を不採用）
- **決定**: アイドル（システム）スリープのみ抑止。ディスプレイスリープは抑止しない。
- **理由**: 用途は「処理継続」。画面は消えてよい。常時ディスプレイ点灯はバッテリー浪費で Constitution §2 安全性に反する。

### ADR-T3: 検出は `ps` パース（`libproc` / `NSWorkspace` を不採用）
- **決定**: `/bin/ps` を実行してコマンドラインを取得・パース。
- **理由**: `NSWorkspace.runningApplications` は GUI アプリしか拾えず、CLI の `claude` / `node` を検出できない。`ps` は追加権限・依存なしに全プロセスのフルコマンドラインを取得でき要件（AC-5/6）を満たす。`libproc` は C API で複雑。シンプルさ（§2.3）を優先。

### ADR-T4: SwiftPM executable で配布（Xcode プロジェクトを不採用）
- **決定**: `Package.swift`（`swift-tools-version: 6.2`）の executable target。Swift 6.2 ツールチェインを利用し、Swift 6 言語モード（strict concurrency）でビルドする。
- **理由**: Xcode なしでビルド・`swift run` で即起動検証可能。MenuBarExtra・activationPolicy はコードで完結し Info.plist 不要。配布用 `.app` バンドル化は Future Work。
- **補足**: `@MainActor` による状態・UI・監視の隔離により strict concurrency でも追加対応なくクリーンビルドする（§5 参照）。

## 5. 並行性・安全性

- `AppState` / `ProcessMonitor` / UI は `@MainActor`。Timer コールバックもメインスレッド。状態更新は単一スレッドで競合なし。
- `SleepAssertion` の acquire/release は冪等。`reconcile()` は差分のみ反映するため重複呼び出しに耐える。
- 終了経路は 2 つ（Quit ボタン / OS 終了）。両方が `applicationWillTerminate` を通るよう、Quit は `NSApplication.terminate(nil)` を呼ぶ（直接 exit しない）。これで解除を一元化（AC-19/20）。

## 6. テスト・検証方針

- **静的**: `swift build` がエラーなく通ること。
- **手動（design ⇄ spec AC 対応）**: [tasks.md](./tasks.md) の検証手順に従い、Claude 起動 → `pmset -g assertions` に `PreventUserIdleSystemSleep` が立つ → Claude 終了で消える、を確認。
- 自動テストは MVP 範囲外（純粋ロジックの `ClaudeDetector` は将来ユニットテスト可能な形に保つ）。

---

## 改訂履歴

| 日付 | 変更内容 | 変更者 |
| --- | --- | --- |
| 2026-05-30 | 初版 (approved) | @matwu |
