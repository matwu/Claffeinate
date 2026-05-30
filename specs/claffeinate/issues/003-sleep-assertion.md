# [003] スリープ抑止（IOKit Power Management Assertion）

**spec:** claffeinate · **対応 AC:** AC-9, AC-10, AC-11, AC-12 · **依存:** 001

## 概要

macOS 標準の Power Management Assertion を使って、アイドル（システム）スリープを抑止・解除するラッパを実装する。sudo / `pmset` は使わない。

## やること

- [ ] `Sources/Claffeinate/SleepAssertion.swift` を作成（`import IOKit.pwr_mgt`）
- [ ] `private var assertionID: IOPMAssertionID` と `private(set) var isActive: Bool` を保持
- [ ] `acquire()`: 未保有時のみ
  ```swift
  IOPMAssertionCreateWithName(
      kIOPMAssertionTypeNoIdleSleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      Constants.assertionReason as CFString,
      &assertionID)
  ```
  成功時 `isActive = true`
- [ ] `release()`: 保有時のみ `IOPMAssertionRelease(assertionID)`、`isActive = false`、`assertionID = 0`
- [ ] acquire / release を冪等にする（二重呼び出しに耐える）

## Acceptance Criteria

- `acquire()` でアイドルスリープが抑止される（**AC-9**, **AC-11**）。
- `release()` で抑止が解除される（**AC-10**）。
- `ディスプレイ`スリープは抑止しない（type は `kIOPMAssertionTypeNoIdleSleep`）。
- 二重 acquire / 二重 release で状態と実体がずれない（**AC-12**）。
- 検証: 抑止中に `pmset -g assertions` に `PreventUserIdleSystemSleep` が立ち、解除で消える。

## メモ

- sudo / `pmset -a disablesleep` は禁止（Constitution §3.1）。
- アサーションはプロセス終了時に OS が自動回収する（クラッシュ時の残留リスクが低い根拠・spec §7）。
