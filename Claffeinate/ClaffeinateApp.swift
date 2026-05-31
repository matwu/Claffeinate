import SwiftUI
import AppKit

/// Process entry point. Before any UI starts, check whether we were invoked as
/// a Claude Code hook (`--claffeinate-hook <Event>`): if so, update the lease
/// files and exit without ever creating a menu bar app.
@main
enum ClaffeinateMain {
    static func main() {
        if HookMode.handleIfNeeded(CommandLine.arguments) {
            exit(0)
        }
        // Fail-safe: a hook-shaped invocation must NEVER fall through to the
        // menu-bar GUI. If the line above didn't recognise it but the args still
        // look like a hook — any `--claffeinate*` flag (the other build's flag or
        // a future/renamed one) or a bare Claude Code event name — exit silently
        // instead of launching the app. (Past incident: a flag mismatch made
        // every hook event launch a full GUI; Claude Code waits synchronously for
        // the hook to exit, so one menu-bar app spawned per session and froze it.)
        if CommandLine.arguments.dropFirst().contains(where: {
            $0.hasPrefix("--claffeinate") || HookMode.knownEventNames.contains($0)
        }) {
            exit(0)
        }
        ClaffeinateApp.main()
    }
}

/// Claffeinate — a macOS menu bar app that prevents system sleep (idle **and**
/// lid-close) only while Claude / Claude Code is running, by toggling the
/// `SleepDisabled` power setting through a privileged helper (SMAppService + XPC).
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
