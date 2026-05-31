import Foundation
import AppKit
import Combine

/// On-demand "is there a newer version?" check against GitHub Releases.
///
/// The user asks from the menu; we fetch the latest published release and
/// compare it to the running version. When a newer one exists and ships a
/// verifiable zip asset, we offer to install it in place and relaunch (see
/// `AppUpdater`); otherwise we fall back to opening the Releases page. Network
/// failures are surfaced as a status line rather than thrown, so the menu
/// always stays usable. It never polls in the background.
@MainActor
final class UpdateChecker: ObservableObject {
    /// Everything needed to install (or, lacking a zip asset, to point the user
    /// at) a newer release.
    struct Available: Equatable {
        let latest: String
        /// The release zip to download and install, when one is published.
        let zipURL: URL?
        /// `"sha256:…"` digest GitHub serves for the zip, for integrity checking.
        let sha256: String?
        /// The release page, used as a fallback when there's no installable zip.
        let pageURL: URL
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case updateAvailable(Available)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    private let updater = AppUpdater()

    /// The running app's marketing version (`CFBundleShortVersionString`),
    /// e.g. "0.1.1". Falls back to "0" if the key is somehow absent.
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// User tapped "Check for Updates…". Fetch the latest release, compare it to
    /// the running version, and report the outcome in an alert — the menu closes
    /// on tap, so an in-menu status line alone would never be seen. The
    /// `status` line is still updated for the next time the menu is opened.
    /// Safe to call repeatedly; an in-flight check ignores further taps.
    func checkForUpdates() {
        if status == .checking { return }
        status = .checking
        Task {
            await performCheck()
            presentResultAlert()
        }
    }

    /// Show the result of the most recent check as a modal alert. When an
    /// installable zip is published, the primary action installs it in place and
    /// relaunches; otherwise it falls back to opening the Releases page.
    private func presentResultAlert() {
        let alert = NSAlert()
        switch status {
        case .upToDate(let current):
            alert.messageText = "You’re up to date"
            alert.informativeText = "Claffeinate \(current) is the latest version."
            alert.addButton(withTitle: "OK")
        case .updateAvailable(let info):
            alert.messageText = "A new version is available"
            alert.informativeText = "Claffeinate \(info.latest) is available. You have \(currentVersion)."
            if info.zipURL != nil {
                alert.addButton(withTitle: "Install & Relaunch")
                alert.addButton(withTitle: "Release Notes")
                alert.addButton(withTitle: "Later")
            } else {
                // No installable asset on this release — point the user at the page.
                alert.addButton(withTitle: "Open Releases…")
                alert.addButton(withTitle: "Later")
            }
        case .failed(let message):
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t check for updates"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
        case .idle, .checking:
            return  // nothing to report
        }

        // An accessory (menu-bar-only) app isn't active, so bring the alert to
        // the front or it can appear behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        guard case .updateAvailable(let info) = status else { return }
        if let zipURL = info.zipURL {
            switch response {
            case .alertFirstButtonReturn:                       // Install & Relaunch
                installUpdate(info, zipURL: zipURL)
            case .alertSecondButtonReturn:                      // Release Notes
                NSWorkspace.shared.open(info.pageURL)
            default:                                            // Later
                break
            }
        } else if response == .alertFirstButtonReturn {         // Open Releases…
            NSWorkspace.shared.open(info.pageURL)
        }
    }

    /// Run the in-place install. On success the app quits and relaunches itself;
    /// on failure we report why and offer the Releases page as a manual fallback.
    private func installUpdate(_ info: Available, zipURL: URL) {
        Task {
            do {
                try await updater.installUpdate(
                    version: info.latest, zipURL: zipURL, expectedSHA256: info.sha256)
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Couldn’t install the update"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Open Releases…")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(info.pageURL)
                }
            }
        }
    }

    private func performCheck() async {
        var request = URLRequest(url: Constants.latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects requests without a User-Agent.
        request.setValue("Claffeinate", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                status = .failed("No response")
                return
            }
            switch http.statusCode {
            case 200:
                break
            case 404:
                // No published (non-draft, non-prerelease) release yet.
                status = .upToDate(current: currentVersion)
                return
            default:
                status = .failed("GitHub returned \(http.statusCode)")
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latest = release.tagName.strippingVersionPrefix
            let pageURL = URL(string: release.htmlURL) ?? Constants.releasesPageURL

            guard Self.isNewer(latest, than: currentVersion) else {
                status = .upToDate(current: currentVersion)
                return
            }

            // Prefer the published .zip so we can install in place; fall back to
            // the Releases page when a release ships without one.
            let zip = release.assets.first {
                $0.contentType == "application/zip" || $0.name.hasSuffix(".zip")
            }
            status = .updateAvailable(Available(
                latest: latest,
                zipURL: zip.flatMap { URL(string: $0.browserDownloadURL) },
                sha256: zip?.digest?.strippingDigestPrefix,
                pageURL: pageURL))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Semantic version comparison

    /// True when `candidate` is a strictly higher semantic version than
    /// `current`. Compares dot-separated integer components left to right;
    /// missing trailing components count as 0 (so "0.2" > "0.1.9"). Any
    /// non-numeric suffix on a component is ignored.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate)
        let rhs = components(current)
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}

/// The subset of the GitHub Releases API response we care about.
private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String
        let contentType: String
        /// `"sha256:…"` since GitHub added asset digests; absent on older releases.
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case contentType = "content_type"
            case digest
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private extension String {
    /// Drop a leading "v"/"V" so "v0.1.1" and "0.1.1" compare as equal.
    var strippingVersionPrefix: String {
        guard let first, first == "v" || first == "V" else { return self }
        return String(dropFirst())
    }

    /// Turn GitHub's `"sha256:abc…"` digest into the bare hex `AppUpdater` checks.
    var strippingDigestPrefix: String {
        guard let colon = firstIndex(of: ":") else { return self }
        return String(self[index(after: colon)...])
    }
}
