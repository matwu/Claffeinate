# [002] Claude 検出ロジック

**spec:** claffeinate · **対応 AC:** AC-5, AC-6, AC-7, AC-8 · **依存:** 001

## 概要

実行中プロセスを走査して Claude / Claude Code の稼働を検出する純粋ロジックを実装する。状態を持たず、呼ばれるたびに「検出有無」と「検出したプロセス情報」を返す。

## やること

- [ ] `Sources/Claffeinate/ClaudeDetector.swift` を作成
- [ ] `/bin/ps -axo pid=,comm=,args=` を `Process` で実行し、各行を `(pid, comm, args)` にパース
- [ ] 判定ルール:
  - `comm` の basename を小文字化し `claude` を部分一致で含む → 検出（`claude` / `Claude` / `claude-code` を網羅）
  - または basename が `node` で、`args` を小文字化したものに `claude` を含む → 検出
- [ ] 自プロセス（`ProcessInfo.processInfo.processIdentifier`）は除外
- [ ] 最初に一致したプロセスを `"PID <pid> <name>"` 形式の文字列で返す
- [ ] 戻り値は `struct DetectionResult { let isRunning: Bool; let process: String? }`

## Acceptance Criteria

- プロセス名が `claude` / `Claude` / `claude-code`（大小無視）のプロセスを検出できる（**AC-5**）。
- `node` プロセスで引数に `claude` を含むものを検出できる（**AC-6**）。
- 検出時、PID と名称を含む文字列を返す（**AC-7**）。
- Claffeinate 自身を Claude として検出しない（**AC-8**）。

## メモ

- 検出対象プロセスは読み取り専用で観測するのみ（Constitution §3.6）。
- `node` の広めの一致で無関係 node を誤検出しても、結果は「不要な抑止」のみで安全側に倒れる（spec §7）。
