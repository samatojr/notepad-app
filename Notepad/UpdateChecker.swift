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
            alert.informativeText = "You're running version \(appVersion())."
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

                // Move to a stable path with .dmg extension before opening
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("NotepadUpdate-\(UUID().uuidString).dmg")
                do {
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                } catch {
                    self.showError("Could not save the downloaded update: \(error.localizedDescription)")
                    return
                }
                self.openDMGForInstall(dmgURL: dest, version: info.version)
            }
        }.resume()
    }

    // MARK: - Automated install

    private func openDMGForInstall(dmgURL: URL, version: String) {
        // Strip quarantine from the downloaded DMG so hdiutil can mount it cleanly.
        shell("/usr/bin/xattr", ["-d", "com.apple.quarantine", dmgURL.path])

        // Mount silently.
        let mountOutput = shell("/usr/bin/hdiutil",
                                ["attach", "-nobrowse", "-quiet", dmgURL.path])

        // Find the mount point — hdiutil prints it as the last token on the last line.
        guard let mountPoint = mountOutput
                .components(separatedBy: "\n")
                .last(where: { $0.contains("/Volumes/") })?
                .components(separatedBy: "\t").last?
                .trimmingCharacters(in: .whitespaces),
              !mountPoint.isEmpty
        else {
            fallbackManualInstall(dmgURL: dmgURL, version: version); return
        }

        // Locate the .app inside the mounted volume.
        let fm = FileManager.default
        guard let appName = (try? fm.contentsOfDirectory(atPath: mountPoint))?
                .first(where: { $0.hasSuffix(".app") })
        else {
            hdiutil_detach(mountPoint)
            fallbackManualInstall(dmgURL: dmgURL, version: version); return
        }

        let sourceApp = URL(fileURLWithPath: mountPoint).appendingPathComponent(appName)

        // Target: same folder the running app is in (usually /Applications).
        let runningApp  = URL(fileURLWithPath: Bundle.main.bundlePath)
        let destination = runningApp.deletingLastPathComponent()
                                    .appendingPathComponent(appName)

        do {
            // Replace the existing app bundle.
            _ = try fm.replaceItemAt(destination, withItemAt: sourceApp,
                                     backupItemName: nil,
                                     options: .usingNewMetadataOnly)
        } catch {
            hdiutil_detach(mountPoint)
            fallbackManualInstall(dmgURL: dmgURL, version: version); return
        }

        // Strip quarantine from the freshly installed app.
        shell("/usr/bin/xattr", ["-cr", destination.path])

        hdiutil_detach(mountPoint)

        // Prompt to relaunch.
        let alert = NSAlert.make()
        alert.messageText    = "Notepad \(version) installed"
        alert.informativeText = "Relaunch now to start using the new version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(
                at: destination, configuration: cfg) { _, _ in }
            NSApp.terminate(nil)
        }
    }

    private func fallbackManualInstall(dmgURL: URL, version: String) {
        NSWorkspace.shared.open(dmgURL)
        let alert = NSAlert.make()
        alert.messageText     = "Manual install needed"
        alert.informativeText = "Drag Notepad from the installer window into Applications, then relaunch Notepad."
        alert.alertStyle      = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @discardableResult
    private func shell(_ path: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                      encoding: .utf8) ?? ""
    }

    private func hdiutil_detach(_ mountPoint: String) {
        shell("/usr/bin/hdiutil", ["detach", mountPoint, "-quiet"])
    }

    // MARK: - Helpers

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
