import Foundation

/// XPC-exported object. Forwards each call to the `SleepDisabledManager`.
final class HelperService: NSObject, HelperProtocol {
    private let manager: SleepDisabledManager

    init(manager: SleepDisabledManager) {
        self.manager = manager
    }

    func setDisableSleep(_ on: Bool, reply: @escaping (Bool) -> Void) {
        reply(manager.setDisableSleep(on))
    }

    func ping(reply: @escaping () -> Void) {
        manager.ping()
        reply()
    }

    func currentState(reply: @escaping (Bool) -> Void) {
        reply(manager.currentState())
    }
}

/// Accepts incoming connections, but only from clients that satisfy our code
/// requirement, so a rogue process can't drive `SleepDisabled` (design §5).
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: HelperService

    init(service: HelperService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Reject anything that isn't our signed app (ADR-T6). The requirement
        // pins the app's bundle id + our Team ID (derived from the helper's own
        // signature). If we can't build it — a teamless/self-signed identity —
        // fail closed and refuse the connection rather than accept anyone.
        guard let requirement = HelperConstants.clientCodeRequirement() else {
            NSLog("Claffeinate Helper: no Team ID in signature; rejecting connection (fail-closed).")
            return false
        }
        // If the connecting code doesn't satisfy this, the OS invalidates the
        // connection.
        newConnection.setCodeSigningRequirement(requirement)

        newConnection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}
