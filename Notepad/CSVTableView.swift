import SwiftUI
import AppKit

// MARK: - Editable cell field

final class CSVEditableField: NSTextField {
    var onCommit: ((String) -> Void)?

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onCommit?(stringValue)
    }
}

// MARK: - NSTableView subclass for ⌘C copy, ⌘V paste, right-click menu

final class CopyableTableView: NSTableView {
    var copyHandler:   (() -> Void)?
    var pasteHandler:  (() -> Void)?
    var deleteHandler: (() -> Void)?

    /// Tracks the last data column index the user clicked — used as the paste anchor column.
    private(set) var lastClickedDataColumn: Int = 0

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { super.keyDown(with: event); return }
        switch event.charactersIgnoringModifiers {
        case "c": copyHandler?()
        case "v": pasteHandler?()
        default:  super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?)  { copyHandler?() }
    @objc func paste(_ sender: Any?) { pasteHandler?() }

    /// Track which data column was clicked so paste knows where to anchor.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let col = clickedColumn
        guard col >= 0, col < tableColumns.count else { return }
        let id = tableColumns[col].identifier.rawValue
        guard id != "col_rownum",
              let last = id.split(separator: "_").last,
              let idx  = Int(last) else { return }
        lastClickedDataColumn = idx
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row   = self.row(at: point)
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        guard !selectedRowIndexes.isEmpty else { return nil }

        let menu  = NSMenu()
        let count = selectedRowIndexes.count
        let label = count == 1 ? "Delete Row" : "Delete \(count) Rows"
        let item  = NSMenuItem(title: label, action: #selector(deleteRows(_:)),
                               keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func deleteRows(_ sender: Any?) { deleteHandler?() }
}

// MARK: - Find match coordinate

struct CSVMatch: Equatable {
    let row: Int   // 0-indexed display row (into displayOrder)
    let col: Int
}

// MARK: - CSVTableView

struct CSVTableView: NSViewRepresentable {
    let document: NotepadDocument

    func makeNSView(context: Context) -> NSScrollView {
        let coord = context.coordinator
        coord.document = document

        let dataTable = CopyableTableView()
        dataTable.style                              = .inset
        dataTable.usesAlternatingRowBackgroundColors = true
        dataTable.allowsMultipleSelection            = true
        dataTable.allowsColumnSelection              = false
        dataTable.allowsColumnReordering             = false
        dataTable.delegate                           = coord
        dataTable.dataSource                         = coord
        dataTable.columnAutoresizingStyle            = .noColumnAutoresizing
        dataTable.copyHandler   = { [weak coord] in coord?.copySelectedRows() }
        dataTable.pasteHandler  = { [weak coord] in coord?.pasteFromClipboard() }
        dataTable.deleteHandler = { [weak coord] in coord?.deleteSelectedRows() }

        let scrollView = NSScrollView()
        scrollView.documentView          = dataTable
        scrollView.borderType            = .noBorder
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers    = true

        coord.tableView  = dataTable
        coord.dataScroll = scrollView
        coord.rebuildColumns()
        coord.applyPaperTheme(AppPreferences.shared.paperTheme)
        coord.startObserving()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var tableView:  CopyableTableView?
        weak var dataScroll: NSScrollView?
        var document: NotepadDocument?

        // Display order: indices into doc.csvRows for each table row
        private var displayOrder: [Int] = []

        // Find state
        private var findMatches:       [CSVMatch] = []
        private var currentMatchIndex: Int        = -1
        private var lastFindText:      String     = ""
        private var lastCaseSensitive: Bool       = false

        // Change tracking
        private var lastPaperTheme:     PaperTheme?
        private var lastShowRowNumbers: Bool = false
        private var lastShowHeaders:    Bool = true
        private var lastSortKeys:       [CSVSortKey] = []

        // MARK: Helpers

        /// Excel-style column label: 0→A, 25→Z, 26→AA, …
        private func columnLetter(_ index: Int) -> String {
            var result = ""
            var n = index
            repeat {
                result = String(UnicodeScalar(65 + n % 26)!) + result
                n = n / 26 - 1
            } while n >= 0
            return result
        }

        // MARK: Display order (sort)

        func rebuildDisplayOrder(in doc: NotepadDocument) {
            let offset = doc.csvShowHeaders ? 1 : 0
            let total  = doc.csvRows.count
            guard total > offset else { displayOrder = []; return }

            var order = Array(offset..<total)

            let keys = doc.csvSortKeys
            guard !keys.isEmpty else { displayOrder = order; return }

            order.sort { a, b in
                for key in keys {
                    let va = key.column < doc.csvRows[a].cells.count ? doc.csvRows[a].cells[key.column] : ""
                    let vb = key.column < doc.csvRows[b].cells.count ? doc.csvRows[b].cells[key.column] : ""
                    if va == vb { continue }
                    if let na = Double(va), let nb = Double(vb) {
                        return key.ascending ? na < nb : na > nb
                    }
                    let cmp = va.localizedCompare(vb)
                    return key.ascending ? cmp == .orderedAscending : cmp == .orderedDescending
                }
                return false
            }

            displayOrder = order
        }

        private func applySortIndicators() {
            guard let dt = tableView, let doc = document else { return }
            for col in dt.tableColumns { dt.setIndicatorImage(nil, in: col) }
            dt.highlightedTableColumn = nil

            for (i, key) in doc.csvSortKeys.enumerated() {
                let colID = NSUserInterfaceItemIdentifier("col_\(key.column)")
                guard let col = dt.tableColumns.first(where: { $0.identifier == colID }) else { continue }
                let img = key.ascending
                    ? NSImage(named: "NSAscendingSortIndicator")
                    : NSImage(named: "NSDescendingSortIndicator")
                dt.setIndicatorImage(img, in: col)
                if i == 0 { dt.highlightedTableColumn = col }
            }
        }

        // MARK: Column setup

        func rebuildColumns() {
            guard let dt = tableView, let doc = document else { return }
            for col in dt.tableColumns { dt.removeTableColumn(col) }
            guard !doc.csvRows.isEmpty else { dt.reloadData(); return }

            let showHeaders = doc.csvShowHeaders
            let offset      = showHeaders ? 1 : 0
            let dataCount   = max(0, doc.csvRows.count - offset)

            // ── Optional row-number column ───────────────────────────────────
            if doc.csvShowRowNumbers {
                let digits = dataCount > 0 ? Int(log10(Double(dataCount))) + 1 : 1
                let numCol = NSTableColumn(identifier: .init("col_rownum"))
                numCol.title                  = "#"
                numCol.isEditable             = false
                numCol.minWidth               = 30
                numCol.width                  = max(30, CGFloat(digits) * 7.0 + 16)
                numCol.headerCell.alignment   = .center
                dt.addTableColumn(numCol)
            }

            // ── Column titles & widths ───────────────────────────────────────
            let titleRow: [String] = showHeaders ? (doc.csvRows.first?.cells ?? []) : []
            let colCount: Int = showHeaders
                ? (doc.csvRows.first?.cells.count ?? 0)
                : (doc.csvRows.map(\.cells.count).max() ?? 0)

            let allData       = showHeaders ? doc.csvRows.dropFirst() : doc.csvRows[...]
            let sample        = Array(allData.prefix(200))
            let firstRowCells = doc.csvRows.first?.cells ?? []

            for i in 0..<colCount {
                let title: String = showHeaders
                    ? { let t = titleRow[i]; return t.isEmpty ? "Column \(i+1)" : t }()
                    : columnLetter(i)

                let col = NSTableColumn(identifier: .init("col_\(i)"))
                col.title      = title
                col.isEditable = true
                if !showHeaders { col.headerCell.alignment = .center }

                let avgChars: CGFloat = sample.isEmpty ? 0 : {
                    let total = sample.reduce(0) { $0 + (i < $1.cells.count ? $1.cells[i].count : 0) }
                    return CGFloat(total) / CGFloat(sample.count)
                }()
                let firstRowChars = i < firstRowCells.count ? CGFloat(firstRowCells[i].count) : 0
                let chars = max(CGFloat(title.count), avgChars, firstRowChars)
                col.minWidth = 30
                col.width    = min(300, max(30, chars * 8.0 + 8))
                dt.addTableColumn(col)
            }

            rebuildDisplayOrder(in: doc)
            applySortIndicators()
            dt.reloadData()
        }

        // MARK: Commit cell edit

        func commitEdit(tableRow: Int, colIdx: Int, value: String) {
            guard let doc   = document,
                  let delim = doc.csvDelimiter,
                  displayOrder.indices.contains(tableRow) else { return }

            let csvIdx = displayOrder[tableRow]
            guard csvIdx < doc.csvRows.count,
                  colIdx < doc.csvRows[csvIdx].cells.count,
                  doc.csvRows[csvIdx].cells[colIdx] != value else { return }

            doc.csvRows[csvIdx].cells[colIdx] = value
            doc.text       = serializeDelimited(doc.csvRows, delimiter: delim)
            doc.isModified = true
        }

        // MARK: Delete selected rows

        func deleteSelectedRows() {
            guard let dt    = tableView,
                  let doc   = document,
                  let delim = doc.csvDelimiter else { return }

            let selected = dt.selectedRowIndexes
            guard !selected.isEmpty else { return }

            let csvIndices = selected.compactMap {
                displayOrder.indices.contains($0) ? displayOrder[$0] : nil
            }
            doc.csvRows.remove(atOffsets: IndexSet(csvIndices))
            doc.text       = serializeDelimited(doc.csvRows, delimiter: delim)
            doc.isModified = true

            rebuildDisplayOrder(in: doc)
            dt.reloadData()
        }

        // MARK: Column header click → sort

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let doc = document,
                  tableColumn.identifier.rawValue != "col_rownum",
                  let colIdxStr = tableColumn.identifier.rawValue.split(separator: "_").last,
                  let colIdx    = Int(colIdxStr) else { return }

            if let idx = doc.csvSortKeys.firstIndex(where: { $0.column == colIdx }) {
                if doc.csvSortKeys[idx].ascending {
                    doc.csvSortKeys[idx].ascending = false
                } else {
                    doc.csvSortKeys.remove(at: idx)
                }
            } else {
                doc.csvSortKeys.append(CSVSortKey(column: colIdx, ascending: true))
            }

            rebuildDisplayOrder(in: doc)
            applySortIndicators()
            tableView.reloadData()
        }

        // MARK: Observation

        func startObserving() {
            withObservationTracking {
                guard let doc = document, let dt = tableView else { return }

                let findText      = doc.findText
                let caseSensitive = doc.findCaseSensitive
                let matchSignal   = doc.csvFindMatchIndex
                let inTableView   = doc.csvIsTableView

                if inTableView && !findText.isEmpty {
                    if findText != lastFindText || caseSensitive != lastCaseSensitive {
                        lastFindText      = findText
                        lastCaseSensitive = caseSensitive
                        rebuildFindMatches(findText: findText, caseSensitive: caseSensitive)
                        currentMatchIndex = findMatches.isEmpty ? -1 : 0
                    } else if !findMatches.isEmpty {
                        let count         = findMatches.count
                        currentMatchIndex = ((matchSignal % count) + count) % count
                    }
                } else {
                    if findText != lastFindText {
                        lastFindText      = findText
                        findMatches       = []
                        currentMatchIndex = -1
                    }
                }

                // Scroll to current match
                if currentMatchIndex >= 0, currentMatchIndex < findMatches.count {
                    let m = findMatches[currentMatchIndex]
                    dt.scrollRowToVisible(m.row)
                    if let colIdx = dt.tableColumns.firstIndex(where: {
                        $0.identifier.rawValue == "col_\(m.col)"
                    }) { dt.scrollColumnToVisible(colIdx) }
                }

                // ── Row numbers or Headers toggled → rebuild columns ───────────
                let showRowNums = doc.csvShowRowNumbers
                let showHeaders = doc.csvShowHeaders
                if showRowNums != lastShowRowNumbers || showHeaders != lastShowHeaders {
                    lastShowRowNumbers = showRowNums
                    lastShowHeaders    = showHeaders
                    rebuildColumns()
                    return
                }

                // ── Sort changed → rebuild display order ──────────────────────
                let sortKeys = doc.csvSortKeys
                if sortKeys != lastSortKeys {
                    lastSortKeys = sortKeys
                    rebuildDisplayOrder(in: doc)
                    applySortIndicators()
                }

                // ── Paper theme ───────────────────────────────────────────────
                let theme = AppPreferences.shared.paperTheme
                if theme != lastPaperTheme {
                    applyPaperTheme(theme)
                    lastPaperTheme = theme
                }

                // Always refresh display order before reload so edits/deletes stay consistent
                rebuildDisplayOrder(in: doc)
                dt.reloadData()

            } onChange: { [weak self] in
                DispatchQueue.main.async { self?.startObserving() }
            }
        }

        // MARK: Paper Theme

        func applyPaperTheme(_ theme: PaperTheme) {
            dataScroll?.appearance      = theme.nsAppearance
            dataScroll?.backgroundColor = theme.paperColor
            tableView?.backgroundColor  = theme.paperColor
        }

        // MARK: Find

        private func rebuildFindMatches(findText: String, caseSensitive: Bool) {
            findMatches = []
            guard let doc = document, !findText.isEmpty else { return }
            let needle = caseSensitive ? findText : findText.lowercased()
            for (displayRow, csvIdx) in displayOrder.enumerated() {
                let cells = doc.csvRows[csvIdx].cells
                for (colIdx, cell) in cells.enumerated() {
                    let hay = caseSensitive ? cell : cell.lowercased()
                    if hay.contains(needle) {
                        findMatches.append(CSVMatch(row: displayRow, col: colIdx))
                    }
                }
            }
        }

        // MARK: Copy

        func copySelectedRows() {
            guard let dt  = tableView,
                  let doc = document else { return }

            let selected = dt.selectedRowIndexes
            guard !selected.isEmpty else { return }

            let rows = selected.compactMap { displayRow -> CSVRow? in
                guard displayOrder.indices.contains(displayRow) else { return nil }
                return doc.csvRows[displayOrder[displayRow]]
            }

            // Always write TSV regardless of the file's native delimiter —
            // Google Sheets (and most spreadsheet apps) split on tabs, not commas.
            // The native file format is preserved in doc.text; this only affects the clipboard.
            let tsv = serializeDelimited(rows, delimiter: "\t")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tsv, forType: .string)
        }

        // MARK: Paste (Google Sheets / TSV grid detection)

        func pasteFromClipboard() {
            guard let dt    = tableView,
                  let doc   = document,
                  let delim = doc.csvDelimiter,
                  let clip  = NSPasteboard.general.string(forType: .string),
                  !clip.isEmpty else { return }

            // Parse clipboard as a TSV grid (Google Sheets copies tab-separated rows).
            // Falls back gracefully to a single value if no tabs/newlines are present.
            let clipGrid = parseClipboardGrid(clip)
            guard !clipGrid.isEmpty else { return }

            // Anchor: top-left of the current row selection + last clicked column.
            let anchorDisplayRow = dt.selectedRowIndexes.min() ?? 0
            let anchorCol        = dt.lastClickedDataColumn

            guard displayOrder.indices.contains(anchorDisplayRow) else { return }

            var changed = false
            for (rowOffset, pasteRow) in clipGrid.enumerated() {
                let targetDisplay = anchorDisplayRow + rowOffset
                guard displayOrder.indices.contains(targetDisplay) else { break }
                let csvIdx = displayOrder[targetDisplay]

                for (colOffset, value) in pasteRow.enumerated() {
                    let targetCol = anchorCol + colOffset
                    guard targetCol < doc.csvRows[csvIdx].cells.count else { continue }
                    doc.csvRows[csvIdx].cells[targetCol] = value
                    changed = true
                }
            }

            guard changed else { return }
            doc.text       = serializeDelimited(doc.csvRows, delimiter: delim)
            doc.isModified = true
            dt.reloadData()
        }

        /// Parses a TSV/CSV clipboard string into a 2-D grid of strings.
        /// Handles \r\n and \n line endings; auto-detects tabs vs commas.
        private func parseClipboardGrid(_ text: String) -> [[String]] {
            // Normalise line endings
            let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
                                 .replacingOccurrences(of: "\r",   with: "\n")
            var lines = normalised.components(separatedBy: "\n")
            // Drop trailing empty line left by a trailing newline
            if lines.last?.isEmpty == true { lines.removeLast() }
            guard !lines.isEmpty else { return [] }

            // Auto-detect delimiter: prefer tab (Google Sheets default), fall back to comma
            let sep: String = lines[0].contains("\t") ? "\t" : ","
            return lines.map { $0.components(separatedBy: sep) }
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int { displayOrder.count }

        // MARK: NSTableViewDelegate — cell views

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let col = tableColumn, let doc = document else { return nil }

            // ── Row-number column (non-editable) ─────────────────────────────
            if col.identifier.rawValue == "col_rownum" {
                let numID = NSUserInterfaceItemIdentifier("rownum_cell")
                var lbl = tableView.makeView(withIdentifier: numID, owner: nil) as? NSTextField
                if lbl == nil {
                    let f = NSTextField()
                    f.identifier      = numID
                    f.isEditable      = false
                    f.isBezeled       = false
                    f.drawsBackground = false
                    f.alignment       = .center
                    lbl = f
                }
                lbl?.stringValue = "\(row + 1)"
                lbl?.textColor   = .tertiaryLabelColor
                return lbl
            }

            guard let colIdxStr = col.identifier.rawValue.split(separator: "_").last,
                  let colIdx    = Int(colIdxStr) else { return nil }

            // ── Data cell (editable) ─────────────────────────────────────────
            let cellID = NSUserInterfaceItemIdentifier("data_cell")
            var field = tableView.makeView(withIdentifier: cellID, owner: nil) as? CSVEditableField
            if field == nil {
                let f = CSVEditableField()
                f.identifier      = cellID
                f.isEditable      = true
                f.isBezeled       = false
                f.lineBreakMode   = .byTruncatingTail
                f.drawsBackground = true
                f.backgroundColor = .clear
                field = f
            }
            guard let f = field else { return nil }

            // Refresh commit closure with current row/col
            f.onCommit = { [weak self] newValue in
                self?.commitEdit(tableRow: row, colIdx: colIdx, value: newValue)
            }

            let csvIdx = displayOrder.indices.contains(row) ? displayOrder[row] : -1
            let cells  = csvIdx >= 0 && csvIdx < doc.csvRows.count ? doc.csvRows[csvIdx].cells : []
            f.stringValue = colIdx < cells.count ? cells[colIdx] : ""
            f.textColor   = .labelColor
            f.alignment   = .left

            // Find highlighting
            let match     = CSVMatch(row: row, col: colIdx)
            let isCurrent = currentMatchIndex >= 0
                          && currentMatchIndex < findMatches.count
                          && findMatches[currentMatchIndex] == match
            let isAny     = !isCurrent && findMatches.contains(match)

            if isCurrent {
                f.drawsBackground = true
                f.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.45)
            } else if isAny {
                f.drawsBackground = true
                f.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.35)
            } else {
                f.drawsBackground = false
                f.backgroundColor = .clear
            }

            return f
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 22 }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

        // MARK: Double-click column divider → auto-size

        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            guard let doc = document, column < tableView.tableColumns.count else { return 80 }
            let col = tableView.tableColumns[column]

            if col.identifier.rawValue == "col_rownum" { return col.width }

            guard let colIdxStr = col.identifier.rawValue.split(separator: "_").last,
                  let colIdx    = Int(colIdxStr) else { return 80 }

            let headerWidth = CGFloat(col.title.count) * 7.0 + 8
            var maxChars: CGFloat = 0
            for csvIdx in displayOrder {
                if colIdx < doc.csvRows[csvIdx].cells.count {
                    maxChars = max(maxChars, CGFloat(doc.csvRows[csvIdx].cells[colIdx].count))
                }
            }
            return min(600, max(30, max(headerWidth, maxChars * 8.0 + 8)))
        }
    }
}
