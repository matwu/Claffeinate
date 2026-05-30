# [001] メニューバーアプリ基盤（Dock 非表示）

**spec:** claffeinate · **対応 AC:** AC-1, AC-2, AC-3 · **依存:** なし

## 概要

SwiftUI `MenuBarExtra` ベースのメニューバー常駐アプリの骨格を作る。Dock には表示せず、起動時にメニューバーアイコンを出す。Swift Package Manager の executable target として `swift build` / `swift run` できる状態にする。

## やること

- [ ] `Package.swift`（executable target `Claffeinate`、macOS 13+、依存ライブラリなし）
- [ ] `Sources/Claffeinate/ClaffeinateApp.swift`: `@main` SwiftUI `App` + `MenuBarExtra` シーン
- [ ] `@NSApplicationDelegateAdaptor` で `AppDelegate` を接続し、`applicationDidFinishLaunching` で `NSApplication.shared.setActivationPolicy(.accessory)` を呼ぶ（Dock 非表示）
- [ ] `Sources/Claffeinate/Constants.swift`: 監視間隔（デフォルト 5 秒・定数）、アサーション理由文字列
- [ ] メニューに最低限のプレースホルダ（タイトル + Quit）を表示

## Acceptance Criteria

- `swift build` がエラーなく成功する。
- `swift run` でメニューバーにアイコンが表示される（**AC-1**）。
- アプリ起動中、Dock にアイコンが表示されない（**AC-2**）。
- 起動と同時に常駐し、後続タスクで監視を自動開始できる土台がある（**AC-3** の前提）。

## メモ

- 依存ライブラリは追加しない（Constitution §3.5）。
- 監視間隔は `Constants` に定数として置き、将来変更可能にする（AC-4 の前提）。
