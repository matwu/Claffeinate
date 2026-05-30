import Foundation

/// Drives the detect → reconcile loop on a timer and owns the user-facing
/// monitoring controls (pause / resume / check now).
///
/// Separation of concerns (design §2): detection and prevention are kept
/// apart. `reconcile()` only applies the *difference* between the latest
/// detection result and the assertion we actually hold, so repeated calls are
/// safe and `isSleepAssertionActive` always matches reality (spec AC-12).
@MainActor
final class ProcessMonitor {
    private let state: AppState
    private let detector = ClaudeDetector()
    private let assertion = SleepAssertion()
    private var timer: Timer?

    init(state: AppState) {
        self.state = state
    }

    /// Start (or resume) monitoring: schedule the timer and run one immediate
    /// check so the UI reflects reality without waiting a full interval
    /// (spec AC-3, AC-14).
    func start() {
        state.isMonitoringPaused = false
        scheduleTimer()
        checkNow()
    }

    /// Pause monitoring: stop the timer and release any held assertion so we
    /// never keep the Mac awake while not monitoring (spec AC-13).
    func pause() {
        timer?.invalidate()
        timer = nil
        state.isMonitoringPaused = true

        assertion.release()
        state.isSleepAssertionActive = assertion.isActive
    }

    /// Run a single detection pass immediately (spec AC-15).
    /// No-op while paused so paused state never updates detection (spec AC-16).
    func checkNow() {
        guard !state.isMonitoringPaused else { return }

        let result = detector.detect()
        state.isClaudeRunning = result.isRunning
        state.lastDetectedProcess = result.process

        reconcile()
    }

    /// Release the assertion on shutdown. Called from the app delegate's
    /// terminate path (spec AC-19, AC-20).
    func releaseOnTerminate() {
        assertion.release()
        state.isSleepAssertionActive = assertion.isActive
    }

    // MARK: - Private

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Constants.monitoringInterval,
            repeats: true
        ) { [weak self] _ in
            // Timer fires on the main run loop; hop to the main actor.
            Task { @MainActor in self?.checkNow() }
        }
        self.timer = timer
    }

    /// Bring the held assertion in line with the latest detection result.
    private func reconcile() {
        if state.isClaudeRunning {
            assertion.acquire()
        } else {
            assertion.release()
        }
        state.isSleepAssertionActive = assertion.isActive
    }
}
