---
spec_id: claffeinate
title: Claffeinate — Claude 稼働中のみスリープを抑止するメニューバーアプリ
status: approved
owner: "@matwu"
created: 2026-05-30
updated: 2026-05-30
related_design: ./design.md
related_tasks: ./tasks.md
implementation_repo: this repository (Claffeinate.xcodeproj — Claffeinate/ app, ClaffeinateHelper/ daemon)
---

# Claffeinate — Claude 稼働中のみスリープを抑止するメニューバーアプリ

> **目的**: Claude / Claude Code が動作している間だけ Mac のスリープ（**蓋を閉じた状態を含む**）を抑止し、Claude が止まれば抑止も解除する。ユーザーが長時間タスクを Claude に任せている間、手を触れなくても — ノートを閉じても — Mac が眠らないようにする。

---

## 1. 背景 / Why

Claude Code に長時間のビルド・調査・リファクタリングを任せると、ユーザーが操作しない時間が続き Mac がアイドルスリープに入る。スリープに入ると実行中のタスクが中断・遅延しうる。

既存の回避策には問題がある:

- `caffeinate` を手動起動 → 終了し忘れて常時スリープ抑止になる（バッテリー浪費）。さらに `caffeinate` / Power Management Assertion は**アイドルスリープしか止められず、蓋を閉じると（clamshell sleep で）眠ってしまう**。
- `sudo pmset -a disablesleep 1` → 蓋を閉じても眠らないが、毎回 sudo が必要・戻し忘れリスク・macOS アプリとして不自然。

実利用上、ユーザーは「Claude に長時間タスクを任せ、ノートを閉じて持ち運ぶ／離席する」。このとき眠ってはタスクが止まる。よって蓋閉じ（clamshell）スリープの抑止が必須要件となる。これは OS 上 `SleepDisabled` システム設定（`pmset disablesleep` の実体）を立てる以外に方法がなく、root 権限を要する。

そこで「**Claude が動いている間だけ**自動でスリープ（蓋閉じ含む）を抑止し、**止まれば自動で解除**する」常駐アプリが必要。root 権限は、ユーザーが一度だけ認証する特権 helper（`SMAppService` daemon + XPC）で取得し、heartbeat watchdog と起動時リセットで「戻し忘れ＝Mac が永遠に眠らない」を防ぐ。

- 関連規範: [Constitution §1](../constitution.md), [§3.1〜§3.4](../constitution.md)（v2.0.0 で特権 helper 経由の `SleepDisabled` 操作を復帰保証付きで許容）
- 関連設計: [design.md](./design.md)

## 2. ユーザーストーリー

- **開発者（主ユーザー）** として、Claude Code に長時間タスクを任せている間、手を触れなくても Mac が眠らないでほしい。そのために、Claude の稼働を自動検出してスリープを抑止してくれる常駐アプリが欲しい。
- **開発者** として、Claude が終了したら自動でスリープ抑止が解除され、無駄なバッテリー消費が起きないでほしい。
- **開発者** として、いま抑止が効いているか・Claude を検出できているかを、メニューバーからすぐ確認したい。
- **開発者** として、必要なときは監視を一時停止 / 再開でき、即時に状態を再チェックできるようにしたい。

## 3. スコープ

### この仕様に含むもの

- メニューバー常駐アプリ（Dock 非表示）の起動・終了
- 一定間隔（デフォルト 5 秒）でのプロセス監視による Claude 稼働検出
- **Claude が実際に処理中か（アクティブ判定）の検出**: プロセスの存在だけでなく、プロセス（＋子プロセス）の CPU 活動でアイドルと処理中を区別する
- **アイドル猶予期間のユーザー設定**（デフォルト 30 分。メニューから変更・永続化）
- 処理中（アクティブ）検出時のスリープ抑止有効化（**蓋閉じ＝clamshell スリープを含む**）、アイドル化時の解除
- 特権 helper（`SMAppService` daemon）のインストール・XPC 接続・`SleepDisabled` の操作
- heartbeat watchdog・helper 起動時リセットによる復帰保証
- メニューでの状態表示（Claude 検出 / 抑止状態 / 監視状態 / helper 接続状態）
- 監視の Pause / Resume、Check Now（即時チェック）
- アプリ終了時のスリープ抑止確実解除

### この仕様に含まないもの（明示）

- Claude / Claude Code 自体の起動・終了・操作 → 対象外（Constitution §5）
- 設定 UI（監視間隔の GUI 変更・検出条件カスタム）→ Future Work。現時点では定数で管理
- ログイン項目への自動登録 → Future Work
- 通知・統計・履歴・永続化 → Future Work
- ディスプレイスリープの抑止 → 対象外（画面は消えてよい。抑止するのはシステムスリープ＝アイドル + 蓋閉じ）
- App Store 配布 → Future Work（本仕様は Developer ID 署名 + 公証による直接配布を対象とする）

## 4. 受け入れ基準（EARS 記法）

> 書式: `When <trigger>, the system shall <response>` / `If <condition>, then the system shall <response>` / `While <state>, the system shall <response>`

### 起動・常駐

- **AC-1**: When アプリが起動したとき、システムはメニューバーにアイコンを表示すること。
- **AC-2**: While アプリが動作している間、システムは Dock にアイコンを表示しないこと。
- **AC-3**: When アプリが起動したとき、システムは監視を自動的に開始すること（初期状態は Monitoring: Running）。

### 検出

- **AC-4**: While 監視中、システムはデフォルト 5 秒間隔で実行中プロセスを走査すること。監視間隔は定数として定義され、将来変更可能であること。
- **AC-4a**: While 監視中、システムはアイドル猶予期間（下記 AC-5a）をユーザーが変更できる手段（メニュー）を提供し、選択値を永続化（`UserDefaults`）して再起動後も保持すること。デフォルトは 30 分とすること。
- **AC-5**: When 走査時にプロセス名が `claude` / `Claude` / `claude-code`（大文字小文字を区別しない）であるプロセスが存在する場合、システムはそれを Claude プロセスの**存在**（`isClaudeRunning`）として検出すること。
- **AC-5a**: When Claude プロセスを検出していても、そのプロセス（および子孫プロセス）の CPU 活動が走査間隔あたりのしきい値（定数 `activityCPUThreshold`）を下回り、かつ最後に活動を観測してからアイドル猶予期間（`gracePeriod`）が経過している場合、システムはそれを**アイドル**（処理していない）とみなし、**アクティブ**（`isClaudeActive`）を偽とすること。逆に CPU 活動がしきい値以上、または最後の活動から猶予期間内である場合はアクティブを真とすること。スリープ抑止はこの**アクティブ判定**を基準に行うこと（存在だけでは抑止しない）。
  - 補足: 猶予期間は「モデル応答待ちなどローカル CPU がほぼゼロになる区間」でアクティブを維持し、タスク途中の誤スリープ（最悪ケース、§7）を防ぐためのもの。Claude を検出した直後（前回サンプルがない初回走査）はアクティブとして扱い、安全側（起きたまま）に倒すこと。
- **AC-6**: When 走査時にプロセス名が `node` であり、かつそのコマンドライン引数に文字列 `claude` を含むプロセスが存在する場合、システムはそれを Claude プロセスの存在として検出すること。
- **AC-7**: When Claude を検出したとき、システムは検出したプロセス情報（PID と名称）を `lastDetectedProcess` として保持すること。
- **AC-8**: システムは自分自身（Claffeinate プロセス）を Claude として誤検出しないこと。

### スリープ抑止

- **AC-9**: When Claude が**アクティブ**（処理中。AC-5a）と判定され、かつ現在スリープ抑止が無効な場合、システムは特権 helper 経由で `IOPMSetSystemPowerSetting("SleepDisabled", true)` を実行し、スリープ抑止を有効化すること。
- **AC-10**: When Claude が**アクティブでなくなった**（アイドル化または未検出。AC-5a）とき、かつ現在スリープ抑止が有効な場合、システムは特権 helper 経由で `IOPMSetSystemPowerSetting("SleepDisabled", false)` を実行し、解除すること。
- **AC-10a**: When 抑止を解除（`SleepDisabled=false`）した時点で蓋が閉じている（`AppleClamshellState` が真）場合、システムは helper 経由で即座にシステムスリープを発火（`IOPMSleepSystem`）すること。理由: macOS は蓋閉じスリープを蓋イベント時にしか評価せず、抑止中に veto された蓋閉じスリープは `SleepDisabled` を戻しても再評価されないため、明示発火しなければ次の蓋イベントまで Mac が起き続ける。蓋が開いている場合は発火せず、通常のアイドルスリープに委ねること。
- **AC-11**: While スリープ抑止が有効な間、システムはアイドルスリープに入らず、**かつ蓋を閉じても（clamshell でも）スリープに入らないこと**。`pmset -g | grep SleepDisabled` が `1` を示すこと。ディスプレイのスリープは抑止しない。
- **AC-12**: When 抑止状態が変化したとき、システムは内部状態 `isSleepAssertionActive` を helper 上の実際の `SleepDisabled` 値と一致させること（状態と実体の不一致を起こさない）。
- **AC-12a**: When アプリ起動時に特権 helper が未登録の場合、システムは `SMAppService` で helper を登録し、ユーザーに一度だけ認証を求めること。登録済みなら再認証を求めないこと。
- **AC-12b**: If 特権 helper への接続が確立できない場合、then システムはスリープ抑止を有効と表示せず、メニューに helper 未接続である旨を表示すること（実体のない「Active」表示を出さない）。

### 監視制御

- **AC-13**: When ユーザーが「Pause Monitoring」を選択したとき、システムは監視を停止し、保有中のアサーションがあれば解除すること（Monitoring: Paused）。
- **AC-14**: When ユーザーが「Resume Monitoring」を選択したとき、システムは監視を再開し、直ちに 1 回検出を実行すること。
- **AC-15**: When ユーザーが「Check Now」を選択したとき、システムは間隔を待たずに即時に 1 回検出を実行し、状態を更新すること。
- **AC-16**: While 監視が一時停止中、システムは定期走査を行わず、検出状態を更新しないこと。

### 状態表示

- **AC-17**: While メニューが開かれている間、システムは以下を表示すること:
  - `Claude: Detected (Active) / Detected (Idle) / Not Detected`（存在かつ処理中／存在するがアイドル／未検出。AC-5a）
  - `Sleep Prevention: Active / Inactive`
  - `Monitoring: Running / Paused`
  - 現在のアイドル猶予期間（分）と、その変更手段（AC-4a）
- **AC-18**: When 状態が変化したとき、メニュー表示は次にメニューを開いた時点で最新の状態を反映すること。

### 終了・復帰保証

- **AC-19**: When ユーザーが「Quit」を選択したとき、または OS からアプリ終了が要求されたとき、システムは helper 経由で `SleepDisabled` を `false` に戻してから終了すること。
- **AC-20**: アプリの正常終了後にスリープ抑止が残らないこと（`pmset -g` の `SleepDisabled` が `0` に戻る）。
- **AC-21**: While スリープ抑止が有効な間、アプリは helper へ定期的に heartbeat を送出すること。
- **AC-22**: If helper が一定時間（既定: 数十秒、定数化）heartbeat を受信しない場合（＝アプリのクラッシュ／強制終了）、then helper は自動的に `SleepDisabled` を `false` に戻すこと。
- **AC-23**: When 特権 helper（daemon）が起動したとき、helper は最初に `SleepDisabled` を `false` にリセットし、前回の残留状態を一掃すること。

## 5. 状態モデル（要約）

詳細は [design.md](./design.md)。アプリは以下の状態を**混在させず**に管理する。

| 状態 | 型 | 意味 |
| --- | --- | --- |
| `isClaudeRunning` | Bool | 直近の走査で Claude プロセスの**存在**を検出したか |
| `isClaudeActive` | Bool | Claude が実際に**処理中**か（CPU 活動＋猶予期間。AC-5a）。スリープ抑止のトリガ |
| `isSleepAssertionActive` | Bool | スリープ抑止（`SleepDisabled`）が有効か |
| `isMonitoringPaused` | Bool | 監視が一時停止中か |
| `lastDetectedProcess` | String? | 直近に検出したプロセス（PID + 名称）。未検出時は nil |
| `isHelperConnected` | Bool | 特権 helper への XPC 接続が確立しているか |
| `gracePeriodMinutes` | Int | ユーザー設定のアイドル猶予期間（分）。`UserDefaults` に永続化。デフォルト 30（AC-4a） |

## 6. UX 原則の遵守確認（Constitution §4）

- [x] メニューバーのみ: Dock 非表示（AC-2）
- [x] 状態の透明性: 検出 / 抑止 / 監視を常時メニューで確認可能（AC-17）
- [x] ユーザー主権: Pause / Resume / Check Now を提供（AC-13〜15）

## 7. 制約 / リスク / オープン質問

- **制約**: プロセス検出は `ps` ベースのため、間隔（5 秒）内に起動・終了した Claude は取りこぼしうる。長時間タスク監視という用途では許容範囲。
- **制約**: `node` プロセスのコマンドラインに `claude` を含むものはすべて検出対象になるため、無関係な node プロセス（例: `claude` を含むパスで動く別物）も誤検出しうる。実害は「不要な抑止」のみで安全側に倒れる。
- **制約（アクティブ判定 / AC-5a）**: 「処理中」は Claude プロセス（＋子孫）の CPU 時間増分で推定するヒューリスティック。モデル応答待ちなどローカル CPU がほぼゼロの区間は猶予期間で吸収する。猶予期間を長くするほど「タスク途中の誤スリープ」（最悪ケース）は起きにくくなる一方、Claude が本当に止まった後も猶予期間ぶん抑止が残りバッテリーを消費する。このトレードオフはユーザーが猶予期間（デフォルト 30 分）で調整できる（AC-4a）。なお猶予期間内は「無関係 node の誤検出」と同様、実害は「不要な抑止」のみで安全側に倒れる。
- **制約**: CPU 活動による判定は `ps` の累積 CPU 時間の差分に基づくため、しきい値（`activityCPUThreshold`）はアイドル時の TUI 描画などの微小 CPU を「処理中」と誤らない値に保つ必要がある。値は定数化し将来調整可能とする。
- **リスク（最重要）**: `SleepDisabled` は OS が自動回収しない永続システム設定であり、アプリのクラッシュ時にそのまま残ると Mac が永遠に眠らなくなる。これを防ぐため heartbeat watchdog（AC-22）と helper 起動時リセット（AC-23）を**必須の安全装置**とする。watchdog のタイムアウト経過までは抑止が残る窓があるが、許容範囲とする。
- **リスク**: 特権 helper の登録には Developer ID 署名・公証と、app⇄helper の署名要件の相互固定が必要。未署名／要件不一致では helper が起動しない。
- **制約**: lid-close 抑止には root が必要で、初回に一度だけ macOS の認証ダイアログが出る（AC-12a）。以降はプロンプトなし。
- **オープン質問**: watchdog のタイムアウト値・監視間隔のユーザー設定・検出キーワードの拡張は Future Work とする。

## 8. 影響範囲

- 新規プロジェクトのため既存仕様への影響なし。
- 技術的意思決定（抑止 API・検出方式・UI フレームワーク・配布形態）は [design.md](./design.md) に記録。

---

## 改訂履歴

| 日付 | 変更内容 | 変更者 |
| --- | --- | --- |
| 2026-05-30 | 初版 (approved) | @matwu |
| 2026-05-30 | 蓋閉じ（clamshell）スリープ抑止を要件化。抑止機構を特権 helper 経由の `SleepDisabled` に変更し、AC-9〜12 改訂・AC-12a/12b/19/21〜23 追加。配布を Developer ID 署名 + 公証に格上げ（constitution v2.0.0 準拠） | @matwu |
| 2026-05-30 | 「稼働中」を「**処理中（アクティブ）**」に厳密化。プロセスの存在（`isClaudeRunning`）と CPU 活動による処理中判定（`isClaudeActive`）を分離し、抑止のトリガをアクティブ判定に変更。AC-5a（CPU 活動＋猶予期間）・AC-4a（アイドル猶予期間のユーザー設定、デフォルト 30 分・永続化）を追加、AC-5/9/10/17 を改訂。状態モデルに `isClaudeActive` / `gracePeriodMinutes` を追加 | @matwu |
