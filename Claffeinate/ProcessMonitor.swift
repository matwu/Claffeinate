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
    private let resolver = ActivityResolver()
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
        state.activityState = .idle
        state.activityReason = nil
        state.activitySince = nil
        state.graceUntil = nil
        state.runningSessionCount = 0
        state.hasAutoModeSession = false
        state.hooksActive = false

        // SleepController updates state.isSleepAssertionActive when the helper
        // confirms the release.
        assertion.release()
    }

    /// Run a single detection pass immediately (spec AC-15).
    /// No-op while paused so paused state never updates detection (spec AC-16).
    func checkNow() {
        guard !state.isMonitoringPaused else { return }

        // Keep the helper-connection status honest even while idle: a fire-and-
        // forget ping flips isHelperConnected on reply and clears it on error.
        // Without this the status only reflected reality once Claude first became
        // busy (the first XPC call), so an idle launch showed a misleading "Off"
        // (spec AC-12b). Runs every poll, so a System Settings toggle is picked
        // up within one interval.
        assertion.probeConnection()

        let result = detector.detect()
        state.isClaudeRunning = result.isRunning
        state.lastDetectedProcess = result.process

        // Presence alone isn't enough — only keep the Mac awake while Claude is
        // actually working (spec AC-5a). The resolver uses Claude Code hooks
        // (authoritative) and falls back to transcript freshness.
        let activity = resolver.resolve(
            roots: result.roots,
            livePIDs: result.livePIDs
        )

        state.activityState = activity.state
        state.activityReason = activity.reason
        state.activitySince = activity.since
        state.graceUntil = activity.graceUntil
        state.runningSessionCount = activity.runningRoots
        state.hasAutoModeSession = activity.hasAutoModeSession
        state.hooksActive = activity.hooksActive

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
