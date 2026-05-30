import Foundation
import Combine

/// Single source of truth for the app's observable state.
///
/// State is held here as passive data and is never mixed: detection
/// (`isClaudeRunning`), prevention (`isSleepAssertionActive`) and monitoring
/// (`isMonitoringPaused`) are independent facts. `ProcessMonitor` updates
/// them; `MenuContent` renders them.
@MainActor
final class AppState: ObservableObject {
    /// Whether the most recent scan detected Claude.
    @Published var isClaudeRunning = false

    /// Whether a sleep-prevention assertion is currently held.
    @Published var isSleepAssertionActive = false

    /// Whether monitoring is paused by the user.
    @Published var isMonitoringPaused = false

    /// "PID <pid> <name>" of the last detected process, or nil.
    @Published var lastDetectedProcess: String?
}
