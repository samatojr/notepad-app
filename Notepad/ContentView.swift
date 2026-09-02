import SwiftUI
import AppKit
import Observation
import UniformTypeIdentifiers

// MARK: - Document Model

@Observable
final class NotepadDocument {
    var text: String = ""
    var fileURL: URL?
    var isModified: Bool = false
    var wordWrap: Bool = false
    var showStatusBar: Bool = true
    var showWordCount: Bool = false
    var language: Language = .plain

    var requestOpenFile: ((URL) -> Void)?

    var isPrettyPrinted: Bool = false
    var originalText: String? = nil   // raw file text saved when auto-formatting on open
    var fontSize: CGFloat = 13        // editor display size (view-only, never affects file)

    // CSV/TSV — purely view state; document.text is always the source of truth
    var csvRows:           [CSVRow]   = []    // parsed table; row 0 = header
    var csvDelimiter:      Character? = nil   // nil = not in tabular mode
    var csvIsTableView:    Bool       = false // toggle between table and raw text
    var csvIsLoading:      Bool       = false // true while background parse is running
    var csvFindMatchIndex: Int        = 0     // signal for Next/Previous in table find
    var csvShowRowNumbers: Bool       = false // show # column in table view (off by default)
    var csvShowHeaders:   Bool       = true  // show column header row in table view (on by default)
    var csvSortKeys: [CSVSortKey] = []   // ordered: first = primary sort

    var isBeingExplicitlyClosed: Bool = false  // set true when user deliberately closes; skips session restore

    var showFindReplace: Bool = false
    var findText: String = ""
    var replaceText: String = ""
    var findCaseSensitive: Bool = false
    var findHighlightRange: NSRange? = nil

    let sessionID: UUID
    var bookmarkData: Data?
    var windowIndex: Int = 0

    var displayName: String { fileURL?.lastPathComponent ?? "Untitled" }

    init() {
        if let url = PendingURLManager.shared.pendingURL {
            PendingURLManager.shared.pendingURL = nil
            sessionID = UUID()
            fileURL = url
            bookmarkData = SessionManager.shared.makeBookmark(for: url)
            let raw  = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let lang = Language.detect(from: url)
            if lang.canPrettyPrint, let formatted = prettyPrint(text: raw, language: lang) {
                originalText = raw; text = formatted; isPrettyPrinted = true
            } else {
                originalText = nil; text = raw
            }
            if lang.isTabular, let delim = lang.tabularDelimiter {
                parseCSVInBackground(raw, delimiter: delim, showTable: true)
            }
            RecentFilesManager.shared.add(url)
        } else if let state = SessionManager.shared.popClosed() {
            sessionID = state.sessionID
            wordWrap = state.wordWrap
            showStatusBar = state.showStatusBar
            windowIndex = state.windowIndex
            fontSize = state.fontSize ?? 13
            if let bm = state.bookmarkData, let url = SessionManager.shared.resolveBookmark(bm) {
                bookmarkData = bm; fileURL = url
                let onDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if let saved = state.unsavedText {
                    // Cached edits take priority over disk, but only count as
                    // "modified" when they actually differ from what's on disk.
                    text = saved; isModified = saved != onDisk
                } else {
                    text = onDisk
                }
            } else if let saved = state.unsavedText, !saved.isEmpty {
                // An empty untitled tab is not an unsaved document. Restoring it as
                // "Edited" made the window title lie and the quit prompt nag about
                // a blank window.
                text = saved; isModified = true
            }
            restoreCSV(from: state)
        } else if let state = SessionManager.shared.popPending() {
            sessionID = state.sessionID
            wordWrap = state.wordWrap
            showStatusBar = state.showStatusBar
            windowIndex = state.windowIndex
            fontSize = state.fontSize ?? 13
            if let bm = state.bookmarkData, let url = SessionManager.shared.resolveBookmark(bm) {
                bookmarkData = bm; fileURL = url
                let onDisk = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if let saved = state.unsavedText {
                    // Cached edits take priority over disk, but only count as
                    // "modified" when they actually differ from what's on disk.
                    text = saved; isModified = saved != onDisk
                } else {
                    text = onDisk
                }
            } else if let saved = state.unsavedText, !saved.isEmpty {
                // An empty untitled tab is not an unsaved document. Restoring it as
                // "Edited" made the window title lie and the quit prompt nag about
                // a blank window.
                text = saved; isModified = true
            }
            restoreCSV(from: state)
        } else {
            sessionID = UUID()
        }
        language = Language.detect(from: fileURL)
    }

    private func restoreCSV(from state: DocumentSessionState) {
        csvSortKeys = state.csvSortKeys ?? []
        if let delimStr = state.csvDelimiter, let delim = delimStr.first {
            parseCSVInBackground(text, delimiter: delim,
                                 showTable: state.csvIsTableView ?? true)
        } else if let url = fileURL, Language.detect(from: url).isTabular,
                  let delim = Language.detect(from: url).tabularDelimiter {
            parseCSVInBackground(text, delimiter: delim, showTable: true)
        }
    }

    /// Parses `raw` on a background thread so the main thread stays responsive
    /// for large files. Sets csvIsLoading = true until parsing completes.
    func parseCSVInBackground(_ raw: String, delimiter: Character, showTable: Bool) {
        csvDelimiter   = delimiter
        csvIsLoading   = true
        csvIsTableView = false   // show spinner, not a half-built table
        csvRows        = []

        Task.detached(priority: .userInitiated) { [weak self] in
            let rows = parseDelimited(raw, delimiter: delimiter)
            // Bind self to a let BEFORE the await — referencing the captured weak
            // var across a suspension point is an error under Swift 6.
            guard let self else { return }
            await MainActor.run {
                self.csvRows        = rows
                self.csvIsTableView = showTable
                self.csvIsLoading   = false
            }
        }
    }

    func markModified() { isModified = true }

    func reset() {
        text = ""; fileURL = nil; bookmarkData = nil
        isModified = false; language = .plain
        isPrettyPrinted = false; originalText = nil
        showFindReplace = false; findHighlightRange = nil
        findText = ""; replaceText = ""
        csvRows = []; csvDelimiter = nil; csvIsTableView = false
        csvIsLoading = false; csvFindMatchIndex = 0
        // Table view state is per-document too — leaving it set meant the next CSV
        // opened in this tab inherited the previous file's sorting and toggles.
        csvSortKeys = []; csvShowRowNumbers = false; csvShowHeaders = true
    }

    func sessionState(index: Int) -> DocumentSessionState {
        DocumentSessionState(
            sessionID: sessionID,
            // Cache the buffer whenever it differs from disk. Previously only
            // untitled docs and modified CSVs were cached, so unsaved edits to any
            // other file-backed document were dropped on restore.
            unsavedText: (fileURL == nil || isModified) ? text : nil,
            bookmarkData: bookmarkData,
            wordWrap: wordWrap,
            showStatusBar: showStatusBar,
            windowIndex: index,
            fontSize: fontSize,
            csvDelimiter: csvDelimiter.map { String($0) },
            csvIsTableView: csvDelimiter != nil ? csvIsTableView : nil,
            csvSortKeys: csvSortKeys.isEmpty ? nil : csvSortKeys
        )
    }

    // MARK: Find

    func findNext() {
        // EASTER EGG: typing "amatopad" in the find bar and pressing Return/⌘G triggers
        // AmatoPad mode instead of a normal search. To remove: delete this if-block.
        if findText.lowercased() == "amatopad" {
            showFindReplace = false
            AppPreferences.shared.isAmatoPadMode.toggle()
            NotificationCenter.default.post(name: .amatoPadModeChanged, object: nil)
            return
        }
        if csvIsTableView { csvFindMatchIndex += 1; return }
        guard !findText.isEmpty else { return }
        let ns = text as NSString
        var opts: NSString.CompareOptions = []
        if !findCaseSensitive { opts.insert(.caseInsensitive) }
        let start = min(findHighlightRange.map { $0.upperBound } ?? 0, ns.length)
        var r = ns.range(of: findText, options: opts, range: NSRange(location: start, length: ns.length - start))
        if r.location == NSNotFound { r = ns.range(of: findText, options: opts) }
        if r.location != NSNotFound { findHighlightRange = r }
    }

    func findPrevious() {
        if csvIsTableView { csvFindMatchIndex -= 1; return }
        guard !findText.isEmpty else { return }
        let ns = text as NSString
        var opts: NSString.CompareOptions = [.backwards]
        if !findCaseSensitive { opts.insert(.caseInsensitive) }
        let end = min(findHighlightRange?.location ?? ns.length, ns.length)
        var r = ns.range(of: findText, options: opts, range: NSRange(location: 0, length: end))
        if r.location == NSNotFound { r = ns.range(of: findText, options: opts) }
        if r.location != NSNotFound { findHighlightRange = r }
    }

    /// Force any open file into grid view with the given delimiter (Format menu "View As Grid").
    func forceGridView(delimiter: Character) {
        parseCSVInBackground(text, delimiter: delimiter, showTable: true)
    }

    func replaceCurrent() {
        guard !findText.isEmpty, let range = findHighlightRange,
              range.upperBound <= (text as NSString).length,
              let swiftRange = Range(range, in: text) else { findNext(); return }
        let current = String(text[swiftRange])
        let matches = findCaseSensitive ? current == findText : current.lowercased() == findText.lowercased()
        guard matches else { findNext(); return }
        text.replaceSubrange(swiftRange, with: replaceText)
        isModified = true
        let newLoc = min(range.location + (replaceText as NSString).length, (text as NSString).length)
        findHighlightRange = NSRange(location: newLoc, length: 0)
        findNext()
    }

    func replaceAll() {
        guard !findText.isEmpty else { return }
        var opts: NSString.CompareOptions = []
        if !findCaseSensitive { opts.insert(.caseInsensitive) }
        let ns = text as NSString
        let result = ns.replacingOccurrences(of: findText, with: replaceText, options: opts,
                                              range: NSRange(location: 0, length: ns.length))
        if result != text { text = result; isModified = true }
        findHighlightRange = nil
    }

    // MARK: Pretty Print / Restore Original (toggle)

    func prettyPrintDocument() {
        if isPrettyPrinted {
            // Restoring replaces the buffer with the raw file text. Confirm first —
            // this used to discard unsaved edits AND clear isModified, so the work
            // was gone with nothing left to warn about at quit time.
            if isModified, !confirmDiscard() { return }
            // Restore original file text
            let restoreTo = originalText ?? text
            let old = text
            NSApp.keyWindow?.undoManager?.registerUndo(withTarget: self) { doc in
                doc.text = old; doc.isModified = true; doc.isPrettyPrinted = true
            }
            text = restoreTo
            isModified = false   // back to what's on disk
            isPrettyPrinted = false
        } else {
            // Pretty print — save original first if not already stored
            guard let formatted = prettyPrint(text: text, language: language) else {
                presentError("Could not format — the content may not be valid \(language).")
                return
            }
            if originalText == nil { originalText = text }
            let old = text
            NSApp.keyWindow?.undoManager?.registerUndo(withTarget: self) { doc in
                doc.text = old; doc.isModified = false; doc.isPrettyPrinted = false
            }
            text = formatted
            isModified = true
            isPrettyPrinted = true
        }
    }

    // MARK: File Operations

    func newDocument() {
        guard !isModified || confirmDiscard() else { return }
        text = ""
        fileURL = nil
        bookmarkData = nil
        isModified = false
        language = .plain
        isPrettyPrinted = false
        originalText = nil
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .text, .xml, .html, .json,
                                     UTType(filenameExtension: "md")  ?? .plainText,
                                     UTType(filenameExtension: "csv") ?? .plainText,
                                     UTType(filenameExtension: "tsv") ?? .plainText,
                                     UTType(filenameExtension: "tab") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Use closure to avoid keyWindow timing issues after panel dismissal
        requestOpenFile?(url)
    }

    func saveDocument() {
        if let url = fileURL { writeFile(to: url) } else { saveAsDocument() }
    }

    func saveAsDocument() {
        let panel = NSSavePanel()
        // Offer the document's own type. Hardcoding .plainText made the panel
        // rewrite "data.csv" to "data.csv.txt", which also dropped grid view.
        if let ext = fileURL?.pathExtension, !ext.isEmpty,
           let type = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [type]
        } else {
            panel.allowedContentTypes = [.plainText]
        }
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        writeFile(to: url)
    }

    func loadFile(from url: URL) {
        do {
            let raw  = try String(contentsOf: url, encoding: .utf8)
            let lang = Language.detect(from: url)

            // CSV/TSV: parse on background thread so large files don't block UI
            if lang.isTabular, let delim = lang.tabularDelimiter {
                parseCSVInBackground(raw, delimiter: delim, showTable: true)
            } else {
                csvDelimiter = nil; csvRows = []; csvIsTableView = false; csvIsLoading = false
            }

            // Pretty-print for JSON/XML/HTML
            if lang.canPrettyPrint, let formatted = prettyPrint(text: raw, language: lang) {
                originalText = raw; text = formatted; isPrettyPrinted = true
            } else {
                originalText = nil; text = raw; isPrettyPrinted = false
            }

            fileURL      = url
            bookmarkData = SessionManager.shared.makeBookmark(for: url)
            isModified   = false
            language     = lang
            csvFindMatchIndex = 0
            RecentFilesManager.shared.add(url)
        } catch {
            presentError("Could not open \"\(url.lastPathComponent)\".\n\(error.localizedDescription)")
        }
    }

    private func writeFile(to url: URL) {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            fileURL = url
            bookmarkData = SessionManager.shared.makeBookmark(for: url)
            isModified = false
            language = Language.detect(from: url)
            isPrettyPrinted = false
            RecentFilesManager.shared.add(url)
        } catch {
            presentError("Could not save \"\(url.lastPathComponent)\".\n\(error.localizedDescription)")
        }
    }

    private func confirmDiscard() -> Bool {
        let alert = NSAlert.make()
        alert.messageText = "Discard changes to \"\(displayName)\"?"
        alert.informativeText = "Your unsaved changes will be lost."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentError(_ message: String) {
        let alert = NSAlert.make()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
}

// MARK: - Session Registry

final class DocumentRegistry {
    static let shared = DocumentRegistry()
    private init() {}
    private var documents: [ObjectIdentifier: NotepadDocument] = [:]
    private var nextOrder = 0

    func register(_ doc: NotepadDocument) {
        // Stamp a stable creation order. allStates() used to take its ordering from
        // Dictionary iteration, which is unspecified and reseeded every process —
        // so restored tabs came back in a different order on each launch.
        doc.windowIndex = nextOrder
        nextOrder += 1
        documents[ObjectIdentifier(doc)] = doc
    }

    func unregister(_ doc: NotepadDocument) {
        documents.removeValue(forKey: ObjectIdentifier(doc))
    }

    func allStates() -> [DocumentSessionState] {
        documents.values
            .sorted { $0.windowIndex < $1.windowIndex }
            .enumerated()
            .map { idx, doc in doc.sessionState(index: idx) }
    }

    func allDocuments() -> [NotepadDocument] { Array(documents.values) }
}


// MARK: - Main View

struct ContentView: View {
    @State private var document = NotepadDocument()
    @State private var myWindow: NSWindow? = nil
    @Environment(\.openWindow) private var openWindow

    private var windowTitle: String {
        document.isModified ? "\(document.displayName) — Edited" : document.displayName
    }

    var body: some View {
        VStack(spacing: 0) {
            if document.csvIsLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Parsing…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.textBackgroundColor))
            } else if document.csvIsTableView && !document.csvRows.isEmpty {
                CSVTableView(document: document)
            } else {
                NotepadEditorView(document: document)
            }
            if document.showFindReplace {
                Divider()
                FindReplaceBar(document: document)
            }
            if document.showStatusBar {
                Divider()
                StatusBarView(document: document)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        // EASTER EGG: red accent color on window chrome (toolbar, status bar, menus) when
        // AmatoPad mode is active. AppKit document views (NSTextView, NSTableView) are
        // unaffected since they don't inherit SwiftUI accent color.
        // To remove: delete this modifier and the AppPreferences.isAmatoPadMode property.
        .accentColor(AppPreferences.shared.isAmatoPadMode ? .red : nil)
        .navigationTitle(windowTitle)
        .focusedValue(\.notepadDocument, document)
        .sheet(isPresented: $document.showWordCount) {
            WordCountView(text: document.text)
        }
        .background(WindowAccessor { myWindow = $0 })
        .toolbar {
            // ── Writing Tools ────────────────────────────────────────────────
            ToolbarItem(placement: .automatic) {
                ToolbarButtonGroup {
                    ToolbarGroupButton(icon: "sparkles", help: "Writing Tools") {
                        NSApp.sendAction(Selector(("showWritingTools:")), to: nil, from: nil)
                    }
                }
            }

            // ── Edit actions ─────────────────────────────────────────────────
            ToolbarItem(placement: .automatic) {
                ToolbarButtonGroup {
                    ToolbarGroupButton(icon: "cursorarrow.and.square.on.square.dashed", help: "Select All") {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                    ToolbarGroupButton(icon: "scissors", help: "Cut") {
                        NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
                    }
                    ToolbarGroupButton(icon: "doc.on.doc", help: "Copy") {
                        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                    }
                    ToolbarGroupButton(icon: "clipboard", help: "Paste") {
                        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                    }
                    ToolbarGroupButton(icon: "magnifyingglass", help: "Find & Replace") {
                        document.showFindReplace.toggle()
                        if !document.showFindReplace { document.findHighlightRange = nil }
                    }
                }
            }

            // ── Window / tab management + close tab ──────────────────────────
            ToolbarItem(placement: .primaryAction) {
                ToolbarButtonGroup {
                    ToolbarGroupButton(icon: "doc.badge.plus", help: "New Tab") {
                        openNewTab()
                    }
                    ToolbarGroupButton(icon: "rectangle.badge.plus", help: "New Window") {
                        NotificationCenter.default.post(name: .openNotepadWindow, object: nil)
                    }
                    ToolbarGroupButton(icon: "square.grid.2x2", help: "Show All Tabs") {
                        NSApp.sendAction(Selector(("toggleTabOverview:")), to: nil, from: nil)
                    }
                    ToolbarGroupButton(icon: "xmark.rectangle", help: "Close Tab") {
                        closeCurrentTab()
                    }
                    .foregroundStyle(.red.opacity(0.8))
                }
            }
        }
        .onAppear {
            DocumentRegistry.shared.register(document)
            document.requestOpenFile = { url in
                handleFileOpen(url: url)
            }
        }
        .onDisappear {
            if !AppState.shared.isTerminating {
                // Only save to closed-tabs buffer if the tab wasn't explicitly dismissed by the user
                if !AppState.shared.isClearingSession
                    && !document.isBeingExplicitlyClosed
                    && (!document.text.isEmpty || document.fileURL != nil) {
                    SessionManager.shared.pushClosed(document.sessionState(index: 0))
                }
                DocumentRegistry.shared.unregister(document)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openNotepadWindow)) { _ in
            guard NSApp.keyWindow == myWindow else { return }
            openNewWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSessionTab)) { note in
            // Claimed by token rather than by window identity, for the same reason
            // .openFile is: at launch NSApp.keyWindow is routinely some window other
            // than any ContentView's, so the old guard dropped every restored tab and
            // the session came back one window instead of N.
            if let token = note.userInfo?["token"] as? UUID {
                guard SessionTabClaims.shared.claim(token) else { return }
            } else {
                guard NSApp.keyWindow == myWindow else { return }
            }
            openNewTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearSession)) { _ in
            guard NSApp.keyWindow == myWindow else { return }
            // Close all other content windows
            for win in NSApp.windows where win != myWindow && win.contentView != nil {
                win.close()
            }
            // Reset this window to blank
            document.reset()
            AppState.shared.isClearingSession = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .openFile)) { note in
            // Finder / `open` / double-click opens, via application(_:open:).
            // Claiming by token rather than by window identity: NSApp.keyWindow
            // frequently matches none of the ContentViews' own windows (and at
            // launch there may be no key window at all), which silently dropped
            // the file and made opening a document from Finder do nothing.
            guard let url = note.userInfo?["url"] as? URL else { return }
            if let token = note.userInfo?["token"] as? UUID {
                guard PendingURLManager.shared.claim(token) else { return }
            } else {
                guard NSApp.keyWindow == myWindow else { return }
            }
            handleFileOpen(url: url)
        }
    }

    private func handleFileOpen(url: URL) {
        if document.text.isEmpty && !document.isModified && document.fileURL == nil {
            document.loadFile(from: url)
        } else {
            PendingURLManager.shared.pendingURL = url
            openNewTab()
        }
    }

    private func openNewTab() {
        let existingIDs = Set(NSApp.windows.map { ObjectIdentifier($0) })
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let newWin = notification.object as? NSWindow,
                  !existingIDs.contains(ObjectIdentifier(newWin)) else { return }
            if let obs = observer { NotificationCenter.default.removeObserver(obs) }
            observer = nil
            myWindow?.addTabbedWindow(newWin, ordered: .above)
            newWin.makeKeyAndOrderFront(nil)
        }
        openWindow(id: "notepad")
    }

    private func openNewWindow() {
        NSWindow.allowsAutomaticWindowTabbing = false
        openWindow(id: "notepad")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSWindow.allowsAutomaticWindowTabbing = true
        }
    }

    private func closeCurrentTab() {
        let alert = NSAlert.make()
        alert.messageText = "Close \"\(document.displayName)\"?"
        alert.informativeText = document.isModified
            ? "You have unsaved changes. They will be lost."
            : "This tab will be removed from your session permanently."
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = document.isModified ? .warning : .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let tabCount = myWindow?.tabbedWindows?.count ?? 1
        if tabCount <= 1 {
            // Last (or only) tab — reset to a fresh blank rather than closing the window.
            // Resetting means nothing gets pushed to the closed-tabs buffer; the now-blank
            // document is effectively a clean new tab from the user's perspective.
            document.reset()
        } else {
            // Multiple tabs open — close this one; the rest stay visible.
            document.isBeingExplicitlyClosed = true
            myWindow?.close()
        }
    }

}

// MARK: - Toolbar Button Group
//
// Liquid-Glass pill style matching macOS 26 (Tahoe):
// large corner radius, translucent material fill, gradient highlight border.

struct ToolbarButtonGroup<Content: View>: View {
    @ViewBuilder let content: Content

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        HStack(spacing: 2) {
            content
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: shape)
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.45), .white.opacity(0.1)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.75
            )
        )
    }
}

// Consistent icon button for use inside ToolbarButtonGroup
struct ToolbarGroupButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .imageScale(.large)
                .frame(width: 30, height: 24)
        }
        .help(help)
    }
}

// MARK: - Window Accessor

private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        attach(to: view, attempt: 0)
        return view
    }

    /// Retries until the view is in a window. A single 0.05s attempt left some
    /// windows permanently without a reference, which disabled every notification
    /// guarded on window identity (new tab, new window, clear session) for them.
    private func attach(to view: NSView, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let window = view.window else {
                if attempt < 40 { attach(to: view, attempt: attempt + 1) }
                return
            }
            window.tabbingMode = .preferred
            window.tabbingIdentifier = "NotepadMain"
            onWindow(window)
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Find & Replace Bar

struct FindReplaceBar: View {
    @Bindable var document: NotepadDocument
    @FocusState private var focus: FocusField?
    enum FocusField { case find, replace }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text("Find:")
                    .frame(width: 56, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField("", text: $document.findText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .find)
                    .onSubmit { document.findNext() }
                charButton("↵") { document.findText += "\n" }
                charButton("⇥") { document.findText += "\t" }
                Button { document.findPrevious() } label: { Image(systemName: "chevron.up") }
                    .help("Find Previous")
                Button { document.findNext() } label: { Image(systemName: "chevron.down") }
                    .help("Find Next")
            }
            HStack(spacing: 6) {
                Text("Replace:")
                    .frame(width: 56, alignment: .trailing)
                    .foregroundStyle(.secondary)
                TextField("", text: $document.replaceText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .replace)
                charButton("↵") { document.replaceText += "\n" }
                charButton("⇥") { document.replaceText += "\t" }
                Button("Replace") { document.replaceCurrent() }
                Button("All") { document.replaceAll() }
                    .help("Replace All")
                Toggle("Case", isOn: $document.findCaseSensitive)
                    .help("Case Sensitive")
                Spacer()
                Button {
                    document.showFindReplace = false
                    document.findHighlightRange = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear { focus = .find }
        .onKeyPress(.escape) {
            document.showFindReplace = false
            document.findHighlightRange = nil
            return .handled
        }
    }

    @ViewBuilder
    private func charButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .font(.system(size: 12, design: .monospaced))
            .buttonStyle(.bordered)
            .help(label == "↵" ? "Insert Return" : "Insert Tab")
    }
}

// MARK: - Status Bar

struct StatusBarView: View {
    let document: NotepadDocument

    private var text: String { document.text }
    private var language: Language { document.language }

    /// Every computed property here re-runs on each render — i.e. on every
    /// keystroke. Past this size the full-document JSON parse is skipped.
    private static let liveValidationLimit = 1_000_000   // bytes

    // Counted in a single non-allocating pass; components(separatedBy:) built a
    // throwaway array of every word in the document on each keystroke.
    private var words: Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                inWord = false
            } else if !inWord {
                inWord = true; count += 1
            }
        }
        return count
    }
    private var characters: Int { text.count }
    private var lines: Int {
        text.isEmpty ? 1 : text.unicodeScalars.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    private var jsonStatus: String? {
        guard language == .json, !text.isEmpty else { return nil }
        // Re-parsing a multi-megabyte document on every keystroke made typing crawl.
        guard text.utf8.count <= Self.liveValidationLimit else { return nil }
        guard let data = text.data(using: .utf8) else { return "JSON Error: invalid encoding" }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
            return "Valid JSON"
        } catch {
            return "JSON Error: \(error.localizedDescription)"
        }
    }

    private var formatColor: Color {
        switch language {
        case .json:       .blue
        case .xml, .html: .orange
        case .csv, .tsv:  .teal
        default:          .secondary
        }
    }

    private var languageBadge: String {
        switch language {
        case .json:     "JSON"
        case .xml:      "XML"
        case .html:     "HTML"
        case .markdown: "MD"
        case .csv:      "CSV"
        case .tsv:      "TSV"
        default:        ""
        }
    }

    private var zoomPercent: Int {
        Int((document.fontSize / 13.0 * 100).rounded())
    }

    private var inTableView: Bool { document.csvIsTableView && !document.csvRows.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            if inTableView {
                // ── Table mode: row / column counts ───────────────────────
                pill("Rows: \(max(0, document.csvRows.count - 1))")
                Divider().frame(height: 12)
                pill("Columns: \(document.csvRows.first?.cells.count ?? 0)")
                if !document.csvSortKeys.isEmpty {
                    Divider().frame(height: 12)
                    Button(action: { document.csvSortKeys = [] }) {
                        Text("Sorted")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)
                    .help("Clear all sorting")
                }
            } else {
                // ── Text mode: word / char / line counts ──────────────────
                pill("Words: \(words)")
                Divider().frame(height: 12)
                pill("Characters: \(characters)")
                Divider().frame(height: 12)
                pill("Lines: \(lines)")
                if let status = jsonStatus {
                    Divider().frame(height: 12)
                    pill(status)
                        .foregroundStyle(status.hasPrefix("Valid") ? Color.green : Color.red)
                }
                if language != .plain {
                    Divider().frame(height: 12)
                    Text(languageBadge).foregroundStyle(formatColor).padding(.horizontal, 8)
                }
            }

            Spacer()

            // EASTER EGG: persistent "AmatoPad" badge in the status bar.
            // To remove: delete this entire if-block.
            if AppPreferences.shared.isAmatoPadMode {
                Divider().frame(height: 12)
                Text("AmatoPad")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.purple, .pink],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .padding(.horizontal, 8)
            }

            // ── Word Wrap toggle (text mode only) ─────────────────────────
            if !inTableView {
                Divider().frame(height: 12)
                statusToggleButton(
                    icon: "text.alignleft",
                    label: "Word Wrap",
                    active: document.wordWrap,
                    color: .blue,
                    inactiveColor: Color(NSColor.tertiaryLabelColor)
                ) { document.wordWrap.toggle() }
            }

            // ── Zoom (text mode only) ──────────────────────────────────────
            if !inTableView {
                Divider().frame(height: 12)
                HStack(spacing: 0) {
                    Button { document.fontSize = max(9,  document.fontSize - 1) } label: {
                        Image(systemName: "minus").frame(width: 22)
                    }.buttonStyle(.plain).help("Zoom Out")
                    Button { document.fontSize = 13 } label: {
                        Text("\(zoomPercent)%").monospacedDigit().frame(width: 40, alignment: .center)
                    }.buttonStyle(.plain).help("Reset to 100%")
                    Button { document.fontSize = min(28, document.fontSize + 1) } label: {
                        Image(systemName: "plus").frame(width: 22)
                    }.buttonStyle(.plain).help("Zoom In")
                }
            }

            // ── Pretty Print (text mode, JSON/XML/HTML only) ───────────────
            if language.canPrettyPrint && !inTableView {
                Divider().frame(height: 12)
                statusToggleButton(
                    icon: "curlybraces",
                    label: document.isPrettyPrinted ? "Show Original" : "Pretty Print",
                    active: document.isPrettyPrinted,
                    color: formatColor
                ) { document.prettyPrintDocument() }
            }

            // ── Table-mode controls ────────────────────────────────────────
            if !document.csvRows.isEmpty {
                Divider().frame(height: 12)

                // Row # and Headers toggles sit left of the Raw Text button
                if inTableView {
                    statusToggleButton(
                        icon: "list.number",
                        label: "Row #",
                        active: document.csvShowRowNumbers,
                        color: .indigo,
                        inactiveColor: Color(NSColor.tertiaryLabelColor)
                    ) { document.csvShowRowNumbers.toggle() }

                    statusToggleButton(
                        icon: "tablecells.badge.ellipsis",
                        label: "Headers",
                        active: document.csvShowHeaders,
                        color: .indigo,
                        inactiveColor: Color(NSColor.tertiaryLabelColor)
                    ) { document.csvShowHeaders.toggle() }
                }

                // Raw Text / Table View — always rightmost
                statusToggleButton(
                    icon: inTableView ? "doc.plaintext" : "tablecells",
                    label: inTableView ? "Raw Text" : "Table View",
                    active: inTableView,
                    color: .teal
                ) { document.csvIsTableView.toggle() }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private func statusToggleButton(
        icon: String, label: String, active: Bool, color: Color,
        inactiveColor: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let fg = active ? color : (inactiveColor ?? color)
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                Text(label)
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(active ? color.opacity(0.12) : Color.clear))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
    }

    private func pill(_ label: String) -> some View {
        Text(label).padding(.horizontal, 8)
    }
}

// MARK: - Word Count Sheet

struct WordCountView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    private var stats: [(label: String, value: Int)] {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let chars = text.count
        let charsNoSpaces = text.filter { !$0.isWhitespace }.count
        let lines = text.isEmpty ? 1 : text.components(separatedBy: "\n").count
        let paragraphs = text.components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        return [
            ("Words", words),
            ("Characters", chars),
            ("Characters (no spaces)", charsNoSpaces),
            ("Lines", lines),
            ("Paragraphs", paragraphs),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Word Count").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 8) {
                ForEach(stats, id: \.label) { stat in
                    GridRow {
                        Text(stat.label).foregroundStyle(.secondary)
                        Text("\(stat.value)")
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}

#Preview {
    ContentView()
}
