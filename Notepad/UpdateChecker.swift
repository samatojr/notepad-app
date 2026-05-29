import AppKit
import Foundation

// MARK: - Update Checker

/// Lightweight update checker — polls a public Gist for the latest version
/// and presents a native alert when a newer build is available.
///
/// Update the Gist at:
/// https://gist.github.com/samatojr/f1c4f80f0f854b40522e4e1bfb124791
/// whenever a new release ships.

final class UpdateChecker {
    static let shared = UpdateChecker()
    private init() {}

    private let feedURL = URL(string:
        "https://gist.githubusercontent.com/samatojr/f1c4f80f0f854b40522e4e1bfb124791/raw/version.json"
    )!

    // MARK: - Public API

    /// Called at launch — waits a few seconds so it doesn't block startup,
    /// then silently checks; only shows UI if a newer build is found.
    func checkOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.check(userInitiated: false)
        }
    }

    /// Called from the "Check for Updates…" menu item — always shows a result.
    func checkNow() {
        check(userInitiated: true)
    }

    // MARK: - Private

    private func check(userInitiated: Bool) {
        let task = URLSession.shared.dataTask(with: feedURL) { data, _, error in
            DispatchQueue.main.async {
                if let error {
                    if userInitiated { self.showError(error.localizedDescription) }
                    return
                }
                guard let data,
                      let info = try? JSONDecoder().decode(VersionInfo.self, from: data)
                else {
                    if userInitiated { self.showError("Could not read version info.") }
                    return
                }
                self.handleResponse(info, userInitiated: userInitiated)
            }
        }
        task.resume()
    }

    private func handleResponse(_ info: VersionInfo, userInitiated: Bool) {
        let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey:
            kCFBundleVersionKey as String) as? String ?? "0") ?? 0

        if info.build > currentBuild {
            showUpdateAvailable(info)
        } else if userInitiated {
            let alert = NSAlert()
            alert.messageText = "Notepad is up to date"
            alert.informativeText = "You're running version \(appVersion()) (build \(currentBuild))."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func showUpdateAvailable(_ info: VersionInfo) {
        let current = appVersion()
        let alert = NSAlert()
        alert.messageText = "Notepad \(info.version) is available"
        alert.informativeText = """
            You have version \(current). Would you like to download the update?

            \(info.releaseNotes)
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: info.downloadURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Update check failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

// MARK: - Version Info Model

private struct VersionInfo: Decodable {
    let version: String
    let build: Int
    let downloadURL: String
    let releaseNotes: String

    enum CodingKeys: String, CodingKey {
        case version, build
        case downloadURL    = "download_url"
        case releaseNotes   = "release_notes"
    }
}
