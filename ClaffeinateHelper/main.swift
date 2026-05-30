import Foundation

// Claffeinate privileged helper.
//
// Runs as a root launchd daemon registered via SMAppService. Its only job is
// to toggle the system-wide `SleepDisabled` power setting on behalf of the
// (non-privileged) app, with a watchdog that restores it if the app dies.

let manager = SleepDisabledManager()

// AC-23: clear any residual SleepDisabled left over from a previous crash
// before we start accepting commands.
manager.resetOnStartup()

let service = HelperService(manager: manager)
let delegate = HelperListenerDelegate(service: service)

let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

NSLog("Claffeinate helper started (machService=%@)", HelperConstants.machServiceName)

// Block forever servicing XPC connections.
dispatchMain()
