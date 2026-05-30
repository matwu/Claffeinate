# [011] 処理中（アクティブ）判定 + アイドル猶予期間のユーザー設定

**spec:** claffeinate · **対応 AC:** AC-4a, AC-5a, AC-9, AC-10, AC-17 · **依存:** 002, 004, 005

## 概要

スリープ抑止のトリガを「Claude プロセスの**存在**」から「Claude が実際に**処理中**か」へ厳密化する。プロセスが立ち上がっているだけ（プロンプトで入力待ちのアイドル）では抑止せず、Claude プロセス（＋子孫サブツリー）の CPU 活動が観測される間だけ抑止する。モデル応答待ち等でローカル CPU がほぼゼロになる区間は、ユーザー設定の**アイドル猶予期間**（デフォルト 30 分）で吸収し、長時間タスク途中の誤スリープ（最悪ケース）を防ぐ。

設計根拠は [design.md ADR-T8](../design.md) を参照。CPU 方式採用・フック不採用の理由もそこに記載。

## やること

### `ActivitySampler.swift`（新規・唯一のステートフル要素・`@MainActor`）

- [ ] `func sample(rootPIDs:table:gracePeriod:now:) -> Bool` を実装
- [ ] 内部状態 `previous: [Int32: Double]`（前回走査の累積 CPU 秒）と `lastActiveAt: Date?` を保持
- [ ] `table` の `ppid` から子マップを作り、`rootPIDs` のサブツリー（roots + 全子孫）の PID 集合を求める（ビルド/テスト/grep 等の子プロセスの CPU も活動に数える）
- [ ] サブツリーの累積 CPU 秒を集計し、**前回も観測していた PID のみ**差分を取って今回の増分を求める（新規子プロセスの生涯 CPU を 1 区間スパイクと誤らない）。今回値を `previous` に保存
- [ ] 初回（前回サンプルなし）は `lastActiveAt = now` で `true`（安全側＝起きたまま）
- [ ] `増分 / monitoringInterval ≥ Constants.activityCPUThreshold` なら活動あり → `lastActiveAt = now`、`true`
- [ ] 活動なしでも `now − lastActiveAt < gracePeriod` なら `true`（idle 区間の吸収）。それ以外は `false`
- [ ] `rootPIDs` 空のときは内部状態をクリアして `false`
- [ ] `func reset()` を用意（pause 時に呼び、resume で新ベースラインから始める）

### `Constants.swift`

- [ ] `activityCPUThreshold`（処理中とみなす最小 CPU 使用率。TUI 描画等の微小 CPU を拾わない値）
- [ ] `defaultActivityGracePeriod = 30 * 60`、`gracePeriodPresetsMinutes`、`gracePeriodDefaultsKey`

### `AppState.swift`

- [ ] `@Published var isClaudeActive`（処理中）を追加
- [ ] `@Published var gracePeriodMinutes: Int` を追加。`didSet` で `UserDefaults` に保存、`init` で読み出し（未設定はデフォルト 30）。`var gracePeriod: TimeInterval` を提供

### `ProcessMonitor.swift`

- [ ] `ActivitySampler` を保持
- [ ] `checkNow()` で `detect()` → `sample(rootPIDs:table:gracePeriod: state.gracePeriod)` を呼び `isClaudeActive` を更新
- [ ] `reconcile()` の判定基準を `isClaudeRunning` → `isClaudeActive` に変更
- [ ] `pause()` で `isClaudeActive = false` と `sampler.reset()`

### `MenuContent.swift`

- [ ] Claude 行を `Detected (Active)` / `Detected (Idle)` / `Not Detected` に変更
- [ ] アイドル猶予期間のサブメニュー（`gracePeriodPresetsMinutes` を列挙、現在値にチェック、選択で `state.gracePeriodMinutes` を更新＝永続化）

## Acceptance Criteria

- Claude プロセスが存在しても、サブツリーの CPU 活動がしきい値未満かつ最後の活動から猶予期間を超えていれば `isClaudeActive` が偽になり、スリープ抑止が解除される（**AC-5a**, **AC-10**）。
- CPU 活動がしきい値以上、または最後の活動から猶予期間内なら `isClaudeActive` が真で、抑止が有効化される（**AC-5a**, **AC-9**）。
- Claude 検出直後（初回走査）はアクティブ扱いで、即座に抑止が立つ（安全側。**AC-5a**）。
- アイドル猶予期間をメニューから変更でき、選択値が `UserDefaults` に永続化され再起動後も保持される。デフォルトは 30 分（**AC-4a**）。
- メニューの Claude 行が `Detected (Active)` / `Detected (Idle)` / `Not Detected` を正しく表示する（**AC-17**）。

## メモ

- 観測は読み取り専用（`ps`）のみ。対象プロセスには一切触れない（Constitution §3.6）。
- 猶予期間内の「不要な抑止」は安全側の挙動であり許容（spec §7）。誤スリープ（タスク死）の方が重大なので、デフォルトは長め（30 分）に倒す。
- しきい値・猶予のチューニングは実利用に応じて定数／設定で調整可能。
