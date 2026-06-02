import AppKit
import Foundation

// MARK: - Update Checker

/// Polls a public Gist for the latest version. When an update is available,
/// downloads the DMG, mounts it, copies the new app over the running one,
/// unmounts, then relaunches — no manual steps required.

final class UpdateChecker {
    static let shared = UpdateChecker()
    private init() {}

    private let feedURL = URL(string:
        "https://gist.githubusercontent.com/samatojr/f1c4f80f0f854b40522e4e1bfb124791/raw/version.json"
    )!

    // MARK: - Public API

    func checkOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.check(userInitiated: false)
        }
    }

    func checkNow() {
        check(userInitiated: true)
    }

    // MARK: - Check

    private func check(userInitiated: Bool) {
        URLSession.shared.dataTask(with: feedURL) { data, _, error in
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
        }.resume()
    }

    private func handleResponse(_ info: VersionInfo, userInitiated: Bool) {
        let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey:
            kCFBundleVersionKey as String) as? String ?? "0") ?? 0

        if info.build > currentBuild {
            showUpdateAvailable(info)
        } else if userInitiated {
            let alert = NSAlert.make()
            alert.messageText = "Notepad is up to date"
            alert.informativeText = "You're running version \(appVersion()) (build \(currentBuild))."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Update Prompt

    private func showUpdateAvailable(_ info: VersionInfo) {
        let alert = NSAlert.make()
        alert.messageText = "Notepad \(info.version) is available"
        alert.informativeText = """
            You have version \(appVersion()). \(info.releaseNotes)

            Click Install to download and relaunch automatically.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            downloadAndInstall(info)
        }
    }

    // MARK: - Download

    private func downloadAndInstall(_ info: VersionInfo) {
        guard let url = URL(string: info.downloadURL) else { return }

        let panel = makeProgressPanel(message: "Downloading Notepad \(info.version)…")
        panel.makeKeyAndOrderFront(nil)

        URLSession.shared.downloadTask(with: url) { tempURL, _, error in
            DispatchQueue.main.async {
                panel.orderOut(nil)
                if let error { self.showError(error.localizedDescription); return }
                guard let tempURL else { self.showError("Download failed."); return }

                // Move download out of the system temp location before mounting
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("NotepadUpdate-\(UUID().uuidString).dmg")
                do {
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                } catch {
                    self.showError("Could not save the downloaded update: \(error.localizedDescription)")
                    return
                }
                // Strip quarantine attribute — URLSession tags downloads with
                // com.apple.quarantine which can cause hdiutil to refuse mounting
                _ = self.run("/usr/bin/xattr", args: ["-d", "com.apple.quarantine", dest.path])
                self.mountAndInstall(dmgURL: dest, version: info.version)
            }
        }.resume()
    }

    // MARK: - Mount → Copy → Relaunch

    private func mountAndInstall(dmgURL: URL, version: String) {
        let panel = makeProgressPanel(message: "Installing Notepad \(version)…")
        panel.makeKeyAndOrderFront(nil)

        DispatchQueue.global(qos: .userInitiated).async {
            // Mount the DMG silently
            let mountPoint = self.run("/usr/bin/hdiutil",
                args: ["attach", dmgURL.path, "-nobrowse", "-mountrandom", "/tmp", "-plist"])

            // Parse the mount point from hdiutil's plist output
            guard let mountPath = self.parseMountPoint(from: mountPoint) else {
                DispatchQueue.main.async {
                    panel.orderOut(nil)
                    self.showError("Could not mount the update disk image.")
                }
                return
            }

            defer {
                _ = self.run("/usr/bin/hdiutil", args: ["detach", mountPath, "-quiet"])
                try? FileManager.default.removeItem(at: dmgURL)
            }

            // Find the .app inside the mounted volume
            let fm = FileManager.default
            guard let appName = (try? fm.contentsOfDirectory(atPath: mountPath))?
                    .first(where: { $0.hasSuffix(".app") })
            else {
                DispatchQueue.main.async {
                    panel.orderOut(nil)
                    self.showError("Could not find the app inside the update.")
                }
                return
            }

            let sourceApp = URL(fileURLWithPath: mountPath).appendingPathComponent(appName)
            let currentApp = Bundle.main.bundleURL
            let destination = currentApp.deletingLastPathComponent().appendingPathComponent(appName)

            // Replace running app with new version
            var resultURL: NSURL?
            let replaceError: Error?
            do {
                try fm.replaceItem(at: destination,
                                   withItemAt: sourceApp,
                                   backupItemName: nil,
                                   options: [],
                                   resultingItemURL: &resultURL)
                replaceError = nil
            } catch {
                replaceError = error
            }

            DispatchQueue.main.async {
                panel.orderOut(nil)
                if let replaceError {
                    self.showError("Could not replace the app: \(replaceError.localizedDescription)")
                    return
                }
                // Small delay so the DMG can be detached before we relaunch
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let finalURL = (resultURL as URL?) ?? destination
                    let config = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.openApplication(at: finalURL, configuration: config) { _, _ in }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func run(_ path: String, args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func parseMountPoint(from plistOutput: String) -> String? {
        guard let data = plistOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]]
        else { return nil }

        for entity in entities {
            if let point = entity["mount-point"] as? String {
                return point
            }
        }
        return nil
    }

    private func makeProgressPanel(message: String) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 70),
                            styleMask: [.titled, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.title = ""
        panel.isFloatingPanel = true
        panel.center()

        let label = NSTextField(labelWithString: message)
        label.frame = NSRect(x: 16, y: 38, width: 268, height: 18)
        label.font = .systemFont(ofSize: 13)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: 16, y: 12, width: 16, height: 16)
        spinner.startAnimation(nil)

        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(spinner)
        return panel
    }

    private func showError(_ message: String) {
        let alert = NSAlert.make()
        alert.messageText = "Update failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

// MARK: - Version Info

private struct VersionInfo: Decodable {
    let version: String
    let build: Int
    let downloadURL: String
    let releaseNotes: String

    enum CodingKeys: String, CodingKey {
        case version, build
        case downloadURL  = "download_url"
        case releaseNotes = "release_notes"
    }
}
