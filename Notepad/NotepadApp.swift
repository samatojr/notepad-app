import SwiftUI
import AppKit
import Combine
import Sparkle


// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restore previous session tabs
        let extraCount = SessionManager.shared.pendingCount()
        if extraCount > 0 {
            // Restored windows come back standalone and are merged into their
            // saved tab groups at the end. Left to itself AppKit would tab each
            // new window onto the last, which is the arrangement, decided for us.
            NSWindow.allowsAutomaticWindowTabbing = false
            // The ladder keeps window creation sequential. It used to be 0.15s a
            // rung, which put a floor of twenty seconds under a 130-tab session
            // before any window had been drawn.
            let rung = 0.06
            for i in 0..<extraCount {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(i) * rung) {
                    // The token lets exactly one window claim this tab — see SessionTabClaims.
                    NotificationCenter.default.post(name: .openSessionTab, object: nil,
                                                    userInfo: ["token": UUID()])
                }
            }
            let settled = 0.3 + Double(extraCount) * rung + 1.2
            DispatchQueue.main.asyncAfter(deadline: .now() + settled) {
                NSWindow.allowsAutomaticWindowTabbing = true
                DocumentRegistry.shared.regroupRestoredWindows()
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
        // Automatic update checks are handled by Sparkle (SPUStandardUpdaterController,
        // started in NotepadApp.init with startingUpdater: true).
        // EASTER EGG: observe the toggle notification fired when user types "amatopad" in Find.
        // To remove: delete this addObserver call and the handleAmatoPadToggle method below.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAmatoPadToggle),
            name: .amatoPadModeChanged,
            object: nil
        )

        startSessionAutosave()

        // A window closing is the moment a document's unsaved text is either
        // kept or lost for good, and nothing in the app was watching for it.
        // See SaveOnClose.swift.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(documentWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
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

    // MARK: Autosave
    //
    // Through 4.0.1 the session was written when a window closed and when the
    // app quit, and nowhere else. Every other way a run can end — a crash, a
    // force-quit, a power cut, the updater restarting the app — took the only
    // copy of every scratch tab with it, because that copy was in memory.
    // "Close it and it comes back" was true for exactly one of the ways a run
    // ends, which is not what the app promises.
    private var autosaveTimer: Timer?

    /// Ten seconds is the most recent work that an abrupt end can now cost.
    /// Target/selector rather than a closure to keep the timer out of the
    /// actor-isolation weeds; it fires on the main run loop either way.
    private func startSessionAutosave() {
        guard !TestEnvironment.isRunningUnitTests else { return }
        autosaveTimer = Timer.scheduledTimer(timeInterval: 10, target: self,
                                             selector: #selector(autosaveSession),
                                             userInfo: nil, repeats: true)
    }

    @objc private func autosaveSession() {
        SessionManager.shared.persistOpenDocuments()
    }

    /// Switching away from the app is the likeliest quiet moment before
    /// something goes wrong, so take the free checkpoint.
    func applicationDidResignActive(_ notification: Notification) {
        guard !TestEnvironment.isRunningUnitTests else { return }
        SessionManager.shared.persistOpenDocuments()
    }

    /// Fires for every window in the app. Only document windows are in the
    /// registry, so panels, sheets and alerts fall straight through.
    @objc private func documentWindowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              let document = DocumentRegistry.shared.document(for: window) else { return }
        noteWindowWillClose(document)
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
        // Under test there is nothing worth persisting, and both halves of this
        // method are actively harmful: the modal alert would hang the run, and
        // the save would replace the user's real session with an empty one.
        if TestEnvironment.isRunningUnitTests { return .terminateNow }
        // Prompt for every document with unsaved changes. Without this, quitting
        // silently discarded edits to any file-backed document: sessionState only
        // caches text for untitled docs, so restore re-read the stale copy on disk.
        // The prompt itself now lives in SaveOnClose.swift, shared with the close
        // path and Clear Session — closing a window used to reach none of this.
        for doc in DocumentRegistry.shared.allDocuments() {
            // Also cancels the quit when the user picks Save and then dismisses
            // the save panel. That used to fall through and terminate anyway,
            // discarding the very work they had just asked to keep.
            guard resolveUnsavedWork(in: doc,
                                     consequence: "If you don't save, your changes will be lost.")
            else { return .terminateCancel }
        }
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
        // Opening a document should bring the app forward.
        NSApp.activate()
        for url in urls { postOpenFile(url, attempt: 0) }
    }

    /// ContentView only accepts .openFile while it owns the key window, but when the
    /// app is LAUNCHED by opening a file no window exists yet — the notification was
    /// posted into the void and the file silently never opened. Wait for a window to
    /// exist and for session restore to finish claiming its tabs (session tabs also
    /// consume PendingURLManager), then post. Caps at ~2.5s so the file always opens.
    private func postOpenFile(_ url: URL, attempt: Int) {
        let ready = NSApp.keyWindow != nil && !SessionManager.shared.hasPending()
        guard !ready, attempt < 25 else {
            // The token lets exactly one window claim this file — see PendingURLManager.
            NotificationCenter.default.post(name: .openFile, object: nil,
                                           userInfo: ["url": url, "token": UUID()])
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.postOpenFile(url, attempt: attempt + 1)
        }
    }
}

// MARK: - Main App

@main
struct NotepadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var recents = RecentFilesManager.shared

    // Sparkle updater. startingUpdater: true begins the automatic background
    // update schedule (checks the appcast feed on its own cadence).
    private let updaterController: SPUStandardUpdaterController

    init() {
        // Notepad restores its own windows from SessionManager. AppKit's Resume
        // feature was *also* reopening the previous run's windows — the lldb
        // backtrace runs _reopenWindowsAsNecessaryIncludingRestorableState ->
        // SwiftUI.AppWindowsController.restoreWindow(withIdentifier:state:) — so a
        // launch reopened last run's window count no matter what the session held,
        // and a "clean" launch still came up with several blank Untitled windows.
        // Registering rather than setting keeps this out of the saved preferences.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
        // A test run launches this very app (the test bundle is injected into it),
        // so it must not touch the real session: loadAndEnqueue would reopen the
        // user's windows and clearClosedTabs writes straight to their defaults.
        if !TestEnvironment.isRunningUnitTests {
            // Before loadAndEnqueue, which ages entries against this number.
            _ = LaunchCounter.advance()
            SessionManager.shared.loadAndEnqueue()
            // NOT cleared any more: the buffer is where aged-out scratch tabs
            // are kept, and wiping it on launch would throw away exactly what
            // retention just decided to hold on to.
        }
        // Sparkle runs only in Release builds of the shipping app.
        //
        // A debug build carries the same production SUFeedURL, and the shipped
        // defaults have SUAutomaticallyUpdate on — so a development build whose
        // CFBundleVersion is behind the appcast will quietly download the
        // RELEASED app and install it over the build being tested. Debug builds
        // must never talk to the production feed.
        //
        // Also stopped under test: a background check firing mid-run is noise at
        // best and a network dependency at worst.
        #if DEBUG
        let shouldStartUpdater = false
        #else
        let shouldStartUpdater = !TestEnvironment.isRunningUnitTests
        #endif
        updaterController = SPUStandardUpdaterController(
            startingUpdater: shouldStartUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup("Notepad", id: "notepad") {
            ContentView()
        }
        .commands {
            NotepadCommands(recents: recents, updater: updaterController.updater)
        }
    }
}

// MARK: - Sparkle "Check for Updates" menu wiring (official SwiftUI pattern)

/// Publishes whether the updater can currently check (disabled mid-check).
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The "Check for Updates…" menu item, bound to Sparkle's updater.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openNotepadWindow = Notification.Name("openNotepadWindow")
    static let openFile          = Notification.Name("openFile")
    static let openSessionTab    = Notification.Name("openSessionTab")
    static let clearSession      = Notification.Name("clearSession")
    static let reopenClosedTab   = Notification.Name("reopenClosedTab")
    static let openNotepadTab    = Notification.Name("openNotepadTab")
    // EASTER EGG: fired by findNext() when find text == "amatopad". To remove: delete this line.
    static let amatoPadModeChanged = Notification.Name("amatoPadModeChanged")
}

// MARK: - About

private func showAbout() {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let alert   = NSAlert.make()
    alert.messageText    = "Notepad"
    alert.informativeText = "Version \(version)\n\nA fast, clean text editor for macOS."
    alert.alertStyle     = .informational
    if let icon = NSApp.applicationIconImage { alert.icon = icon }
    alert.addButton(withTitle: "OK")
    alert.runModal()
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

// MARK: - Table menu state

/// What the Table menu can act on right now.
///
/// Built only from document properties the grid publishes as the selection
/// and sort change. They are all observable, so SwiftUI rebuilds the menu when
/// they move.
struct GridMenuState {
    var isGrid = false
    var showsHeaders = true
    var isSorted = false
    var dataRows = 0
    /// Separate pieces selected — more than one after ⌘-clicking cells apart.
    var pieces = 0
    /// The tallest and widest single piece. Fill works piece by piece, so it
    /// needs one piece at least two rows tall (or two columns wide).
    var tallestPiece = 0
    var widestPiece = 0
    /// Columns touched by any piece — what Join and Split act on.
    var distinctColumns = 0
    /// Every piece runs the full height of the grid.
    var wholeColumns = false
    /// First and last selected rows as displayed, for a single piece. Only
    /// meaningful unsorted, the only time they are used: a sorted grid can't move rows.
    private var topRow = 0
    private var bottomRow = 0

    init(_ doc: NotepadDocument?) {
        guard let doc, doc.csvIsTableView, !doc.csvRows.isEmpty else { return }
        isGrid = true
        showsHeaders = doc.csvShowHeaders
        isSorted = !doc.csvSortKeys.isEmpty
        let offset = doc.csvShowHeaders ? 1 : 0
        dataRows = max(0, doc.csvRows.count - offset)

        let blocks = doc.csvSelectionBlocks
        pieces = blocks.count
        tallestPiece = blocks.map(\.rows.count).max() ?? 0
        widestPiece = blocks.map(\.columns.count).max() ?? 0
        distinctColumns = Set(blocks.flatMap { Array($0.columns) }).count
        wholeColumns = !blocks.isEmpty && blocks.allSatisfy { $0.rows.count == dataRows }
        if blocks.count == 1, let first = blocks[0].rows.min(), let last = blocks[0].rows.max() {
            topRow = first - offset
            bottomRow = last - offset
        }
    }

    var hasSelection: Bool { pieces > 0 }
    /// One rectangle — what "before the selection" and moving rows need.
    var isSinglePiece: Bool { pieces == 1 }
    // Left enabled while sorted: choosing it explains why rows can't move and
    // offers Keep Sorted Order, which beats an item that is grey for no stated reason.
    var canMoveUp: Bool   { isSinglePiece && (isSorted || topRow > 0) }
    var canMoveDown: Bool { isSinglePiece && (isSorted || bottomRow < dataRows - 1) }
}

// MARK: - Commands

struct NotepadCommands: Commands {
    @FocusedValue(\.notepadDocument) private var document: NotepadDocument?

    /// The document these commands act on.
    ///
    /// SwiftUI's focused value is the primary source, but it goes nil whenever
    /// nothing in the window holds first responder — which is exactly the state
    /// left behind by switching between grid and raw text. `document?.save…()`
    /// on a nil is a silent no-op while the menu item still looks enabled, so
    /// ⌘S appeared to work and saved nothing. Falling back to the key window's
    /// document makes every command act on what the user is looking at.
    private var target: NotepadDocument? {
        document ?? DocumentRegistry.shared.activeDocument
    }

    /// Sends a Table-menu action up the responder chain to whichever grid has
    /// focus. Nothing happens in a text document, which is the point.
    private func sendToGrid(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
    @ObservedObject var recents: RecentFilesManager
    let updater: SPUUpdater

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { target?.newDocument() }
                .keyboardShortcut("n")
            Button("New Tab") {
                // Was NSApp.sendAction(newWindowForTab:), which asks AppKit to
                // make the tab and depends on the frontmost window answering.
                // With SwiftUI's WindowGroup windows that is unreliable — ⌘T
                // produced a separate window about as often as a tab. The app
                // makes the window itself now and tabs it deliberately.
                NotificationCenter.default.post(name: .openNotepadTab, object: nil)
            }
            .keyboardShortcut("t")
            Button("Reopen Closed Tab") {
                // Deliberately NOT .disabled() on hasClosedTab(): that reads
                // non-observable state, and a menu item whose enablement SwiftUI
                // cannot track is one that sticks in whatever state it was built
                // with. Beeping on an empty buffer is the honest version.
                guard SessionManager.shared.hasClosedTab() else { NSSound.beep(); return }
                NotificationCenter.default.post(name: .reopenClosedTab, object: nil,
                                                userInfo: ["token": UUID()])
            }
            .keyboardShortcut("T", modifiers: [.command, .shift])
            Button("New Window") {
                NotificationCenter.default.post(name: .openNotepadWindow, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open…") { target?.openDocument() }
                .keyboardShortcut("o")
            Divider()
            recentFilesMenu
            Divider()
            Menu("Reopen with Encoding") {
                ForEach(FileEncoding.menuCases, id: \.self) { encoding in
                    Button(encoding.displayName) { target?.reopen(with: encoding) }
                }
            }
            .disabled(target?.fileURL == nil)
            Menu("Save with Encoding") {
                ForEach(FileEncoding.menuCases, id: \.self) { encoding in
                    Toggle(isOn: Binding(
                        get: { target?.fileEncoding == encoding },
                        set: { if $0 { target?.setEncoding(encoding) } }
                    )) { Text(encoding.displayName) }
                }
            }
            .disabled(document == nil)
            Menu("Line Endings") {
                ForEach(LineEnding.allCases, id: \.self) { ending in
                    Toggle(isOn: Binding(
                        get: { target?.lineEnding == ending },
                        set: { if $0 { target?.setLineEnding(ending) } }
                    )) { Text(ending.displayName) }
                }
            }
            .disabled(document == nil)
            Divider()
            Button("Clear Session") {
                // Prompt to save each modified document. Same shared prompt the
                // quit and window-close paths use — see SaveOnClose.swift.
                for doc in DocumentRegistry.shared.allDocuments() {
                    // .permanent: this is the one action that wipes the session
                    // AND the recovery buffer, so even scratch text — which
                    // closing and quitting no longer ask about — is genuinely
                    // about to be destroyed and has to be offered first.
                    guard resolveUnsavedWork(
                        in: doc,
                        consequence: "Your unsaved changes will be lost if you clear the session.",
                        discard: .permanent
                    ) else { return }   // user cancelled
                }
                AppState.shared.isClearingSession = true
                SessionManager.shared.clearSession()
                NotificationCenter.default.post(name: .clearSession, object: nil)
            }
            Divider()
            Button("Save") { target?.saveDocument() }
                .keyboardShortcut("s")
            Button("Save As…") { target?.saveAsDocument() }
                .keyboardShortcut("S")
        }

        // ── Printing ─────────────────────────────────────────────────────────
        CommandGroup(replacing: .printItem) {
            Button("Page Setup…") { DocumentPrinter.pageSetup(window: NSApp.keyWindow) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Print…") { target?.printDocument(window: NSApp.keyWindow) }
                .keyboardShortcut("p")
                .disabled(document == nil)
        }

        CommandGroup(replacing: .appInfo) {
            Button("About Notepad") { showAbout() }
            Divider()
            CheckForUpdatesView(updater: updater)
            Divider()
        }

        // ── Edit menu additions ──────────────────────────────────────────────
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find & Replace…") { target?.showFindReplace = true }
                .keyboardShortcut("f")
            Button("Find Next") { target?.findNext() }
                .keyboardShortcut("g")
            Button("Find Previous") { target?.findPrevious() }
                .keyboardShortcut("G")
            Divider()
            Button("Go to Line…") { target?.promptGoToLine() }
                .keyboardShortcut("l")
                .disabled(document == nil)
            Divider()
            Button("Word Count…") { target?.showWordCount = true }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button(target?.isPrettyPrinted == true ? "Show Original" : "Pretty Print") {
                target?.prettyPrintDocument()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!(target?.language.canPrettyPrint ?? false))
        }

        // ── View menu ────────────────────────────────────────────────────────
        // MARK: Table menu
        //
        // The grid operations existed only in context menus, which meant a user who
        // did not think to right-click never found them at all. Every item here is
        // dispatched up the responder chain with NSApp.sendAction(_:to:from:), so
        // it reaches the grid that has focus and nothing else.
        //
        // Enablement comes from GridMenuState, which reads only OBSERVABLE document
        // state the grid publishes. The first attempt read NSApp.keyWindow, which
        // SwiftUI cannot track, so items stuck in whatever state they were built in.
        CommandMenu("Table") {
            let grid = GridMenuState(document)

            Button("Fill Down")  { sendToGrid(#selector(CopyableTableView.fillDownAction(_:))) }
                .keyboardShortcut("d")
                .disabled(grid.tallestPiece < 2)
            Button("Fill Right") { sendToGrid(#selector(CopyableTableView.fillRightAction(_:))) }
                .keyboardShortcut("r")
                .disabled(grid.widestPiece < 2)
            Button("Fill Series") { sendToGrid(#selector(CopyableTableView.fillSeriesAction(_:))) }
                .disabled(grid.tallestPiece < 2)

            Divider()

            Button("New Column from Calculation…") {
                sendToGrid(#selector(CopyableTableView.calculateAction(_:)))
            }
            .disabled(!grid.isGrid)
            Button("Add Totals Row") { sendToGrid(#selector(CopyableTableView.totalsAction(_:))) }
                .disabled(grid.dataRows == 0)
            Menu("Text") {
                Button("Trim Spaces") { sendToGrid(#selector(CopyableTableView.trimSpacesAction(_:))) }
                Button("UPPERCASE")   { sendToGrid(#selector(CopyableTableView.uppercaseAction(_:))) }
                Button("lowercase")   { sendToGrid(#selector(CopyableTableView.lowercaseAction(_:))) }
                Button("Title Case")  { sendToGrid(#selector(CopyableTableView.titleCaseAction(_:))) }
                Divider()
                Button("Join Columns…") { sendToGrid(#selector(CopyableTableView.joinColumnsAction(_:))) }
                    .disabled(grid.distinctColumns < 2)
                Button("Split Column…") { sendToGrid(#selector(CopyableTableView.splitColumnAction(_:))) }
                    .disabled(grid.distinctColumns != 1)
            }
            .disabled(!grid.hasSelection)

            Divider()

            Button("Insert Column Before") {
                sendToGrid(#selector(CopyableTableView.insertColumnBeforeAction(_:)))
            }
            .disabled(!grid.isSinglePiece)
            Button("Insert Column After") {
                sendToGrid(#selector(CopyableTableView.insertColumnAfterAction(_:)))
            }
            .disabled(!grid.isSinglePiece)
            Button("Delete Columns") {
                sendToGrid(#selector(CopyableTableView.deleteColumnsAction(_:)))
            }
            .disabled(!grid.wholeColumns)
            Button("Rename Column…") {
                sendToGrid(#selector(CopyableTableView.renameColumnAction(_:)))
            }
            .disabled(!grid.isSinglePiece || !grid.showsHeaders)

            Divider()

            Button("Insert Row") { sendToGrid(#selector(CopyableTableView.insertRowAction(_:))) }
                .disabled(!grid.isGrid)
            Button("Duplicate Rows") {
                sendToGrid(#selector(CopyableTableView.duplicateRowsAction(_:)))
            }
            .disabled(!grid.hasSelection)
            Button("Move Rows Up") { sendToGrid(#selector(CopyableTableView.moveRowsUpAction(_:))) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!grid.canMoveUp)
            Button("Move Rows Down") { sendToGrid(#selector(CopyableTableView.moveRowsDownAction(_:))) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!grid.canMoveDown)
            Button("Delete Rows") {
                sendToGrid(#selector(CopyableTableView.deleteRowsAction(_:)))
            }
            .disabled(!grid.hasSelection)

            Divider()

            Button("Keep Sorted Order") { sendToGrid(#selector(CopyableTableView.keepSortAction(_:))) }
                .disabled(!grid.isSorted)
            Button("Clear Sort") { sendToGrid(#selector(CopyableTableView.clearSortAction(_:))) }
                .disabled(!grid.isSorted)
        }

        CommandGroup(after: .toolbar) {
            Divider()
            Toggle(isOn: Binding(
                get: { target?.wordWrap ?? true },
                set: { target?.wordWrap = $0 }
            )) { Text("Word Wrap") }
            Toggle(isOn: Binding(
                get: { target?.showStatusBar ?? true },
                set: { target?.showStatusBar = $0 }
            )) { Text("Status Bar") }
            Divider()
            Button("Zoom In")     { target?.fontSize = min(28, (target?.fontSize ?? 13) + 1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out")    { target?.fontSize = max(9,  (target?.fontSize ?? 13) - 1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { target?.fontSize = 13 }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Button("Show All Tabs") {
                NSApp.sendAction(Selector(("toggleTabOverview:")), to: nil, from: nil)
            }
            .keyboardShortcut("\\", modifiers: [.command, .shift])
            Divider()
            Menu("View As Grid") {
                Button("Comma-separated (CSV)") { target?.forceGridView(delimiter: ",") }
                Button("Tab-separated (TSV)")   { target?.forceGridView(delimiter: "\t") }
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
                    Button(url.lastPathComponent) { target?.loadFile(from: url) }
                }
                Divider()
                Button("Clear All") { recents.clearAll() }
            }
        }
    }

}
