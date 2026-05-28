import SwiftUI
import AppKit

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Open one extra window per remaining session state (first already consumed by initial window)
        let extraCount = SessionManager.shared.pendingCount()
        guard extraCount > 0 else { return }
        for i in 0..<extraCount {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(i) * 0.15) {
                NotificationCenter.default.post(name: .openSessionTab, object: nil)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.shared.isTerminating = true
        let states = DocumentRegistry.shared.allStates()
        SessionManager.shared.save(states: states)
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {}

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
                    let alert = NSAlert()
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

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find & Replace…") { document?.showFindReplace = true }
                .keyboardShortcut("f")
            Button("Find Next") { document?.findNext() }
                .keyboardShortcut("g")
            Button("Find Previous") { document?.findPrevious() }
                .keyboardShortcut("G")
        }

        CommandMenu("Format") {
            Toggle(isOn: Binding(
                get: { document?.wordWrap ?? true },
                set: { document?.wordWrap = $0 }
            )) { Text("Word Wrap") }
            Toggle(isOn: Binding(
                get: { document?.showStatusBar ?? true },
                set: { document?.showStatusBar = $0 }
            )) { Text("Status Bar") }
            Divider()
            Button("Word Count…") { document?.showWordCount = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button(document?.isPrettyPrinted == true ? "Show Original" : "Pretty Print") {
                document?.prettyPrintDocument()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!(document?.language.canPrettyPrint ?? false))
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
                    Menu(url.lastPathComponent) {
                        Button("Open") { document?.loadFile(from: url) }
                        Button("Remove from Recent") { recents.remove(url) }
                    }
                }
                Divider()
                Button("Clear All") { recents.clearAll() }
            }
        }
    }

}
