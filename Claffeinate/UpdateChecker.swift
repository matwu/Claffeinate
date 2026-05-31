import Foundation
import AppKit
import Combine

/// On-demand "is there a newer version?" check against GitHub Releases.
///
/// Deliberately minimal: it never polls in the background, never downloads, and
/// never auto-updates. The user asks from the menu; we fetch the latest
/// published release, compare it to the running version, and either say we're up
/// to date or offer to open the Releases page. Network failures are surfaced as
/// a status line rather than thrown, so the menu always stays usable.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case updateAvailable(latest: String, url: URL)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

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

    /// Show the result of the most recent check as a modal alert, offering a
    /// Download button when an update is available.
    private func presentResultAlert() {
        let alert = NSAlert()
        switch status {
        case .upToDate(let current):
            alert.messageText = "You’re up to date"
            alert.informativeText = "Claffeinate \(current) is the latest version."
            alert.addButton(withTitle: "OK")
        case .updateAvailable(let latest, _):
            alert.messageText = "A new version is available"
            alert.informativeText = "Claffeinate \(latest) is available. You have \(currentVersion)."
            alert.addButton(withTitle: "Download…")
            alert.addButton(withTitle: "Later")
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

        if case .updateAvailable(_, let url) = status, response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
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
            let url = URL(string: release.htmlURL) ?? Constants.releasesPageURL

            status = Self.isNewer(latest, than: currentVersion)
                ? .updateAvailable(latest: latest, url: url)
                : .upToDate(current: currentVersion)
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

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

private extension String {
    /// Drop a leading "v"/"V" so "v0.1.1" and "0.1.1" compare as equal.
    var strippingVersionPrefix: String {
        guard let first, first == "v" || first == "V" else { return self }
        return String(dropFirst())
    }
}
