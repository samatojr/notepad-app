import SwiftUI
import AppKit

// MARK: - NSTableView subclass for ⌘C copy support

final class CopyableTableView: NSTableView {
    var copyHandler: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "c" {
            copyHandler?()
        } else {
            super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        copyHandler?()
    }
}

// MARK: - Find match coordinate

struct CSVMatch: Equatable {
    let row: Int   // 0-indexed data row
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
        dataTable.copyHandler = { [weak coord] in coord?.copySelectedRows() }

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

        // Find state
        private var findMatches:       [CSVMatch] = []
        private var currentMatchIndex: Int        = -1
        private var lastFindText:      String     = ""
        private var lastCaseSensitive: Bool       = false

        // Change tracking
        private var lastPaperTheme:     PaperTheme?
        private var lastShowRowNumbers: Bool = false
        private var lastShowHeaders:    Bool = true

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

        /// The rows treated as data (respects the Headers toggle).
        private func dataRows(in doc: NotepadDocument) -> ArraySlice<CSVRow> {
            doc.csvShowHeaders ? doc.csvRows.dropFirst() : doc.csvRows[...]
        }

        // MARK: Column setup

        func rebuildColumns() {
            guard let dt = tableView, let doc = document else { return }
            for col in dt.tableColumns { dt.removeTableColumn(col) }
            guard !doc.csvRows.isEmpty else { dt.reloadData(); return }

            let showHeaders = doc.csvShowHeaders
            let allData     = dataRows(in: doc)
            let dataCount   = allData.count

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
            // Headers ON  → titles come from row 0; data sampled from rows 1+
            // Headers OFF → titles are A/B/C…;      data sampled from all rows
            let titleRow: [String] = showHeaders
                ? (doc.csvRows.first?.cells ?? [])
                : []
            let colCount: Int = showHeaders
                ? (doc.csvRows.first?.cells.count ?? 0)
                : (doc.csvRows.map(\.cells.count).max() ?? 0)

            let sample = Array(allData.prefix(200))

            // When headers are off, the first CSV row (original "header") is
            // now data row 0. Its values can be much wider than the single-letter
            // column label, so we use them as an additional width floor.
            let firstRowCells = doc.csvRows.first?.cells ?? []

            for i in 0..<colCount {
                let title: String = showHeaders
                    ? { let t = titleRow[i]; return t.isEmpty ? "Column \(i+1)" : t }()
                    : columnLetter(i)

                let col = NSTableColumn(identifier: .init("col_\(i)"))
                col.title      = title
                col.isEditable = false

                // Center letter-style (A/B/C…) headers; leave named headers left-aligned
                if !showHeaders {
                    col.headerCell.alignment = .center
                }

                let avgChars: CGFloat = sample.isEmpty ? 0 : {
                    let total = sample.reduce(0) { $0 + (i < $1.cells.count ? $1.cells[i].count : 0) }
                    return CGFloat(total) / CGFloat(sample.count)
                }()

                // Take the largest of: column label, avg data, first-row value
                // (first-row matters most when headers are off — it was the header)
                let firstRowChars = i < firstRowCells.count ? CGFloat(firstRowCells[i].count) : 0
                let minWidth: CGFloat = 30
                let chars    = max(CGFloat(title.count), avgChars, firstRowChars)
                col.minWidth = minWidth
                col.width    = min(300, max(minWidth, chars * 8.0 + 8))
                dt.addTableColumn(col)
            }

            dt.reloadData()
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
                        rebuildFindMatches(findText: findText,
                                          caseSensitive: caseSensitive,
                                          dataRows: Array(dataRows(in: doc)))
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

                // ── Paper theme ───────────────────────────────────────────────
                let theme = AppPreferences.shared.paperTheme
                if theme != lastPaperTheme {
                    applyPaperTheme(theme)
                    lastPaperTheme = theme
                }

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

        private func rebuildFindMatches(findText: String,
                                        caseSensitive: Bool,
                                        dataRows: [CSVRow]) {
            findMatches = []
            guard !findText.isEmpty else { return }
            let needle = caseSensitive ? findText : findText.lowercased()
            for (rowIdx, row) in dataRows.enumerated() {
                for (colIdx, cell) in row.cells.enumerated() {
                    let hay = caseSensitive ? cell : cell.lowercased()
                    if hay.contains(needle) {
                        findMatches.append(CSVMatch(row: rowIdx, col: colIdx))
                    }
                }
            }
        }

        // MARK: Copy

        func copySelectedRows() {
            guard let dt = tableView, let doc = document,
                  let delim = doc.csvDelimiter else { return }

            let selected = dt.selectedRowIndexes
            guard !selected.isEmpty else { return }

            // When headers are off, NSTableView row 0 = csvRows[0]
            let offset = doc.csvShowHeaders ? 1 : 0
            let rows = selected.compactMap { dataRow -> CSVRow? in
                let csvIdx = dataRow + offset
                guard csvIdx < doc.csvRows.count else { return nil }
                return doc.csvRows[csvIdx]
            }

            let csv = serializeDelimited(rows, delimiter: delim)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(csv, forType: .string)
        }

        // MARK: NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            guard let doc = document, !doc.csvRows.isEmpty else { return 0 }
            // Headers ON: row 0 is the header, data starts at row 1
            // Headers OFF: all rows are data
            return doc.csvShowHeaders ? max(0, doc.csvRows.count - 1) : doc.csvRows.count
        }

        // MARK: NSTableViewDelegate — cell views

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let col = tableColumn, let doc = document else { return nil }

            let cellID = NSUserInterfaceItemIdentifier("data_cell")
            var tf = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTextField
            if tf == nil {
                let f = NSTextField()
                f.identifier      = cellID
                f.isEditable      = false
                f.isBezeled       = false
                f.lineBreakMode   = .byTruncatingTail
                f.drawsBackground = true
                f.backgroundColor = .clear
                tf = f
            }
            guard let field = tf else { return nil }

            // Row-number column
            if col.identifier.rawValue == "col_rownum" {
                field.stringValue     = "\(row + 1)"
                field.textColor       = .tertiaryLabelColor
                field.alignment       = .center
                field.drawsBackground = false
                field.backgroundColor = .clear
                return field
            }

            guard let colIdxStr = col.identifier.rawValue.split(separator: "_").last,
                  let colIdx    = Int(colIdxStr) else { return field }

            // Headers ON: NSTableView row 0 → csvRows[1]; OFF: row 0 → csvRows[0]
            let csvIdx = doc.csvShowHeaders ? row + 1 : row
            let cells  = csvIdx < doc.csvRows.count ? doc.csvRows[csvIdx].cells : []
            field.stringValue = colIdx < cells.count ? cells[colIdx] : ""
            field.textColor   = .labelColor
            field.alignment   = .left

            // Find highlighting
            let match     = CSVMatch(row: row, col: colIdx)
            let isCurrent = currentMatchIndex >= 0
                          && currentMatchIndex < findMatches.count
                          && findMatches[currentMatchIndex] == match
            let isAny     = !isCurrent && findMatches.contains(match)

            if isCurrent {
                field.drawsBackground = true
                field.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.45)
            } else if isAny {
                field.drawsBackground = true
                field.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.35)
            } else {
                field.drawsBackground = false
                field.backgroundColor = .clear
            }

            return field
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
            for row in dataRows(in: doc) {
                if colIdx < row.cells.count {
                    maxChars = max(maxChars, CGFloat(row.cells[colIdx].count))
                }
            }
            let dataWidth = maxChars * 8.0 + 8

            return min(600, max(30, max(headerWidth, dataWidth)))
        }
    }
}
