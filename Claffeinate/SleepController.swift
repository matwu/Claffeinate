import Foundation

/// Drives system sleep prevention (idle **and** lid-close) through the
/// privileged helper.
///
/// Deliberately keeps the same `acquire()` / `release()` / `isActive` surface
/// the old IOKit `SleepAssertion` had, so `ProcessMonitor` is unchanged. The
/// real work — writing `SleepDisabled` — happens in the helper over XPC, so the
/// result is applied asynchronously: `isActive` and `AppState.isSleepAssertionActive`
/// are updated when the helper replies, never optimistically (spec AC-12 / AC-12b).
@MainActor
final class SleepController {
    private let state: AppState
    private let helper: HelperClient
    private var heartbeat: Timer?

    /// What we're trying to reach. Set synchronously by acquire/release so the
    /// idempotency guards work even before the async reply lands.
    private var desiredOn = false

    /// True only once the helper confirms `SleepDisabled` is on.
    private(set) var isActive = false

    init(state: AppState) {
        self.state = state
        self.helper = HelperClient(state: state)
    }

    /// Register the privileged helper (spec AC-12a). Call once at launch.
    func registerHelperIfNeeded() {
        helper.registerIfNeeded()
    }

    /// Probe the XPC connection so `AppState.isHelperConnected` reflects reality
    /// even while no assertion is held (idle). Fire-and-forget: a reply flips the
    /// flag on, an error clears it. This is what makes "Helper" self-correct at
    /// launch, after the user toggles the helper in System Settings, and right
    /// after installing hooks — without waiting for Claude to first become busy.
    func probeConnection() {
        helper.ping()
    }

    func acquire() {
        guard !desiredOn else { return }
        desiredOn = true
        Task { await applyDesired() }
    }

    func release() {
        guard desiredOn else { return }
        desiredOn = false
        Task { await applyDesired() }
    }

    /// Best-effort synchronous release for termination (spec AC-19/20). The
    /// helper's watchdog is the backstop if this can't reach the daemon.
    func releaseSynchronously() {
        desiredOn = false
        stopHeartbeat()
        helper.setDisableSleepSync(false)
        isActive = false
        state.isSleepAssertionActive = false
    }

    // MARK: - Private

    private func applyDesired() async {
        let target = desiredOn
        let ok = await helper.setDisableSleep(target)
        // Guard against a newer acquire/release having superseded this one
        // while we awaited the reply.
        guard target == desiredOn else { return }

        isActive = ok && target
        state.isSleepAssertionActive = isActive
        if isActive { startHeartbeat() } else { stopHeartbeat() }
    }

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Timer.scheduledTimer(
            withTimeInterval: HelperConstants.heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.helper.ping() }
        }
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
    }
}
