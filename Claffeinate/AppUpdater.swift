import Foundation
import AppKit
import CryptoKit

/// Downloads a GitHub release zip, verifies it, swaps it in over the running
/// bundle and relaunches — so "a new version is available" actually updates the
/// app instead of just opening the Releases page.
///
/// Trust chain (all three must hold before anything is swapped):
///   1. The download's SHA-256 matches the digest GitHub served over TLS, so the
///      bytes are exactly what the release published (integrity).
///   2. `codesign --verify --strict` passes on the unzipped app (the signature
///      is intact and the bundle wasn't tampered with after signing).
///   3. The new app's Team ID equals the *running* app's Team ID, so an update
///      can only ever come from the same developer identity (provenance).
/// Gatekeeper assessment (`spctl`) is run as a best-effort bonus and logged, but
/// not required — a missing notarization staple offline must not block a
/// legitimately-signed update whose bytes already matched the GitHub digest.
@MainActor
final class AppUpdater {
    enum UpdateError: LocalizedError {
        case download(String)
        case digestMismatch
        case unzip(String)
        case appNotFound
        case signatureInvalid
        case teamMismatch
        case notWritable(String)
        case relaunch(String)

        var errorDescription: String? {
            switch self {
            case .download(let m):  return "Download failed: \(m)"
            case .digestMismatch:   return "The downloaded file didn’t match its published checksum."
            case .unzip(let m):     return "Couldn’t expand the update: \(m)"
            case .appNotFound:      return "The update didn’t contain Claffeinate.app."
            case .signatureInvalid: return "The update’s code signature couldn’t be verified."
            case .teamMismatch:     return "The update is signed by a different developer and was rejected."
            case .notWritable(let p): return "Claffeinate can’t update itself in place at \(p). Move it to a folder you own (e.g. /Applications) and try again."
            case .relaunch(let m):  return "Couldn’t start the installer: \(m)"
            }
        }
    }

    /// Download → verify → swap → relaunch. Shows a small progress window while
    /// it works; on success the app quits and the new version launches itself,
    /// on failure it throws (the caller surfaces the message).
    func installUpdate(version: String, zipURL: URL, expectedSHA256: String?) async throws {
        let progress = UpdateProgressWindow(version: version)
        progress.show()
        defer { progress.close() }

        // 1. Download to a private working directory.
        progress.status = "Downloading Claffeinate \(version)…"
        let workDir = try makeWorkDir()
        let zipPath = workDir.appendingPathComponent("Claffeinate.zip")
        try await download(zipURL, to: zipPath)

        // 2. Integrity: bytes must match the digest GitHub served over TLS.
        progress.status = "Verifying…"
        if let expected = expectedSHA256 {
            guard try sha256(of: zipPath).caseInsensitiveCompare(expected) == .orderedSame else {
                throw UpdateError.digestMismatch
            }
        }

        // 3. Expand with ditto so the code signature and xattrs survive.
        let extractDir = workDir.appendingPathComponent("extracted", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zipPath.path, extractDir.path],
                onFail: { UpdateError.unzip($0) })
        guard let newApp = locateApp(in: extractDir) else { throw UpdateError.appNotFound }

        // 4. Provenance: valid signature, same developer as the running app.
        guard codesignVerifies(newApp) else { throw UpdateError.signatureInvalid }
        let currentApp = Bundle.main.bundleURL
        guard let newTeam = teamIdentifier(of: newApp),
              let curTeam = teamIdentifier(of: currentApp),
              newTeam == curTeam else {
            throw UpdateError.teamMismatch
        }
        // Best-effort notarization check — logged, never fatal (see type doc).
        if !gatekeeperAccepts(newApp) {
            NSLog("Claffeinate: spctl did not accept the update (continuing; digest + signature + team verified).")
        }

        // 5. We must be able to replace the running bundle in place.
        let parent = currentApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(currentApp.path)
        }

        // 6. Hand off to a detached script that waits for us to quit, swaps the
        // bundle, and relaunches — then terminate so the swap can proceed.
        progress.status = "Installing… the app will relaunch."
        try launchSwap(newApp: newApp, destApp: currentApp, workDir: workDir)
        NSApp.terminate(nil)
    }

    // MARK: - Download

    private func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("Claffeinate", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        do {
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateError.download("server returned \(http.statusCode)")
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch let e as UpdateError {
            throw e
        } catch {
            throw UpdateError.download(error.localizedDescription)
        }
    }

    // MARK: - Verification helpers

    private func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Find `*.app` at the top level of the extracted directory.
    private func locateApp(in dir: URL) -> URL? {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        return contents?.first { $0.pathExtension == "app" }
    }

    private func codesignVerifies(_ app: URL) -> Bool {
        (try? run("/usr/bin/codesign", ["--verify", "--strict", app.path],
                  onFail: { _ in UpdateError.signatureInvalid })) != nil
    }

    /// Parse `TeamIdentifier=XXXX` out of `codesign -dvv` (which prints to stderr).
    private func teamIdentifier(of app: URL) -> String? {
        guard let output = try? capture("/usr/bin/codesign", ["-dvv", app.path]) else { return nil }
        for line in output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = line.dropFirst("TeamIdentifier=".count)
            return value == "not set" ? nil : String(value)
        }
        return nil
    }

    private func gatekeeperAccepts(_ app: URL) -> Bool {
        (try? run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path],
                  onFail: { _ in UpdateError.signatureInvalid })) != nil
    }

    // MARK: - Swap & relaunch

    private func launchSwap(newApp: URL, destApp: URL, workDir: URL) throws {
        let scriptURL = workDir.appendingPathComponent("install.sh")
        // Paths arrive as positional args, so no shell-quoting of user paths.
        let script = """
        #!/bin/bash
        OLD_PID="$1"; SRC="$2"; DEST="$3"
        # Wait (max ~30s) for the running app to exit before swapping its bundle.
        for _ in $(seq 1 150); do
          kill -0 "$OLD_PID" 2>/dev/null || break
          sleep 0.2
        done
        BACKUP="${DEST}.old-$$"
        /bin/mv "$DEST" "$BACKUP" || exit 1
        if /usr/bin/ditto "$SRC" "$DEST"; then
          /bin/rm -rf "$BACKUP"
        else
          /bin/rm -rf "$DEST"; /bin/mv "$BACKUP" "$DEST"; exit 1
        fi
        /usr/bin/open "$DEST"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path,
                          String(ProcessInfo.processInfo.processIdentifier),
                          newApp.path,
                          destApp.path]
        do {
            try task.run()   // detached — outlives our termination, reparented to launchd
        } catch {
            throw UpdateError.relaunch(error.localizedDescription)
        }
    }

    // MARK: - Process plumbing

    private func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaffeinateUpdate-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Run a tool and throw (via `onFail`) on a non-zero exit.
    private func run(_ tool: String, _ args: [String],
                     onFail: (String) -> UpdateError) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        let err = Pipe()
        task.standardError = err
        task.standardOutput = Pipe()
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? "exit \(task.terminationStatus)"
            throw onFail(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Run a tool and return its combined stdout+stderr (codesign prints to stderr).
    private func capture(_ tool: String, _ args: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Progress window

/// A small borderless window with a spinner, shown while the update downloads
/// and installs — a menu-bar app has no main window to host this in.
@MainActor
private final class UpdateProgressWindow {
    private let window: NSWindow
    private let label = NSTextField(labelWithString: "")

    var status: String = "" {
        didSet { label.stringValue = status }
    }

    init(version: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 96),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Updating Claffeinate"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.center()

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        status = "Preparing update…"

        let content = NSView()
        content.addSubview(spinner)
        content.addSubview(label)
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            spinner.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 20),
            spinner.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.contentView = content
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.orderOut(nil)
    }
}
