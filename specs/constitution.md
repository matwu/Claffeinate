---
title: Claffeinate Constitution
version: 2.0.0
status: accepted
created: 2026-05-30
last_amended: 2026-05-30
---

# Claffeinate Constitution

Claffeinate の意思決定の最上位規範。spec / design / tasks / コードは本憲法に従う。
矛盾が生じた場合は本憲法を優先する。

---

## §1. プロダクトの目的

**「Claude / Claude Code が動作している間だけ Mac をスリープさせない」** ための macOS メニューバーアプリ。

- 名称の由来: Claude + caffeinate（macOS の `caffeinate` 文化を踏襲した命名）
- ユーザーが Claude に長時間タスクを任せている間、手を触れなくても Mac が眠らないようにする
- Claude が動いていないときは通常どおりスリープする（電力を無駄にしない）

## §2. コア価値（重視順）

実装・設計上のトレードオフは、原則この順序で判断する。

1. **安全性** — 戻し忘れ・解除漏れによるバッテリー消費や設定破壊を絶対に起こさない。システム全体設定（`SleepDisabled`）を操作する場合は、heartbeat watchdog と起動時リセットにより**クラッシュ時も必ず復帰可能**であることを必須とする
2. **macOS らしさ** — OS 標準の作法に従い、ユーザーの想定を裏切らない
3. **シンプルさ** — 機能・設定・コードを最小限に保つ
4. **保守性** — 状態と責務を分離し、読んで理解できる構造にする
5. **拡張性** — 将来の変更余地を残すが、現時点で使わない抽象は作らない

## §3. 非交渉の原則（MUST）

- **§3.1 特権操作の限定**: システム全体設定（`SleepDisabled`）の変更は、(a) ユーザーが明示的に認証した特権 helper 経由でのみ行い、(b) heartbeat watchdog と起動時リセットにより必ず復帰可能にすること。生 sudo 呼び出し・`/etc/sudoers` の改変・無認証の権限昇格は行わない。
  - 補足: アイドルスリープのみの抑止は引き続き標準の Power Management Assertion で行ってよい。`SleepDisabled` は lid-close（蓋閉じ）スリープを止めるためにのみ用い、これを止める他の手段は OS に存在しない。
- **§3.2 標準 API のみ**: スリープ抑止は macOS 標準 API で実現する。許容範囲は Power Management Assertion（IOKit `IOPMAssertionCreateWithName` / `IOPMAssertionRelease`）、`IOPMSetSystemPowerSetting`、特権 helper の登録に用いる `SMAppService`、app⇄helper 間の `XPC`（`NSXPCConnection`）まで。サードパーティ依存は不可（§3.5）。
- **§3.3 解除保証**: スリープ抑止を有効化したら、クラッシュを除き必ず解除する。アプリ終了時の解除漏れを許容しない。`SleepDisabled` は OS が自動回収しないため、(a) 正常終了時の明示解除、(b) helper の heartbeat watchdog による自動復帰、(c) helper 起動時の残留状態リセット、の三重で復帰を保証する。
- **§3.4 過剰設計の禁止**: 要件にない一般化・抽象化・設定項目・永続化・ネットワーク通信を追加しない。ただし lid-close 抑止の達成に不可欠な最小限として、特権 helper・ローカル XPC・`SleepDisabled`（永続システム設定）の使用は許容する。外部ネットワーク通信は依然として禁止。
- **§3.5 依存ゼロ**: サードパーティ依存を追加しない。標準ライブラリ（Swift / SwiftUI / AppKit / IOKit）のみを使う。
- **§3.6 非侵襲**: 検出対象プロセスを kill・変更・監視ログ送信しない。読み取り専用で観測するだけ。

## §4. UX 原則

- **§4.1 メニューバーのみ**: Dock には表示しない。常駐 UI はメニューバーアイコンとそのメニューのみ。
- **§4.2 状態の透明性**: 現在の検出状態・抑止状態・監視状態を、ユーザーがいつでもメニューで確認できる。
- **§4.3 ユーザー主権**: 監視の一時停止 / 再開、即時チェックをユーザーが明示的に操作できる。

## §5. スコープ規律

- 本アプリは「スリープ抑止」という単一責務に集中する。
- Claude の起動・終了・操作・ログインなどには一切関与しない。
- 設定 UI・自動起動登録・通知・統計などは MVP に含めない（[spec §"含まないもの"]・Future Work で扱う）。

---

## 改訂履歴

| 日付 | 変更内容 | 変更者 |
| --- | --- | --- |
| 2026-05-30 | 初版 (accepted) | @matwu |
| 2026-05-30 | v2.0.0: lid-close（蓋閉じ）スリープ抑止のため §3.1〜§3.4・§2.1 を改正。特権 helper 経由の `SleepDisabled` 操作を watchdog/リセットによる復帰保証付きで許容 | @matwu |
