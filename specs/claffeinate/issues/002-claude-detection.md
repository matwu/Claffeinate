# [002] Claude 検出ロジック

**spec:** claffeinate · **対応 AC:** AC-5, AC-6, AC-7, AC-8 · **依存:** 001 · **後続:** [011](./011-activity-detection.md)（処理中判定はこの検出結果を入力に使う）

## 概要

実行中プロセスを走査して Claude / Claude Code の**存在**を検出する純粋ロジックを実装する。状態を持たず、呼ばれるたびに「検出有無」「検出したプロセス情報」、および後続のアクティブ判定（011）が使う「一致した PID 群」と「全プロセスの親子・CPU 時間テーブル」を返す。

## やること

- [ ] `Claffeinate/ClaudeDetector.swift` を作成
- [ ] `/bin/ps -axo pid=,ppid=,cputime=,comm=,args=` を `Process` で実行し、各行を `(pid, ppid, cputime, comm, args)` にパース（`cputime` の `[DD-]HH:MM:SS` / `MM:SS.cc` を秒へ変換）
- [ ] 判定ルール:
  - `comm` の basename を小文字化し `claude` を部分一致で含む → 一致（`claude` / `Claude` / `claude-code` を網羅）
  - または basename が `node` で、`args` を小文字化したものに `claude` を含む → 一致
- [ ] 自プロセス（`ProcessInfo.processInfo.processIdentifier`）は root 判定から除外（ただし table には含めてサブツリー走査を完全にする）
- [ ] 一致した全 PID を `rootPIDs` に、最初の一致を `"PID <pid> <name>"` 形式の文字列で返す
- [ ] 全プロセスを `table: [Int32: ProcessSample(pid, ppid, cpuSeconds)]` として返す（011 がサブツリーの CPU を辿るため）
- [ ] 戻り値は `struct DetectionResult { let isRunning: Bool; let process: String?; let rootPIDs: [Int32]; let table: [Int32: ProcessSample] }`

## Acceptance Criteria

- プロセス名が `claude` / `Claude` / `claude-code`（大小無視）のプロセスを検出できる（**AC-5**）。
- `node` プロセスで引数に `claude` を含むものを検出できる（**AC-6**）。
- 検出時、PID と名称を含む文字列を返す（**AC-7**）。
- Claffeinate 自身を Claude として検出しない（**AC-8**）。

## メモ

- 検出対象プロセスは読み取り専用で観測するのみ（Constitution §3.6）。
- `node` の広めの一致で無関係 node を誤検出しても、結果は「不要な抑止」のみで安全側に倒れる（spec §7）。
