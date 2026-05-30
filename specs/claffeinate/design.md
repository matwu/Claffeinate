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
| 言語 | Swift（Xcode プロジェクトの `SWIFT_VERSION`、`@MainActor` で明示分離） | macOS ネイティブ標準。当初 SwiftPM の Swift 6 言語モードで実装し、Xcode 移行後も同コードがクリーンビルド |
| UI | SwiftUI + `MenuBarExtra` | メニューバー常駐アプリの標準。最小コードで実現（macOS 13+） |
| 常駐制御 | AppKit `NSApplication.setActivationPolicy(.accessory)` | Dock 非表示・メニューバー常駐 |
| スリープ抑止 | 特権 helper 経由の `IOPMSetSystemPowerSetting("SleepDisabled", …)` | **蓋閉じ（clamshell）スリープも止める唯一の手段**。`pmset disablesleep` の実体。root 必須のため helper 経由 |
| 特権取得 | `SMAppService.daemon`（macOS 13+） | 配布アプリで root daemon を登録する Apple 標準 API（旧 `SMJobBless` の後継）。初回のみ認証 |
| app⇄helper IPC | `XPC`（`NSXPCConnection`） | OS 標準のプロセス間通信。署名要件で接続元を固定 |
| 復帰保証 | heartbeat watchdog + helper 起動時リセット | `SleepDisabled` は自動回収されないため、クラッシュ時も helper 側で自動的に `false` へ戻す（Constitution §3.3） |
| プロセス検出 | `/bin/ps` を `Process` で実行しパース | 追加権限・依存不要で全プロセスのコマンドライン・親子関係・CPU 時間を取得可能 |
| 処理中（アクティブ）判定 | `ps` の累積 CPU 時間の走査間差分（プロセス＋子孫サブツリー）＋アイドル猶予期間 | 追加権限・依存なしで「存在」と「処理中」を区別。モデル応答待ち等のローカル idle 区間は猶予期間で吸収（ADR-T8） |
| 設定の永続化 | `UserDefaults` | アイドル猶予期間のユーザー選択を再起動間で保持。OS 標準・依存なし（AC-4a） |
| 依存ライブラリ | なし | Constitution §3.5（`SMAppService` は OS 標準フレームワーク） |
| ビルド/配布 | Xcode プロジェクト（`Claffeinate.xcodeproj`）→ `.app` バンドル + 埋め込み helper、Developer ID 署名 + 公証 | `SMAppService` daemon は署名済み `.app` バンドルへの埋め込みが前提のため Xcode をビルドシステムに採用 |

## 2. アーキテクチャ概要

**2 プロセス構成**: 非特権のメインアプリ（UI・検出・監視）と、root で常駐する特権 helper（`SleepDisabled` の実操作）を XPC で接続する。状態は引き続きアプリ側の 1 箇所（`AppState`）に集約し、各コンポーネントは単方向に依存する。

```
┌──────────────────────── Claffeinate.app（非特権）────────────────────────┐
│   ┌────────────────────────────────────────────┐                          │
│   │              ClaffeinateApp                 │                          │
│   │  @main SwiftUI App + MenuBarExtra scene     │                          │
│   │  AppDelegate: setActivationPolicy(.accessory)│                          │
│   │              applicationWillTerminate ──────┼──► release（SleepDisabled=0）│
│   └───────────────┬─────────────────────────────┘                          │
│                   │ owns                                                    │
│                   ▼                                                         │
│   ┌────────────────────────────────────────────┐  ← ObservableObject（SSoT）│
│   │                 AppState                    │                          │
│   │  isClaudeRunning / isClaudeActive           │                          │
│   │  isSleepAssertionActive / isMonitoringPaused│                          │
│   │  lastDetectedProcess / isHelperConnected    │                          │
│   │  gracePeriodMinutes（UserDefaults 永続化）   │                          │
│   └───┬───────────────────┬─────────────────┬───┘                          │
│       │ drives            │ uses            │ renders                       │
│       ▼                   ▼                 ▼                               │
│ ┌───────────────┐  ┌────────────────┐ ┌──────────────┐                     │
│ │ ProcessMonitor│  │ SleepController│ │  MenuContent │                     │
│ │ Timer(5s)     │  │ acquire/release│ │  SwiftUI View│                     │
│ │ → Detector    │  │  + heartbeat   │ │  メニュー項目 │                     │
│ │ → ActivitySampler                  │ │  + 猶予期間Picker                  │
│ └──────┬────────┘  └───────┬────────┘ └──────────────┘                     │
│        │ uses              │ XPC（NSXPCConnection）                         │
│        ▼                   │  setDisableSleep(_:reply:) / ping(reply:)      │
│ ┌───────────────┐ ┌───────────────┐  │                                     │
│ │ ClaudeDetector│ │ ActivitySampler│ │                                     │
│ │ 存在＋PIDツリー │ │ CPU差分＋猶予  │  │                                     │
│ └───────────────┘ └───────────────┘  │                                     │
└────────────────────────────┼───────────────────────────────────────────────┘
                             ▼
┌──────────── com.matwu.Claffeinate.Helper（root daemon / SMAppService）──────┐
│  HelperProtocol を実装した XPC リスナ                                        │
│   setDisableSleep(true/false) → IOPMSetSystemPowerSetting("SleepDisabled",…) │
│   ping() → heartbeat 受信。タイムアウトで自動的に SleepDisabled=0（watchdog） │
│   起動時: SleepDisabled=0 にリセット（残留一掃）                              │
│  接続元は app の署名要件（code requirement）で固定                            │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 制御の流れ（1 tick）

```
Timer fires (5s)  or  Check Now  or  Resume
        │
        ▼
 isMonitoringPaused == true ? ──yes──► 何もしない（検出更新なし）
        │ no
        ▼
 ClaudeDetector.detect() → (found, process, rootPIDs, table)   ← 存在 + プロセステーブル
        │
        ▼
 AppState.isClaudeRunning = found ; lastDetectedProcess = process
        │
        ▼
 ActivitySampler.sample(rootPIDs, table, gracePeriod) → active: Bool   ← 処理中判定
   ・サブツリー（roots + 子孫）の累積 CPU 時間の前回比増分を集計
   ・増分/間隔 ≥ activityCPUThreshold なら活動あり → lastActiveAt 更新 → true
   ・活動なしでも (now − lastActiveAt) < gracePeriod なら true（idle 区間を吸収）
   ・初回（前回サンプルなし）は true（安全側＝起きたまま）
        │
        ▼
 AppState.isClaudeActive = active
        │
        ▼
 reconcile():
   active && !held  → SleepController.acquire()  → XPC setDisableSleep(true)  → isSleepAssertionActive = true
  !active &&  held  → SleepController.release()  → XPC setDisableSleep(false) → isSleepAssertionActive = false
```

「検出（存在）」「処理中判定」「抑止」を分離する。`ClaudeDetector` は状態を持たない純粋走査、`ActivitySampler` は走査間の差分・猶予タイマを保持する唯一のステートフル要素、`reconcile()` は `isClaudeActive` と `isSleepAssertionActive` の差分のみを実体（helper 上の `SleepDisabled`）に反映する。抑止のトリガを「存在」ではなく「処理中（`isClaudeActive`）」に変えた点が本改訂の要（AC-5a / AC-9 / AC-10）。`SleepController` は現行 `SleepAssertion` と同一の `acquire()` / `release()` API のままで、`reconcile()` の判定条件のみ差し替えている。

## 3. コンポーネント設計

### 3.1 `Constants.swift`
- `monitoringInterval: TimeInterval = 5`（AC-4。定数化・将来変更可能）
- `assertionReason = "Claffeinate: Claude is running"`
- 検出キーワード定義（`claude`, `claude-code`, `node` + `claude`）
- **アクティブ判定（AC-5a）**: `activityCPUThreshold`（処理中とみなす最小 CPU 使用率＝1 コア相当に対する走査間隔あたりの割合。TUI 描画等の微小 CPU を拾わない値）
- **アイドル猶予期間（AC-4a）**: `defaultActivityGracePeriod = 30 * 60`、`gracePeriodPresetsMinutes`（メニューの選択肢）、`gracePeriodDefaultsKey`（`UserDefaults` キー）
- `helperBundleID = "com.matwu.Claffeinate.Helper"`、`heartbeatInterval`、`helperWatchdogTimeout`（watchdog タイムアウト。`heartbeatInterval` の数倍に設定。AC-22）

### 3.2 `AppState.swift`（`@MainActor` `ObservableObject`）
- `@Published var isClaudeRunning`（存在）, `isClaudeActive`（処理中。AC-5a）, `isSleepAssertionActive`, `isMonitoringPaused`, `lastDetectedProcess`, `isHelperConnected`
- `@Published var gracePeriodMinutes: Int`（AC-4a）: `didSet` で `UserDefaults` に書き戻し、`init` で読み出す（未設定時はデフォルト 30）。`var gracePeriod: TimeInterval` で秒に換算。
- 状態の唯一の持ち主。View / Monitor から参照・更新される。
- 状態遷移メソッドは持たず、Monitor 側のロジックが更新する（状態は受動的なデータ。`gracePeriodMinutes` の永続化のみ例外的に State が担う）。

### 3.3 `ClaudeDetector.swift`（状態を持たない純粋ロジック）
- `func detect() -> DetectionResult`（`isRunning`, `process`, `rootPIDs`, `table`）
- `/bin/ps -axo pid=,ppid=,cputime=,comm=,args=` を `Process` で実行し、各行を `(pid, ppid, cputime, comm, args)` にパース。`cputime` は `[DD-]HH:MM:SS` / `MM:SS.cc` 形式を秒（`Double`）に変換。
- 判定:
  1. `comm` の basename を小文字化 → `claude` を含む（`claude` / `Claude` / `claude-code` を網羅）なら一致。
  2. または basename が `node` で `args`（小文字化）に `claude` を含むなら一致。
  3. 自 PID（`ProcessInfo.processInfo.processIdentifier`）は除外（AC-8）。
- 一致したすべての PID を `rootPIDs` に集め、最初の一致を `process = "PID 名称"` として返す。全プロセスを `table: [pid: ProcessSample(pid, ppid, cpuSeconds)]` に記録し、`ActivitySampler` がサブツリーを辿れるようにする（自 PID も table には含めるが root 判定からは除外）。
- ※ `claffeinate` は `claude`（c-l-a-u-d-e）を部分文字列として含まないため自己誤検出しない。加えて自 PID も除外。

### 3.3a `ActivitySampler.swift`（唯一のステートフル要素・`@MainActor`）
- `func sample(rootPIDs:table:gracePeriod:now:) -> Bool` — Claude が**処理中**かを返す（AC-5a）。
- 内部状態: `previous: [pid: 累積 CPU 秒]`（前回走査）、`lastActiveAt: Date?`（最後に活動を観測した時刻）。
- アルゴリズム:
  1. `rootPIDs` 空 → 状態をクリアして `false`（Claude なし）。
  2. `table` の `ppid` から子マップを構築し、`rootPIDs` の**サブツリー**（roots + 全子孫）の PID 集合を求める。Claude が起動する子プロセス（ビルド・テスト・grep 等）の CPU も活動として数える。
  3. サブツリー各 PID の累積 CPU 秒を集計。**前回も観測していた PID のみ**差分を取る（新規子プロセスの生涯 CPU を 1 区間のスパイクと誤らないため）。今回値を `previous` に保存。
  4. 初回（前回サンプルなし）→ `lastActiveAt = now` で `true`（安全側＝起きたまま）。
  5. `増分 / monitoringInterval ≥ activityCPUThreshold` → 活動あり、`lastActiveAt = now`、`true`。
  6. 活動なしでも `now − lastActiveAt < gracePeriod` → `true`（モデル応答待ち等のローカル idle 区間を吸収）。それ以外は `false`。
- `func reset()` — `pause()` 時に呼び、再開時に新しいベースラインから始める（AC-13/14）。

### 3.4 `SleepController.swift`（旧 `SleepAssertion`／helper の XPC クライアント）
- 旧 `SleepAssertion` を置き換える。**API は互換**（`acquire()` / `release()` / `private(set) var isActive`）に保ち、`ProcessMonitor` を無改修にする。
- 内部で `HelperClient` を保持し、抑止の実体を helper に委譲する:
  - `func acquire()`: 未保有なら helper に `setDisableSleep(true)`。成功（XPC reply 成功）時のみ `isActive = true`。heartbeat 送出を開始。
  - `func release()`: 保有中なら helper に `setDisableSleep(false)`。`isActive = false`。heartbeat 送出を停止。
- 二重 acquire / 二重 release を内部でガードし冪等にする（AC-12 / AC-9 / AC-10）。
- helper 未接続・XPC 失敗時は `isActive` を `true` にしない（AC-12b：実体のない「Active」を出さない）。

### 3.5 `HelperClient.swift`（新規・app 側 XPC クライアント）
- 起動時に `SMAppService.daemon(plistName:)` で helper を登録（未登録時のみ。AC-12a）。状態 `.requiresApproval` ならユーザーを設定アプリへ誘導。
- `NSXPCConnection` を確立し `HelperProtocol` をリモートインターフェースとして設定。切断時は再接続。
- `setDisableSleep(_:)` / `ping()` を helper に転送。接続状態を `AppState.isHelperConnected` に反映。
- heartbeat: 抑止有効中は数秒ごとに `ping()` を送る（watchdog の餌。AC-21）。

### 3.6 `HelperProtocol.swift`（新規・app/helper 共有）
- `@objc protocol HelperProtocol`：
  - `func setDisableSleep(_ on: Bool, reply: @escaping (Bool) -> Void)`
  - `func ping(reply: @escaping () -> Void)`
- app ターゲットと helper ターゲットの双方からコンパイルされる共有ソース。

### 3.7 `ClaffeinateHelper`（新規・root daemon ターゲット）
- `SMAppService` で登録される launchd daemon。`NSXPCListener` で `HelperProtocol` を公開。
- `newConnection` で接続元の **code requirement（app の署名要件）を検証**し、不一致なら拒否。
- `setDisableSleep`: `IOPMSetSystemPowerSetting("SleepDisabled", on ? kCFBooleanTrue : kCFBooleanFalse)` を実行し結果を reply。
- **watchdog**: 最後の `ping` から `Constants.helperWatchdogTimeout` 経過で自動的に `SleepDisabled=0`（AC-22）。
- **起動時リセット**: 起動直後に `SleepDisabled=0`（AC-23）。

### 3.8 `ProcessMonitor.swift`（`@MainActor`）
- `Timer.scheduledTimer(withTimeInterval: Constants.monitoringInterval, repeats: true)`
- `func start()` / `func pause()` / `func checkNow()`
- 各 tick で 3.3（`detect`）→ 3.3a（`sample`）の順に呼ぶ: `isClaudeRunning = result.isRunning`、`isClaudeActive = sampler.sample(rootPIDs, table, gracePeriod: state.gracePeriod)` を `AppState` に反映し `reconcile()` を呼ぶ。
- `reconcile()` は `isClaudeActive`（処理中）を基準に `acquire()` / `release()` する（旧版は `isClaudeRunning` 基準だった。AC-5a / AC-9 / AC-10）。
- `pause()` 時は Timer 無効化＋抑止解除＋`isClaudeActive = false`＋`sampler.reset()`（AC-13）。
- `start()` / `resume()` 時は Timer 起動＋即時 1 回 `checkNow()`（AC-14）。
- 抑止の実体は引き続き `SleepController`（helper 委譲）に委ねる。本改訂での変更は「サンプラー結線」と「reconcile の判定基準を活動へ変更」の 2 点のみ。

### 3.9 `MenuContent.swift`（SwiftUI View）
- `MenuBarExtra` の content。`@EnvironmentObject`（または `@ObservedObject`）で `AppState` を参照。
- 表示: タイトル、Status 行（Claude: `Detected (Active)` / `Detected (Idle)` / `Not Detected`（AC-5a/AC-17）/ Sleep Prevention / Monitoring / **Helper 接続状態**）、区切り、Pause/Resume、Check Now、**アイドル猶予期間サブメニュー**（`Constants.gracePeriodPresetsMinutes` を列挙し現在値にチェック。選択で `state.gracePeriodMinutes` を更新＝永続化。AC-4a）、区切り、Quit。
- helper 未接続時はその旨を表示（AC-12b）。
- Quit は「解除してから terminate」を行うアクションに紐づける。

### 3.10 `ClaffeinateApp.swift`（`@main`）
- `MenuBarExtra("Claffeinate", systemImage: ...) { MenuContent() }`
- `@NSApplicationDelegateAdaptor` で `AppDelegate` を接続:
  - `applicationDidFinishLaunching`: `setActivationPolicy(.accessory)`（Dock 非表示・AC-2）、helper 登録（AC-12a）、Monitor 起動。
  - `applicationWillTerminate`: `SleepController.release()`（helper 経由で `SleepDisabled=0`。AC-19/20）。
- メニューバーアイコンは抑止状態に応じて見た目を変える（active 時はハイライト系シンボル）。

## 4. 技術的意思決定（ADR 相当）

### ADR-T1: スリープ抑止に IOPMAssertion を採用（pmset を不採用） — **Superseded by ADR-T5（2026-05-30）**
- **当初決定**: `IOPMAssertionCreateWithName` + `kIOPMAssertionTypeNoIdleSleep` を使用。
- **当初理由**: sudo 不要、ユーザー単位、プロセス終了で OS が自動回収（解除漏れに強い）、`caffeinate` 同等の正攻法。
- **失効理由**: Power Management Assertion は**アイドルスリープしか止められず、蓋を閉じると（clamshell sleep）眠ってしまう**ことが判明。蓋閉じでもタスクを継続したいという実利用要件を満たせない。蓋閉じ抑止には `SleepDisabled` が唯一の手段であり、ADR-T5 へ移行。constitution も v2.0.0 で §3.1 を改正済み。

### ADR-T2: 抑止対象はシステムスリープ（ディスプレイスリープは抑止しない）
- **決定**: システムスリープ（アイドル + 蓋閉じ）を抑止する。ディスプレイスリープは抑止しない。
- **理由**: 用途は「処理継続」。画面は消えてよい。常時ディスプレイ点灯はバッテリー浪費で Constitution §2 安全性に反する。`SleepDisabled` はディスプレイスリープには影響しないため本方針と整合する。

### ADR-T3: 検出は `ps` パース（`libproc` / `NSWorkspace` を不採用）
- **決定**: `/bin/ps` を実行してコマンドラインを取得・パース。
- **理由**: `NSWorkspace.runningApplications` は GUI アプリしか拾えず、CLI の `claude` / `node` を検出できない。`ps` は追加権限・依存なしに全プロセスのフルコマンドラインを取得でき要件（AC-5/6）を満たす。`libproc` は C API で複雑。シンプルさ（§2.3）を優先。

### ADR-T4: SwiftPM executable で配布（Xcode プロジェクトを不採用） — **Superseded by ADR-T6（2026-05-30）**
- **当初決定**: `Package.swift`（`swift-tools-version: 6.2`）の executable target。`swift run` で起動検証。
- **失効理由**: `SMAppService` daemon は署名済み `.app` バンドルに helper を埋め込む構成が前提で、素の SwiftPM executable では登録できない。配布要件（Developer ID 署名 + 公証）とあわせ、Xcode プロジェクト + `.app` バンドルへ移行（ADR-T6）。
- **補足**: `@MainActor` による状態・UI・監視の隔離は引き続き有効で、strict concurrency でクリーンビルドする（§5 参照）。

### ADR-T5: lid-close 抑止に `SleepDisabled` を特権 helper 経由で操作
- **決定**: 抑止の実体を `IOPMSetSystemPowerSetting("SleepDisabled", …)` とし、root 権限が要るため特権 helper 経由で実行する。
- **理由**: 蓋閉じスリープを止める手段は OS 上 `SleepDisabled` のみ（`pmset disablesleep` の実体）。アイドル専用の Power Management Assertion では要件を満たせない（ADR-T1 失効）。
- **安全装置**: `SleepDisabled` は自動回収されないため、heartbeat watchdog（ADR-T7）と helper 起動時リセットで復帰を保証（Constitution §3.3）。
- **代替案**: `sudo pmset` を毎回 subprocess 実行 → 毎回認証 or sudoers 改変が必要で配布不可。AppleScript 管理者ダイアログ → ON のたびに認証プロンプトで UX 不良。いずれも不採用。

### ADR-T6: 特権取得は `SMAppService` daemon + XPC、配布は Developer ID 署名 + 公証
- **決定**: helper を `SMAppService.daemon` で登録し、app⇄helper を `XPC`（`NSXPCConnection`）で接続。`.app` バンドル化し Developer ID で署名・公証する。
- **理由**: 配布アプリが root 操作を行う Apple 標準・推奨の構成。初回に一度だけ認証すれば以降プロンプトなし。旧 `SMJobBless` は非推奨のため後継の `SMAppService`（macOS 13+）を採用。接続元は code requirement で固定し、悪意あるプロセスからの helper 悪用を防ぐ。
- **代替案**: NOPASSWD sudo（sudoers をユーザー機で改変、配布不可）、`SMJobBless`（非推奨）。不採用。
- **実装メモ（2026-05-30）**: ビルドシステムは **Xcode プロジェクト**（リポジトリ直下の `Claffeinate.xcodeproj`, objectVersion 77 / synchronized groups）に一本化。当初の SwiftPM（`Package.swift` / `Sources/` / `build.sh` / C シムターゲット）は撤去した。2 ターゲット構成（app `Claffeinate/` + Command Line Tool helper `ClaffeinateHelper/`）。helper は launchd plist を `Contents/Library/LaunchDaemons/`、実行ファイルを `Contents/MacOS/` に Copy Files で埋め込む。非公開 SPI `IOPMSetSystemPowerSetting` は **bridging header**（`ClaffeinateHelper/ClaffeinateHelper-Bridging-Header.h`）で解決。app は **App Sandbox 無効**（特権 daemon の要件）。一度きりの Xcode 配線手順は Issue [#7](https://github.com/matwu/Claffeinate/issues/7)（CLOSED・適用済み）、署名・公証・配布の runbook は Issue [#6](https://github.com/matwu/Claffeinate/issues/6)（旧 `XCODE_SETUP.md` / `RUNBOOK.md`）。app ターゲットは `xcodebuild` でコンパイル確認済み、helper ソースは `swiftc`（bridging header + IOKit リンク）で確認済み。helper ターゲット配線・署名・公証・daemon 登録・蓋閉じ実挙動はユーザー側で要検証。

### ADR-T8: 「処理中」判定をプロセス CPU 活動 + アイドル猶予期間で行う（フックを不採用）
- **決定**: スリープ抑止のトリガを「Claude プロセスの存在」から「Claude が実際に処理中か」へ変更する。処理中は Claude プロセス（＋子孫サブツリー）の累積 CPU 時間の走査間差分で推定し、活動が途切れてもユーザー設定のアイドル猶予期間（デフォルト 30 分）内はアクティブを維持する。
- **理由**: プロセスが立ち上がっているだけ（プロンプトで入力待ちのアイドル）でも抑止が効くと、無駄なスリープ抑止・バッテリー消費になる。一方、観測できるローカル信号は CPU 活動が最も汎用的（`claude` / `claude-code` / `node` いずれにも効き、追加権限・依存なし）。
- **最重要トレードオフ（誤スリープ回避）**: モデル応答待ちなどローカル CPU がほぼゼロの区間を「アイドル」と誤判定して抑止解除すると、**長時間タスクの途中で Mac が眠りタスクが死ぬ**（最悪ケース、spec §7）。これを避けるため猶予期間を設け、活動を一度でも観測したら猶予期間ぶんアクティブを維持する。デフォルトを 30 分と長めに取り、誤スリープ側のリスクを十分小さくする。代償（Claude 終了後も猶予期間ぶん抑止が残る）はユーザーが猶予期間で調整可能（AC-4a）。
- **代替案（不採用）**: ①Claude Code フック（`UserPromptSubmit`→busy / `Stop`→idle）で状態ファイルを書く案。通信待ちも含め最も正確だが、Claude Code CLI 限定かつフック登録という外部設定が必須で、デスクトップアプリ等に効かない。本アプリは「設定なしで動く」ことを優先し CPU 方式を採用した。②瞬間 `%cpu`（ps の減衰平均）で判定。差分計算より不正確で猶予制御と相性が悪い。
- **しきい値・猶予の調整**: `activityCPUThreshold` と `gracePeriodMinutes` は定数／ユーザー設定として外出しし、実利用に応じて調整可能とする。

### ADR-T7: heartbeat watchdog による解除保証
- **決定**: 抑止有効中は app が helper へ定期 `ping`。helper は一定時間 ping が途絶えたら自動で `SleepDisabled=0` に戻す。helper 起動時にも `0` にリセット。
- **理由**: `SleepDisabled` は OS が自動回収しないため、app のクラッシュ／強制終了でそのまま残ると Mac が永遠に眠らない。watchdog でこの最悪ケースを自動復旧し Constitution §2.1・§3.3 を満たす。
- **トレードオフ**: watchdog タイムアウト経過までは抑止が残る窓があるが、許容範囲（spec §7）。

## 5. 並行性・安全性

- `AppState` / `ProcessMonitor` / UI は `@MainActor`。Timer コールバックもメインスレッド。状態更新は単一スレッドで競合なし。XPC reply はメインアクターへホップして `AppState` を更新する。
- `SleepController` の acquire/release は冪等。`reconcile()` は差分のみ反映するため重複呼び出しに耐える。helper の `setDisableSleep` も冪等（同値書き込みは無害）。
- **復帰保証（最重要・Constitution §3.3）**: `SleepDisabled` は自動回収されないため、三重で `0` への復帰を保証する。
  1. **正常終了**: Quit / OS 終了は `applicationWillTerminate` を通り `SleepController.release()`（→ helper で `0`）。Quit は `NSApplication.terminate(nil)` を呼び、直接 exit しない（AC-19/20）。
  2. **クラッシュ／強制終了**: app からの heartbeat が途絶え、helper の watchdog が `helperWatchdogTimeout` 経過で自動的に `0`（AC-22）。
  3. **helper 起動時**: 残留状態を一掃するため最初に `0` にリセット（AC-23）。
- **接続元検証**: helper は `newConnection(_:)` で接続プロセスの code requirement（app の署名要件）を検証し、不一致は拒否。第三者プロセスが helper を悪用して `SleepDisabled` を立てることを防ぐ。

## 6. テスト・検証方針

- **静的**: ビルドがエラーなく通ること（app + helper の両ターゲット）。
- **手動（design ⇄ spec AC 対応）**: [tasks.md](./tasks.md) の検証手順に従い、Claude 起動 → `pmset -g` の `SleepDisabled` が `1` → **蓋を閉じても眠らない** → Claude 終了で `0` に戻る、を確認。
- **復帰保証の検証**: 抑止中に app を強制終了（`kill -9`）→ watchdog タイムアウト後に `SleepDisabled` が `0` に戻ることを確認（AC-22）。helper 再起動で `0` リセットを確認（AC-23）。
- 自動テストは MVP 範囲外（純粋ロジックの `ClaudeDetector` は将来ユニットテスト可能な形に保つ）。

---

## 改訂履歴

| 日付 | 変更内容 | 変更者 |
| --- | --- | --- |
| 2026-05-30 | 初版 (approved) | @matwu |
| 2026-05-30 | lid-close 抑止対応。抑止機構を特権 helper 経由の `SleepDisabled` に刷新（`SleepController`/`HelperClient`/`HelperProtocol`/`ClaffeinateHelper` 追加）。ADR-T1/T4 を Superseded 化し ADR-T5/T6/T7 追加。配布を `.app` + Developer ID 署名/公証に変更（constitution v2.0.0 準拠） | @matwu |
| 2026-05-30 | 処理中（アクティブ）判定を追加。`ClaudeDetector` を ppid/cputime 取得＋サブツリー対応に拡張、`ActivitySampler`（CPU 差分＋アイドル猶予期間）を新設、`ProcessMonitor.reconcile()` の判定基準を存在→アクティブに変更、`MenuContent` に Active/Idle 表示と猶予期間 Picker、`AppState` に `isClaudeActive`/`gracePeriodMinutes`（UserDefaults 永続化）を追加。ADR-T8 追加（CPU+猶予方式、フック不採用） | @matwu |
