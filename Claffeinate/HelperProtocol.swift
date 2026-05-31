import Foundation
import Security

/// Identifiers and tunables shared by the app and the privileged helper.
///
/// Kept in the shared target so both sides agree on the Mach service name,
/// the launchd plist name, and the heartbeat/watchdog timing.
public enum HelperConstants {
    /// `.develop` in DEBUG builds, empty in RELEASE. Keeps a dev build's whole
    /// identity (app + helper bundle IDs, Mach service, launchd label, plist)
    /// from colliding with an installed Release build. Must match the Debug
    /// `PRODUCT_BUNDLE_IDENTIFIER`s in the Xcode project
    /// (`com.matwu.Claffeinate.develop` / `…develop.Helper`).
    #if DEBUG
    public static let bundleSuffix = ".develop"
    #else
    public static let bundleSuffix = ""
    #endif

    /// Bundle identifier of the helper. Also the launchd label and the Mach
    /// service name advertised by the daemon's `NSXPCListener`. Build-specific
    /// via `bundleSuffix`.
    public static let machServiceName = appBundleIdentifier + ".Helper"

    /// File name of the launchd property list embedded under
    /// `Contents/Library/LaunchDaemons/` in the app bundle. Passed to
    /// `SMAppService.daemon(plistName:)`.
    public static let helperPlistName = machServiceName + ".plist"

    /// Whether this build registers and drives the privileged root helper.
    /// RELEASE always does; DEBUG never does. A dev build must not register a
    /// root `LaunchDaemon` or write the single global `SleepDisabled` setting —
    /// two daemons would contend on one OS resource, and registering out of an
    /// ephemeral DerivedData build orphans root processes. Verify the helper
    /// with a Release build.
    public static var managesPrivilegedHelper: Bool {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }

    /// How often the app pings the helper while sleep is disabled. The helper's
    /// watchdog (below) must be comfortably larger than this.
    public static let heartbeatInterval: TimeInterval = 10

    /// If the helper receives no ping for this long it assumes the app died and
    /// restores `SleepDisabled = false` on its own (spec AC-22). Set to several
    /// heartbeat intervals so a single missed ping never trips it.
    public static let watchdogTimeout: TimeInterval = 35

    /// Bundle identifier of the main app — the only client allowed to drive
    /// `SleepDisabled`. Not secret; it appears in the app's code signature.
    /// Build-specific via `bundleSuffix` so the Debug helper's client
    /// requirement pins the Debug app, not the Release one.
    public static let appBundleIdentifier = "com.matwu.Claffeinate" + bundleSuffix

    /// Team Identifier read from the *helper's own* code signature. The app and
    /// helper are signed by the same Apple Developer team, so requiring the
    /// connecting client to match this is equivalent to pinning the Team ID —
    /// without baking it into source (it flows from the signing identity, like
    /// the bundle id does). Returns `nil` under an ad-hoc / self-signed identity,
    /// which carries no team.
    public static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }

        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Code-signing requirement the helper enforces on connecting clients so a
    /// rogue process can't drive `SleepDisabled` (design §5, ADR-T6).
    ///
    /// Built from `appBundleIdentifier` + the runtime-derived Team ID. Returns
    /// `nil` under a teamless (self-signed) identity; the listener treats that as
    /// fail-closed and rejects the connection. For local development, sign with a
    /// Development certificate (which carries a team).
    public static func clientCodeRequirement() -> String? {
        guard let team = currentTeamIdentifier() else { return nil }
        return "identifier \"\(appBundleIdentifier)\" and anchor apple generic "
             + "and certificate leaf[subject.OU] = \"\(team)\""
    }
}

/// The XPC contract. Implemented by the helper, called by the app through an
/// `NSXPCConnection` remote proxy.
///
/// Methods use reply blocks (not async) because `@objc` XPC protocols predate
/// Swift concurrency; the app wraps them in continuations.
@objc public protocol HelperProtocol {
    /// Set the system-wide `SleepDisabled` power setting. `reply` carries
    /// whether the privileged write succeeded (spec AC-9 / AC-10).
    func setDisableSleep(_ on: Bool, reply: @escaping (Bool) -> Void)

    /// Heartbeat. Resets the helper's watchdog (spec AC-21 / AC-22).
    func ping(reply: @escaping () -> Void)

    /// Report the helper's current `SleepDisabled` value so the app can
    /// reconcile its displayed state with reality (spec AC-12).
    func currentState(reply: @escaping (Bool) -> Void)
}
