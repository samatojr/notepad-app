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
        // Observe NSWorkspace for the DMG volume to mount — no hdiutil Process needed.
        var observer: NSObjectProtocol?
        var installed = false

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self,
                  let volumeURL = notif.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            else { return }

            // Only act on a volume that contains our app.
            let fm = FileManager.default
            guard let appName = (try? fm.contentsOfDirectory(atPath: volumeURL.path))?
                    .first(where: { $0.hasSuffix(".app") }),
                  appName.lowercased().contains("notepad")
            else { return }

            if let obs = observer {
                NSWorkspace.shared.notificationCenter.removeObserver(obs)
                observer = nil
            }
            installed = true
            self.installFromVolume(volumeURL: volumeURL, appName: appName, version: version)
        }

        // Open the DMG — macOS mounts it and fires didMountNotification.
        NSWorkspace.shared.open(dmgURL)

        // Fallback: if the volume never mounts within 30 s, show manual instructions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if let obs = observer {
                NSWorkspace.shared.notificationCenter.removeObserver(obs)
                observer = nil
            }
            if !installed { self?.showManualFallback() }
        }
    }

    private func installFromVolume(volumeURL: URL, appName: String, version: String) {
        let fm          = FileManager.default
        let sourceApp   = volumeURL.appendingPathComponent(appName)
        let runningApp  = URL(fileURLWithPath: Bundle.main.bundlePath)
        let destination = runningApp.deletingLastPathComponent().appendingPathComponent(appName)

        do {
            _ = try fm.replaceItemAt(destination, withItemAt: sourceApp,
                                     backupItemName: nil,
                                     options: .usingNewMetadataOnly)
        } catch {
            try? NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)
            showManualFallback(); return
        }

        // Strip quarantine from the installed app.
        shell("/usr/bin/xattr", ["-cr", destination.path])

        try? NSWorkspace.shared.unmountAndEjectDevice(at: volumeURL)

        let alert = NSAlert.make()
        alert.messageText     = "Notepad \(version) installed"
        alert.informativeText = "Relaunch now to start using the new version."
        alert.alertStyle      = .informational
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: destination, configuration: cfg) { _, _ in }
            NSApp.terminate(nil)
        }
    }

    private func showManualFallback() {
        let alert = NSAlert.make()
        alert.messageText     = "Manual install needed"
        alert.informativeText = "Quit Notepad first, then drag Notepad from the installer window into Applications, and relaunch."
        alert.alertStyle      = .informational
        alert.addButton(withTitle: "Quit Notepad")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
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
