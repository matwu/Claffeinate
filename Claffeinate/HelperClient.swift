import Foundation
import ServiceManagement

/// App-side bridge to the privileged helper: registers the daemon and proxies
/// calls over XPC. Keeps `AppState.isHelperConnected` in sync with reality so
/// the UI never shows "Active" without a working helper (spec AC-12b).
@MainActor
final class HelperClient {
    private let state: AppState
    private var connection: NSXPCConnection?

    init(state: AppState) {
        self.state = state
    }

    /// Register the helper daemon if it isn't already enabled (spec AC-12a).
    /// macOS prompts for approval the first time only.
    func registerIfNeeded() {
        let service = SMAppService.daemon(plistName: HelperConstants.helperPlistName)
        guard service.status != .enabled else { return }
        do {
            try service.register()
        } catch {
            NSLog("Claffeinate: helper registration failed: \(error.localizedDescription)")
            // Approval may be required — point the user at the right settings.
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // MARK: - Calls

    /// Async toggle used during normal monitoring.
    func setDisableSleep(_ on: Bool) async -> Bool {
        guard let proxy = remoteProxy() else {
            state.isHelperConnected = false
            return false
        }
        return await withCheckedContinuation { continuation in
            proxy.setDisableSleep(on) { [weak self] ok in
                Task { @MainActor in self?.state.isHelperConnected = true }
                continuation.resume(returning: ok)
            }
        }
    }

    /// Synchronous toggle for app termination, where we can't await (spec
    /// AC-19/20). Uses a synchronous proxy so the reply is delivered before the
    /// call returns; the helper watchdog is the backstop if the helper is gone.
    @discardableResult
    func setDisableSleepSync(_ on: Bool) -> Bool {
        let connection = ensureConnection()
        var result = false
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { error in
            NSLog("Claffeinate: XPC sync error: \(error.localizedDescription)")
        } as? HelperProtocol
        proxy?.setDisableSleep(on) { ok in result = ok }
        return result
    }

    /// Heartbeat (spec AC-21). Fire-and-forget.
    func ping() {
        guard let proxy = remoteProxy() else { return }
        proxy.ping { [weak self] in
            Task { @MainActor in self?.state.isHelperConnected = true }
        }
    }

    // MARK: - Connection management

    private func ensureConnection() -> NSXPCConnection {
        if let connection { return connection }
        let new = NSXPCConnection(machServiceName: HelperConstants.machServiceName,
                                  options: .privileged)
        new.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        new.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.handleDisconnect() }
        }
        new.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.handleDisconnect() }
        }
        new.resume()
        connection = new
        return new
    }

    private func remoteProxy() -> HelperProtocol? {
        let connection = ensureConnection()
        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            NSLog("Claffeinate: XPC error: \(error.localizedDescription)")
            Task { @MainActor in self?.handleDisconnect() }
        } as? HelperProtocol
    }

    private func handleDisconnect() {
        connection?.invalidate()
        connection = nil
        state.isHelperConnected = false
    }
}
