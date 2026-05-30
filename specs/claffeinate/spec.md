---
spec_id: claffeinate
title: Claffeinate — Claude 稼働中のみスリープを抑止するメニューバーアプリ
status: approved
owner: "@matwu"
created: 2026-05-30
updated: 2026-05-30
related_design: ./design.md
related_tasks: ./tasks.md
implementation_repo: this repository (Sources/Claffeinate)
---

# Claffeinate — Claude 稼働中のみスリープを抑止するメニューバーアプリ

> **目的**: Claude / Claude Code が動作している間だけ Mac のアイドルスリープを抑止し、Claude が止まれば抑止も解除する。ユーザーが長時間タスクを Claude に任せている間、手を触れなくても Mac が眠らないようにする。

---

## 1. 背景 / Why

Claude Code に長時間のビルド・調査・リファクタリングを任せると、ユーザーが操作しない時間が続き Mac がアイドルスリープに入る。スリープに入ると実行中のタスクが中断・遅延しうる。

既存の回避策には問題がある:

- `caffeinate` を手動起動 → 終了し忘れて常時スリープ抑止になる（バッテリー浪費）
- `sudo pmset -a disablesleep 1` → sudo が必要・戻し忘れリスク・macOS アプリとして不自然

そこで「**Claude が動いている間だけ**自動でスリープを抑止し、**止まれば自動で解除**する」常駐アプリが必要。OS 標準の Power Management Assertion を使うことで sudo 不要・解除保証・OS 作法準拠を満たす。

- 関連規範: [Constitution §1](../constitution.md), [§3.1〜§3.3](../constitution.md)
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
- 検出時の Power Management Assertion 作成、非検出時の解除
- メニューでの状態表示（Claude 検出 / 抑止状態 / 監視状態）
- 監視の Pause / Resume、Check Now（即時チェック）
- アプリ終了時のアサーション確実解除

### この仕様に含まないもの（明示）

- Claude / Claude Code 自体の起動・終了・操作 → 対象外（Constitution §5）
- 設定 UI（監視間隔の GUI 変更・検出条件カスタム）→ Future Work。現時点では定数で管理
- ログイン項目への自動登録 → Future Work
- 通知・統計・履歴・永続化 → Future Work
- ディスプレイスリープの抑止 → 対象外（アイドルスリープ＝システムスリープのみ抑止する）
- App Store 配布・署名・公証 → 対象外（ローカルビルド前提）

## 4. 受け入れ基準（EARS 記法）

> 書式: `When <trigger>, the system shall <response>` / `If <condition>, then the system shall <response>` / `While <state>, the system shall <response>`

### 起動・常駐

- **AC-1**: When アプリが起動したとき、システムはメニューバーにアイコンを表示すること。
- **AC-2**: While アプリが動作している間、システムは Dock にアイコンを表示しないこと。
- **AC-3**: When アプリが起動したとき、システムは監視を自動的に開始すること（初期状態は Monitoring: Running）。

### 検出

- **AC-4**: While 監視中、システムはデフォルト 5 秒間隔で実行中プロセスを走査すること。監視間隔は定数として定義され、将来変更可能であること。
- **AC-5**: When 走査時にプロセス名が `claude` / `Claude` / `claude-code`（大文字小文字を区別しない）であるプロセスが存在する場合、システムはそれを Claude 稼働として検出すること。
- **AC-6**: When 走査時にプロセス名が `node` であり、かつそのコマンドライン引数に文字列 `claude` を含むプロセスが存在する場合、システムはそれを Claude 稼働として検出すること。
- **AC-7**: When Claude を検出したとき、システムは検出したプロセス情報（PID と名称）を `lastDetectedProcess` として保持すること。
- **AC-8**: システムは自分自身（Claffeinate プロセス）を Claude として誤検出しないこと。

### スリープ抑止

- **AC-9**: When Claude を検出し、かつ現在アサーションが無効な場合、システムは `IOPMAssertionCreateWithName`（type `kIOPMAssertionTypeNoIdleSleep`）でアサーションを作成し、スリープ抑止を有効化すること。
- **AC-10**: When Claude が検出されなくなり、かつ現在アサーションが有効な場合、システムは `IOPMAssertionRelease` でアサーションを解除すること。
- **AC-11**: While スリープ抑止が有効な間、システムはアイドルスリープに入らないこと（ディスプレイのスリープは抑止しない）。
- **AC-12**: When 抑止状態が変化したとき、システムは内部状態 `isSleepAssertionActive` を実際のアサーション保有状況と一致させること（状態と実体の不一致を起こさない）。

### 監視制御

- **AC-13**: When ユーザーが「Pause Monitoring」を選択したとき、システムは監視を停止し、保有中のアサーションがあれば解除すること（Monitoring: Paused）。
- **AC-14**: When ユーザーが「Resume Monitoring」を選択したとき、システムは監視を再開し、直ちに 1 回検出を実行すること。
- **AC-15**: When ユーザーが「Check Now」を選択したとき、システムは間隔を待たずに即時に 1 回検出を実行し、状態を更新すること。
- **AC-16**: While 監視が一時停止中、システムは定期走査を行わず、検出状態を更新しないこと。

### 状態表示

- **AC-17**: While メニューが開かれている間、システムは以下を表示すること:
  - `Claude: Detected / Not Detected`
  - `Sleep Prevention: Active / Inactive`
  - `Monitoring: Running / Paused`
- **AC-18**: When 状態が変化したとき、メニュー表示は次にメニューを開いた時点で最新の状態を反映すること。

### 終了

- **AC-19**: When ユーザーが「Quit」を選択したとき、または OS からアプリ終了が要求されたとき、システムは保有中のアサーションを解除してから終了すること。
- **AC-20**: クラッシュ（異常終了）を除き、アプリ終了後にスリープ抑止アサーションが残らないこと。

## 5. 状態モデル（要約）

詳細は [design.md](./design.md)。アプリは以下の状態を**混在させず**に管理する。

| 状態 | 型 | 意味 |
| --- | --- | --- |
| `isClaudeRunning` | Bool | 直近の走査で Claude を検出したか |
| `isSleepAssertionActive` | Bool | スリープ抑止アサーションを保有しているか |
| `isMonitoringPaused` | Bool | 監視が一時停止中か |
| `lastDetectedProcess` | String? | 直近に検出したプロセス（PID + 名称）。未検出時は nil |

## 6. UX 原則の遵守確認（Constitution §4）

- [x] メニューバーのみ: Dock 非表示（AC-2）
- [x] 状態の透明性: 検出 / 抑止 / 監視を常時メニューで確認可能（AC-17）
- [x] ユーザー主権: Pause / Resume / Check Now を提供（AC-13〜15）

## 7. 制約 / リスク / オープン質問

- **制約**: プロセス検出は `ps` ベースのため、間隔（5 秒）内に起動・終了した Claude は取りこぼしうる。長時間タスク監視という用途では許容範囲。
- **制約**: `node` プロセスのコマンドラインに `claude` を含むものはすべて検出対象になるため、無関係な node プロセス（例: `claude` を含むパスで動く別物）も誤検出しうる。実害は「不要な抑止」のみで安全側に倒れる。
- **リスク**: クラッシュ時はアサーションが残るが、Power Management Assertion はプロセス終了時に OS が自動回収するため、プロセスが消えれば抑止も解除される（OS 仕様）。よって永続的な残留リスクは低い。
- **オープン質問**: 監視間隔のユーザー設定・検出キーワードの拡張は Future Work とする。

## 8. 影響範囲

- 新規プロジェクトのため既存仕様への影響なし。
- 技術的意思決定（抑止 API・検出方式・UI フレームワーク・配布形態）は [design.md](./design.md) に記録。

---

## 改訂履歴

| 日付 | 変更内容 | 変更者 |
| --- | --- | --- |
| 2026-05-30 | 初版 (approved) | @matwu |
