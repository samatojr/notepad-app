import SwiftUI
import AppKit

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restore previous session tabs
        let extraCount = SessionManager.shared.pendingCount()
        if extraCount > 0 {
            for i in 0..<extraCount {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(i) * 0.15) {
                    NotificationCenter.default.post(name: .openSessionTab, object: nil)
                }
            }
        }
        // Set the correct icon for the current appearance and watch for changes
        updateDockIcon()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        // Background update check — only shows UI if a newer build is available
        UpdateChecker.shared.checkOnLaunch()
        // EASTER EGG: observe the toggle notification fired when user types "amatopad" in Find.
        // To remove: delete this addObserver call and the handleAmatoPadToggle method below.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAmatoPadToggle),
            name: .amatoPadModeChanged,
            object: nil
        )

        // EASTER EGG: re-apply all appearance changes on launch if mode was persisted
        if AppPreferences.shared.isAmatoPadMode {
            updateDockIcon()
            // Delay slightly so SwiftUI finishes building the menu before we rename it
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.applyAmatoPadAppearance()
            }
        }
    }

    // EASTER EGG: called when the user triggers AmatoPad mode via the find bar.
    // Swaps dock icon, forces dark mode, renames app in menu bar, shows alert.
    // To remove: delete this method and the addObserver call above.
    @objc private func handleAmatoPadToggle() {
        updateDockIcon()
        applyAmatoPadAppearance()
        if AppPreferences.shared.isAmatoPadMode {
            NSApp.requestUserAttention(.informationalRequest)
            // EASTER EGG: NSAlert.make() automatically sets the AmatoPad icon
            let alert = NSAlert.make()
            alert.messageText = "Welcome to AmatoPad! 🎉"
            alert.informativeText = "You've unlocked AmatoPad — the secret edition. Your friends were right all along."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Let's go!")
            alert.runModal()
        }
    }

    // EASTER EGG: forces dark mode and renames the app in the menu bar.
    // NSApp.appearance overrides the system appearance for this process only.
    // The app-menu title (bold name in top-left of menu bar) is the first mainMenu item's title.
    // To remove: delete this method and its call in handleAmatoPadToggle.
    private func applyAmatoPadAppearance() {
        if AppPreferences.shared.isAmatoPadMode {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            NSApp.mainMenu?.items.first?.title = "AmatoPad"
        } else {
            NSApp.appearance = nil                              // restores system appearance
            NSApp.mainMenu?.items.first?.title = "Notepad"     // restores original name
        }
    }

    @objc private func systemAppearanceChanged() {
        DispatchQueue.main.async { self.updateDockIcon() }
    }

    private func updateDockIcon() {
        // EASTER EGG: swap to AmatoPad icon when mode is active.
        // AmatoPadIconImage is Assets.xcassets/AmatoPadIconImage.imageset — safe to delete with the easter egg.
        if AppPreferences.shared.isAmatoPadMode {
            // EASTER EGG: squircle-mask the AmatoPad icon, same as the dark Notepad icon.
            if let img = NSImage(named: "AmatoPadIconImage") {
                NSApplication.shared.applicationIconImage = squircled(img)
            }
            return
        }
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        if isDark {
            // Load the dark icon and apply a squircle mask — macOS 11+ no longer
            // adds the squircle automatically for programmatically-set icons.
            if let img = NSImage(named: "AppIconDark") {
                NSApplication.shared.applicationIconImage = squircled(img)
            }
        } else {
            // Nil resets to the compiled AppIcon.appiconset, which Xcode's asset
            // catalog compiler already renders with the correct squircle.
            NSApplication.shared.applicationIconImage = nil
        }
    }

    /// Clips an image to the macOS squircle shape (≈22.6% corner radius).
    private func squircled(_ source: NSImage) -> NSImage {
        let side: CGFloat = 1024
        let sz   = NSSize(width: side, height: side)
        let result = NSImage(size: sz)
        result.lockFocus()
        // Clear to transparent — lockFocus() defaults to white otherwise
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: sz)).fill()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: sz),
                                xRadius: side * 0.2257,
                                yRadius: side * 0.2257)
        path.addClip()
        source.draw(in: NSRect(origin: .zero, size: sz),
                    from: .zero, operation: .sourceOver, fraction: 1)
        result.unlockFocus()
        return result
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.shared.isTerminating = true
        let states = DocumentRegistry.shared.allStates()
        SessionManager.shared.save(states: states)
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {}

    // EASTER EGG: reapply the menu bar app name after every SwiftUI menu rebuild.
    // SwiftUI regenerates NSMenuItems on state changes, resetting the title; this
    // counteracts that by re-setting it on every app update cycle.
    // To remove: delete this method.
    func applicationDidUpdate(_ notification: Notification) {
        guard AppPreferences.shared.isAmatoPadMode else { return }
        if NSApp.mainMenu?.items.first?.title != "AmatoPad" {
            NSApp.mainMenu?.items.first?.title = "AmatoPad"
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(name: .openFile, object: nil, userInfo: ["url": url])
        }
    }
}

// MARK: - Main App

@main
struct NotepadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var recents = RecentFilesManager.shared

    init() {
        SessionManager.shared.loadAndEnqueue()
        SessionManager.shared.clearClosedTabs()
    }

    var body: some Scene {
        WindowGroup("Notepad", id: "notepad") {
            ContentView()
        }
        .commands {
            NotepadCommands(recents: recents)
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openNotepadWindow = Notification.Name("openNotepadWindow")
    static let openFile          = Notification.Name("openFile")
    static let openSessionTab    = Notification.Name("openSessionTab")
    static let clearSession      = Notification.Name("clearSession")
    // EASTER EGG: fired by findNext() when find text == "amatopad". To remove: delete this line.
    static let amatoPadModeChanged = Notification.Name("amatoPadModeChanged")
}

// MARK: - NSAlert helper

extension NSAlert {
    // EASTER EGG: automatically swaps the alert icon to AmatoPadIconImage when
    // AmatoPad mode is active. Call on every new NSAlert instead of setting .icon manually.
    // To remove: delete this extension and revert all makeAlert() calls to NSAlert().
    static func make() -> NSAlert {
        let alert = NSAlert()
        if AppPreferences.shared.isAmatoPadMode,
           let img = NSImage(named: "AmatoPadIconImage") {
            alert.icon = img
        }
        return alert
    }
}

// MARK: - Focused Value Key

extension FocusedValues {
    @Entry var notepadDocument: NotepadDocument? = nil
}

// MARK: - Commands

struct NotepadCommands: Commands {
    @FocusedValue(\.notepadDocument) private var document: NotepadDocument?
    @ObservedObject var recents: RecentFilesManager

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { document?.newDocument() }
                .keyboardShortcut("n")
            Button("New Tab") {
                NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
            }
            .keyboardShortcut("t")
            Button("New Window") {
                NotificationCenter.default.post(name: .openNotepadWindow, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open…") { document?.openDocument() }
                .keyboardShortcut("o")
            Divider()
            recentFilesMenu
            Divider()
            Button("Clear Session") {
                // Prompt to save each modified document
                for doc in DocumentRegistry.shared.allDocuments().filter({ $0.isModified }) {
                    let alert = NSAlert.make()
                    alert.messageText = "Save changes to \"\(doc.displayName)\"?"
                    alert.informativeText = "Your unsaved changes will be lost if you clear the session."
                    alert.addButton(withTitle: "Save")
                    alert.addButton(withTitle: "Don't Save")
                    alert.addButton(withTitle: "Cancel")
                    alert.alertStyle = .warning
                    switch alert.runModal() {
                    case .alertFirstButtonReturn: doc.saveDocument()
                    case .alertThirdButtonReturn: return  // user hit Cancel
                    default: break
                    }
                }
                AppState.shared.isClearingSession = true
                SessionManager.shared.clearSession()
                NotificationCenter.default.post(name: .clearSession, object: nil)
            }
            Divider()
            Button("Save") { document?.saveDocument() }
                .keyboardShortcut("s")
            Button("Save As…") { document?.saveAsDocument() }
                .keyboardShortcut("S")
        }

        CommandGroup(replacing: .appInfo) {
            Button("Check for Updates…") { UpdateChecker.shared.checkNow() }
            Divider()
        }

        // ── Edit menu additions ──────────────────────────────────────────────
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find & Replace…") { document?.showFindReplace = true }
                .keyboardShortcut("f")
            Button("Find Next") { document?.findNext() }
                .keyboardShortcut("g")
            Button("Find Previous") { document?.findPrevious() }
                .keyboardShortcut("G")
            Divider()
            Button("Word Count…") { document?.showWordCount = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button(document?.isPrettyPrinted == true ? "Show Original" : "Pretty Print") {
                document?.prettyPrintDocument()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!(document?.language.canPrettyPrint ?? false))
        }

        // ── View menu ────────────────────────────────────────────────────────
        CommandGroup(after: .toolbar) {
            Divider()
            Toggle(isOn: Binding(
                get: { document?.wordWrap ?? true },
                set: { document?.wordWrap = $0 }
            )) { Text("Word Wrap") }
            Toggle(isOn: Binding(
                get: { document?.showStatusBar ?? true },
                set: { document?.showStatusBar = $0 }
            )) { Text("Status Bar") }
            Divider()
            Button("Zoom In")     { document?.fontSize = min(28, (document?.fontSize ?? 13) + 1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out")    { document?.fontSize = max(9,  (document?.fontSize ?? 13) - 1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { document?.fontSize = 13 }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Show All Tabs") {
                NSApp.sendAction(Selector(("toggleTabOverview:")), to: nil, from: nil)
            }
            .keyboardShortcut("\\", modifiers: [.command, .shift])
            Divider()
            Menu("View As Grid") {
                Button("Comma-separated (CSV)") { document?.forceGridView(delimiter: ",") }
                Button("Tab-separated (TSV)")   { document?.forceGridView(delimiter: "\t") }
            }
            .disabled(document == nil)
            Divider()
            Menu("Paper") {
                ForEach(PaperTheme.allCases, id: \.self) { theme in
                    Toggle(isOn: Binding(
                        get: { AppPreferences.shared.paperTheme == theme },
                        set: { if $0 { AppPreferences.shared.paperTheme = theme } }
                    )) { Text(theme.menuLabel) }
                }
            }
        }
    }

    @ViewBuilder
    private var recentFilesMenu: some View {
        if recents.recentURLs.isEmpty {
            Menu("Open Recent") {
                Text("No Recent Files").foregroundStyle(.secondary)
            }
        } else {
            Menu("Open Recent") {
                ForEach(recents.recentURLs, id: \.self) { url in
                    Button(url.lastPathComponent) { document?.loadFile(from: url) }
                }
                Divider()
                Button("Clear All") { recents.clearAll() }
            }
        }
    }

}
