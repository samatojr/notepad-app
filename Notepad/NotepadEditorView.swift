import SwiftUI
import AppKit

// MARK: - Custom NSTextView with file drag & drop

/// NSTextView subclass that intercepts file-URL drags so dropping a file
/// onto the editor opens it rather than inserting its path as text.
private final class NotepadTextView: NSTextView {
    var onFileDrop: ((URL) -> Void)?
    var onAutoGrid: ((Character) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) { return .copy }
        return super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let url = urls.first {
            onFileDrop?(url)
            return true
        }
        return super.performDragOperation(sender)
    }

    /// Strip all formatting on paste — insert plain text only.
    /// After inserting, checks whether the full document now looks like a
    /// TSV grid (≥5 rows, ≥2 columns, ≥80% consistent column count) and,
    /// if so, fires onAutoGrid so the coordinator can switch to table view.
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        guard let plain = pb.string(forType: .string) else {
            // No plain-text flavour (image, file promise, …) — let AppKit handle it
            // rather than making ⌘V a silent no-op.
            super.paste(sender)
            return
        }

        // Only auto-switch when the paste covers the entire document.
        let totalLen = (string as NSString).length
        let sel = selectedRange()
        let coversAll = sel.length == totalLen || totalLen == 0

        insertText(plain, replacementRange: sel)

        if coversAll, let delim = tsvGridDelimiter(string) {
            onAutoGrid?(delim)
        }
    }

    /// Returns the detected delimiter if `text` looks like a well-formed grid:
    /// ≥5 rows, ≥2 columns, ≥80% of rows share the modal column count.
    private func tsvGridDelimiter(_ text: String) -> Character? {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count >= 5 else { return nil }

        for delim: Character in ["\t", ","] {
            let counts = lines.map { $0.components(separatedBy: String(delim)).count }
            guard let modal = counts.max(), modal >= 2 else { continue }
            let matching = counts.filter { $0 == modal }.count
            if Double(matching) / Double(lines.count) >= 0.8 {
                return delim
            }
        }
        return nil
    }

}

// MARK: - Editor View

struct NotepadEditorView: NSViewRepresentable {
    /// Pass the whole document; the Coordinator uses withObservationTracking
    /// so every model change (text, wordWrap, language, findHighlightRange)
    /// reaches the NSTextView without depending on SwiftUI's render cycle.
    let document: NotepadDocument

    func makeNSView(context: Context) -> NSScrollView {
        // Build scroll view + text view manually so we can use NotepadTextView.
        // This replicates what NSTextView.scrollableTextView() does internally.
        let scrollView = NSScrollView()
        scrollView.borderType          = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers  = true
        scrollView.autoresizingMask    = [.width, .height]

        let textStorage = NSTextStorage()
        let layoutMgr   = NSLayoutManager()
        textStorage.addLayoutManager(layoutMgr)
        let container = NSTextContainer(size: CGSize(width: scrollView.contentSize.width,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutMgr.addTextContainer(container)

        let textView = NotepadTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize),
                                       textContainer: container)
        textView.minSize             = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize             = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable   = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask        = .width
        scrollView.documentView = textView
        scrollView.backgroundColor = .textBackgroundColor

        // Wire file drop handler
        textView.onFileDrop = { [weak coord = context.coordinator] url in
            coord?.document?.loadFile(from: url)
        }
        textView.onAutoGrid = { [weak coord = context.coordinator] delim in
            coord?.document?.forceGridView(delimiter: delim)
        }

        textView.delegate    = context.coordinator
        textView.isRichText  = false
        textView.allowsUndo  = true
        textView.font        = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor   = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled   = false
        textView.isAutomaticDashSubstitutionEnabled    = false
        textView.isAutomaticTextReplacementEnabled     = false
        textView.isAutomaticSpellingCorrectionEnabled  = false
        textView.isContinuousSpellCheckingEnabled      = false
        textView.isGrammarCheckingEnabled              = false
        // Disable macOS 14+ inline prediction (ghost-text completions) which
        // can move the insertion point unexpectedly.
        // Writing Tools (.writingToolsBehavior) is left at system default so
        // the sparkle toolbar button continues to work.
        if #available(macOS 14, *) { textView.inlinePredictionType = .no }
        textView.textContainerInset = NSSize(width: 8, height: 8)

        // Wire up syntax highlighter BEFORE setting text so initial load is highlighted
        let highlighter = context.coordinator.highlighter
        highlighter.language = document.language
        highlighter.inkColor = AppPreferences.shared.paperTheme.inkColor
        highlighter.baseFont = .monospacedSystemFont(ofSize: document.fontSize, weight: .regular)
        textView.textStorage?.delegate = highlighter

        context.coordinator.isUpdatingFromCode = true
        textView.string = document.text
        context.coordinator.isUpdatingFromCode = false
        context.coordinator.lastSyncedText = document.text

        applyWordWrap(document.wordWrap, scrollView: scrollView, textView: textView)
        applyPaperTheme(AppPreferences.shared.paperTheme, scrollView: scrollView, textView: textView)

        // Store refs and kick off the self-renewing observation chain
        context.coordinator.textView   = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.document   = document
        context.coordinator.startObserving()

        return scrollView
    }

    /// All updates are driven by withObservationTracking inside the Coordinator.
    /// updateNSView is effectively a no-op (document reference is stable @State).
    func updateNSView(_ scrollView: NSScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView:   NSTextView?
        weak var scrollView: NSScrollView?
        var document: NotepadDocument?

        var isUpdatingFromCode = false
        /// Tracks the last text that was explicitly pushed from the model into
        /// the text view (or pulled from the text view into the model).  Only
        /// when doc.text diverges from this value do we need to re-set
        /// textView.string — which is what moves the insertion point.
        /// Comparing against a local copy avoids the async-timing race where
        /// textView.string and doc.text appear to differ momentarily after the
        /// SyntaxHighlighter modifies the full attributed-string range.
        var lastSyncedText: String = ""
        let highlighter = SyntaxHighlighter()

        private var lastWordWrap:       Bool?
        private var lastLanguage:       Language?
        private var lastHighlightRange: NSRange?
        private var lastFontSize:       CGFloat?
        private var lastPaperTheme:     PaperTheme?
        private var lastSelectionRequestID: Int?

        /// Self-renewing observation chain: re-subscribes after every change so
        /// any model mutation (text, wordWrap, language, findHighlightRange)
        /// is immediately reflected in the NSTextView.
        func startObserving() {
            withObservationTracking {
                guard let doc = self.document,
                      let textView   = self.textView,
                      let scrollView = self.scrollView else { return }

                // ── Text ─────────────────────────────────────────────────────
                let newText = doc.text
                if !self.isUpdatingFromCode && newText != self.lastSyncedText {
                    // doc.text was changed by external code (load file, find/replace,
                    // pretty-print, etc.) — push the new content into the text view
                    // and restore the insertion point to the nearest valid position.
                    self.lastSyncedText = newText
                    let saved = textView.selectedRanges
                    self.isUpdatingFromCode = true
                    textView.string = newText
                    self.isUpdatingFromCode = false
                    let len  = (newText as NSString).length
                    let safe = saved.filter { $0.rangeValue.upperBound <= len }
                    textView.selectedRanges = safe.isEmpty
                        ? [NSValue(range: NSRange(location: 0, length: 0))]
                        : safe
                }

                // ── Font size (zoom) ──────────────────────────────────────────
                let newFontSize = doc.fontSize
                if self.lastFontSize != newFontSize {
                    let font = NSFont.monospacedSystemFont(ofSize: newFontSize, weight: .regular)
                    textView.font = font
                    self.highlighter.baseFont = font
                    self.lastFontSize = newFontSize
                    // Setting textView.font rewrites the whole storage, wiping the
                    // highlighter's bold runs — re-run it so markdown bold survives
                    // zooming and matches the new size.
                    if let ts = textView.textStorage, ts.length > 0 {
                        ts.edited(.editedCharacters,
                                  range: NSRange(location: 0, length: ts.length),
                                  changeInLength: 0)
                    }
                }

                // ── Word wrap ─────────────────────────────────────────────────
                if self.lastWordWrap != doc.wordWrap {
                    applyWordWrap(doc.wordWrap, scrollView: scrollView, textView: textView)
                    self.lastWordWrap = doc.wordWrap
                }

                // ── Language / syntax highlighting ────────────────────────────
                // For files that support pretty print (JSON/HTML/XML), only apply
                // syntax highlighting when the content is actually pretty-printed.
                // The original file view shows as plain text.
                let effectiveLang: Language = doc.language.canPrettyPrint
                    ? (doc.isPrettyPrinted ? doc.language : .plain)
                    : doc.language
                if self.lastLanguage != effectiveLang {
                    self.highlighter.language = effectiveLang
                    self.lastLanguage = effectiveLang
                    if let ts = textView.textStorage, ts.length > 0 {
                        ts.edited(.editedCharacters,
                                  range: NSRange(location: 0, length: ts.length),
                                  changeInLength: 0)
                    }
                }

                // ── Paper theme ───────────────────────────────────────────────
                // Reading AppPreferences.shared.paperTheme registers it in the
                // observation graph so onChange fires whenever the user changes
                // the theme from the Format menu.
                let theme = AppPreferences.shared.paperTheme
                // Always keep the highlighter's ink color in sync so that plain
                // text and non-token regions render with the correct foreground.
                self.highlighter.inkColor = theme.inkColor
                if self.lastPaperTheme != theme {
                    applyPaperTheme(theme, scrollView: scrollView, textView: textView)
                    self.lastPaperTheme = theme
                }

                // ── Go to Line / explicit selection request ───────────────────
                // Carries its own id so asking for the same line twice scrolls
                // twice; comparing ranges alone would swallow the second ask.
                if let request = doc.selectionRequest,
                   request.id != self.lastSelectionRequestID {
                    self.lastSelectionRequestID = request.id
                    let len = (doc.text as NSString).length
                    if request.range.upperBound <= len {
                        textView.setSelectedRange(request.range)
                        textView.scrollRangeToVisible(request.range)
                        textView.window?.makeFirstResponder(textView)
                    }
                }

                // ── Find highlight ────────────────────────────────────────────
                let newRange = doc.findHighlightRange
                if newRange != self.lastHighlightRange {
                    self.lastHighlightRange = newRange
                    if let range = newRange {
                        let len = (doc.text as NSString).length
                        if range.upperBound <= len {
                            textView.setSelectedRange(range)
                            textView.scrollRangeToVisible(range)
                        }
                    }
                }

            } onChange: { [weak self] in
                DispatchQueue.main.async { self?.startObserving() }
            }
        }

        // User typed → push back to model
        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromCode,
                  let tv = notification.object as? NSTextView else { return }
            // Always sync lastSyncedText first so startObserving() sees the
            // texts as equal and skips the textView.string = newText reset
            // (which is what moves the insertion point to the wrong position).
            lastSyncedText = tv.string
            if document?.text != tv.string {
                document?.text = tv.string
                document?.markModified()
            }
        }
    }
}

// MARK: - Word Wrap Helper

private func applyWordWrap(_ wrap: Bool, scrollView: NSScrollView, textView: NSTextView) {
    guard let container = textView.textContainer else { return }
    if wrap {
        // ── Step 1: stop horizontal growth so the frame resize in step 2 sticks ──
        textView.isHorizontallyResizable = false

        // ── Step 2: snap the text view frame to the scroll view's content width ──
        // BEFORE enabling widthTracksTextView — if we don't, the container inherits
        // the current (potentially huge) no-wrap frame and the text never re-wraps.
        let wrapWidth = scrollView.contentSize.width
        var f = textView.frame; f.size.width = wrapWidth; textView.frame = f

        // ── Step 3: now the container can safely track the (narrow) text view ────
        container.widthTracksTextView = true
        container.containerSize       = NSSize(width: wrapWidth,
                                               height: .greatestFiniteMagnitude)
        textView.autoresizingMask        = .width   // keep tracking on window resize
        scrollView.hasHorizontalScroller = false
    } else {
        let huge: CGFloat = 10_000_000
        container.widthTracksTextView    = false
        container.containerSize          = NSSize(width: huge, height: .greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.autoresizingMask        = .height  // don't re-snap width on resize
        textView.maxSize                 = NSSize(width: huge, height: .greatestFiniteMagnitude)
        scrollView.hasHorizontalScroller = true
        textView.sizeToFit()             // frame → content width so scrolling works immediately
    }
}

// MARK: - Paper Theme Helper

/// Applies the chosen paper theme to the scroll view + text view pair.
/// Setting view.appearance forces all system-adaptive colors inside that
/// subtree (syntax highlight colors, selection highlight, etc.) to resolve
/// in the correct light/dark context — giving proper "dark paper" behavior
/// even when the macOS system appearance is light, and vice versa.
private func applyPaperTheme(_ theme: PaperTheme,
                              scrollView: NSScrollView,
                              textView: NSTextView) {
    // Frame (window chrome / toolbar) is NOT touched here — it continues
    // to inherit from the system, keeping the "frame vs paper" separation.
    scrollView.appearance = theme.nsAppearance
    textView.appearance   = theme.nsAppearance

    scrollView.backgroundColor  = theme.paperColor
    textView.backgroundColor    = theme.paperColor
    textView.textColor          = theme.inkColor

    // Insertion point matches the text color
    textView.insertionPointColor = theme.inkColor
}
