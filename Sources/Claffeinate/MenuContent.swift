import SwiftUI

/// The menu shown when the menu bar icon is clicked.
/// Renders the three independent status lines and the user controls
/// (spec AC-17, AC-18) plus Pause / Resume / Check Now / Quit.
struct MenuContent: View {
    @ObservedObject var state: AppState
    let monitor: ProcessMonitor

    var body: some View {
        // --- Title ---
        Text("Claffeinate")

        Divider()

        // --- Status (read-only) ---
        Text("Claude: \(state.isClaudeRunning ? "Detected" : "Not Detected")")
        Text("Sleep Prevention: \(state.isSleepAssertionActive ? "Active" : "Inactive")")
        Text("Monitoring: \(state.isMonitoringPaused ? "Paused" : "Running")")

        Divider()

        // --- Controls ---
        if state.isMonitoringPaused {
            Button("Resume Monitoring") { monitor.start() }
        } else {
            Button("Pause Monitoring") { monitor.pause() }
        }

        Button("Check Now") { monitor.checkNow() }
            .disabled(state.isMonitoringPaused)

        Divider()

        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// The menu bar icon. Filled cup while sleep is being prevented, outline cup
/// otherwise, so the active state is visible at a glance.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        Image(systemName: state.isSleepAssertionActive
              ? "cup.and.saucer.fill"
              : "cup.and.saucer")
    }
}
