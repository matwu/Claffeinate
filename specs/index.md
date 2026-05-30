# Specs Index

Claffeinate の仕様の一覧。仕様駆動開発（Spec-Driven Development）で管理する。

## ステータスの意味

| ステータス | 意味 |
| --- | --- |
| `draft` | 起案中。受け入れ基準が未確定 / レビュー前 |
| `approved` | レビュー済み。実装可能な状態 |
| `done` | 実装完了 |

## 一覧

| spec_id | タイトル | status | spec | design | tasks |
| --- | --- | --- | --- | --- | --- |
| claffeinate | Claude 稼働中のみスリープを抑止するメニューバーアプリ | done | [spec.md](./claffeinate/spec.md) | [design.md](./claffeinate/design.md) | [tasks.md](./claffeinate/tasks.md) |

## 上位規範

- [Constitution](./constitution.md) — プロダクトの最上位規範

## 運用

1. `constitution.md` を最上位規範とする。
2. 機能ごとに `specs/<spec_id>/` に `spec.md`（What）/ `design.md`（How）/ `tasks.md`（実装計画）を置く。
3. `tasks.md` のタスクを `specs/<spec_id>/issues/` に GitHub 貼り付け可能な草案として起こし、可能なら GitHub Issue 化する。
4. EARS 記法（`When ..., the system shall ...`）で受け入れ基準の曖昧さを排除する。
