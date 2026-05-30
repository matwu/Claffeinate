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
    private let sampler = ActivitySampler()
    private let assertion: SleepController
    private var timer: Timer?

    init(state: AppState) {
        self.state = state
        self.assertion = SleepController(state: state)
    }

    /// Register the privileged helper (spec AC-12a). Call once at launch.
    func registerHelper() {
        assertion.registerHelperIfNeeded()
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
        state.isClaudeActive = false
        state.lastActivityAt = nil

        // Drop the activity baseline so a later resume starts fresh (AC-14).
        sampler.reset()

        // SleepController updates state.isSleepAssertionActive when the helper
        // confirms the release.
        assertion.release()
    }

    /// Run a single detection pass immediately (spec AC-15).
    /// No-op while paused so paused state never updates detection (spec AC-16).
    func checkNow() {
        guard !state.isMonitoringPaused else { return }

        let result = detector.detect()
        state.isClaudeRunning = result.isRunning
        state.lastDetectedProcess = result.process

        // Presence alone isn't enough — only keep the Mac awake while Claude is
        // actually processing (spec AC-5a). The sampler applies the CPU
        // threshold and the user's idle grace period.
        state.isClaudeActive = sampler.sample(
            rootPIDs: result.rootPIDs,
            table: result.table,
            gracePeriod: state.gracePeriod
        )

        // Surface when activity was last seen so the menu can show "N min ago".
        state.lastActivityAt = sampler.lastActiveAt

        reconcile()
    }

    /// Release the assertion on shutdown. Called from the app delegate's
    /// terminate path (spec AC-19, AC-20).
    func releaseOnTerminate() {
        // Synchronous so SleepDisabled is cleared before the process exits.
        assertion.releaseSynchronously()
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
        // SleepController writes state.isSleepAssertionActive once the helper
        // confirms the SleepDisabled change (it never claims active optimistically).
        // Keyed off *activity*, not mere presence: an idle Claude at the prompt
        // must not hold the Mac awake (spec AC-5a, AC-9/AC-10).
        if state.isClaudeActive {
            assertion.acquire()
        } else {
            assertion.release()
        }
    }
}
