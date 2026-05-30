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
        // "Detected" means a Claude process exists; "(Active)" vs "(Idle)"
        // reflects whether it's actually processing (spec AC-5a, AC-17).
        Text("Claude: \(claudeStatus)")
        if let lastActivity = lastActivityText {
            Text(lastActivity)
        }
        Text("Sleep Prevention: \(state.isSleepAssertionActive ? "Active" : "Inactive")")
        Text("Monitoring: \(state.isMonitoringPaused ? "Paused" : "Running")")
        Text("Helper: \(state.isHelperConnected ? "Connected" : "Not Connected")")

        // Be honest when the helper is down: lid-close prevention can't work
        // without it (spec AC-12b).
        if !state.isHelperConnected {
            Text("⚠️ Helper not connected — sleep can't be prevented")
        }

        Divider()

        // --- Controls ---
        if state.isMonitoringPaused {
            Button("Resume Monitoring") { monitor.start() }
        } else {
            Button("Pause Monitoring") { monitor.pause() }
        }

        Button("Check Now") { monitor.checkNow() }
            .disabled(state.isMonitoringPaused)

        // --- Idle grace period (user-configurable, spec AC-4a) ---
        Menu("Idle grace period: \(state.gracePeriodMinutes) min") {
            ForEach(Constants.gracePeriodPresetsMinutes, id: \.self) { minutes in
                Button {
                    state.gracePeriodMinutes = minutes
                } label: {
                    // A leading check marks the current choice.
                    Text("\(state.gracePeriodMinutes == minutes ? "✓ " : "")\(minutes) min")
                }
            }
        }

        Divider()

        Button("Quit") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// "Detected (Active)" / "Detected (Idle)" / "Not Detected" (spec AC-17).
    private var claudeStatus: String {
        guard state.isClaudeRunning else { return "Not Detected" }
        return state.isClaudeActive ? "Detected (Active)" : "Detected (Idle)"
    }

    /// "Last activity: N min ago" describing how long since Claude was last seen
    /// processing. Re-evaluated whenever the menu re-renders (every monitoring
    /// tick updates `state`, so the elapsed time stays roughly current). nil
    /// when there's no recorded activity, so the line is hidden entirely.
    private var lastActivityText: String? {
        guard let last = state.lastActivityAt else { return nil }
        let elapsed = Date().timeIntervalSince(last)
        let minutes = Int(elapsed / 60)
        if minutes < 1 {
            return "Last activity: just now"
        }
        return "Last activity: \(minutes) min ago"
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
