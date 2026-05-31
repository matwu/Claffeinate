import SwiftUI
import AppKit

/// Claffeinate — a macOS menu bar app that prevents system sleep (idle **and**
/// lid-close) only while Claude / Claude Code is running, by toggling the
/// `SleepDisabled` power setting through a privileged helper (SMAppService + XPC).
@main
struct ClaffeinateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: appDelegate.state,
                        monitor: appDelegate.monitor,
                        updater: appDelegate.updater)
        } label: {
            MenuBarLabel(state: appDelegate.state)
        }
        // Render a custom SwiftUI panel rather than a system menu: the status
        // hero, tinted tags, grace-period pills and hover-aware controls all
        // need real layout, which the default `.menu` style can't provide.
        .menuBarExtraStyle(.window)
    }
}

/// Owns the long-lived objects and the app lifecycle hooks that guarantee the
/// sleep assertion is released on exit (spec AC-19, AC-20).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    lazy var monitor = ProcessMonitor(state: state)
    let updater = UpdateChecker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — never show a Dock icon (spec AC-2).
        NSApplication.shared.setActivationPolicy(.accessory)

        // Register the privileged helper (prompts once on first launch, AC-12a).
        monitor.registerHelper()

        // Start monitoring immediately (spec AC-3).
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Single choke point for shutdown: both the Quit button and any OS
        // termination route through here, so the assertion is always released.
        monitor.releaseOnTerminate()
    }
}
