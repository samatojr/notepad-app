import SwiftUI
import AppKit

// MARK: - Editable cell field

final class CSVEditableField: NSTextField {
    var onCommit: ((String) -> Void)?

    /// Cells are click-to-select and double-click-to-edit, like a spreadsheet.
    /// Until editing actually starts the field must be invisible to the mouse:
    /// an editable text field would otherwise swallow the click that begins a
    /// drag-selection, and the table would never see the drag at all.
    var isEditingEnabled = false

    /// Transparent to hit-testing while not editing, so the TABLE receives the
    /// whole mouse session — press, drag and release. Forwarding the click by
    /// hand would not work: drag events keep going to whichever view accepted
    /// the mouseDown.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isEditingEnabled ? super.hitTest(point) : nil
    }

    override var acceptsFirstResponder: Bool { isEditingEnabled }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        isEditingEnabled = false
        onCommit?(stringValue)
    }
}

// MARK: - Cell address

/// A single cell in DISPLAY coordinates — the row as shown (sorted, header
/// excluded) and the data column index.
struct GridCellAddress: Equatable {
    var row: Int
    var column: Int
}

// MARK: - Grid header view
//
// The header does two jobs that used to be one. Clicking a header now SELECTS
// that column, the way every spreadsheet behaves; sorting moved to the sort
// indicator at the right edge of the header cell and to the right-click menu.
// Splitting them by hit region keeps a single click doing the obvious thing
// while leaving sorting one click away.

final class GridHeaderView: NSTableHeaderView {
    /// Width of the sort hit zone at the trailing edge of each header cell.
    static let indicatorZoneWidth: CGFloat = 20

    var onSortColumn: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = column(at: point)
        guard index >= 0, index < tableView?.tableColumns.count ?? 0,
              let table = tableView else { super.mouseDown(with: event); return }

        let identifier = table.tableColumns[index].identifier.rawValue
        guard identifier != "col_rownum",
              let suffix = identifier.split(separator: "_").last,
              let dataColumn = Int(suffix) else { super.mouseDown(with: event); return }

        // The trailing strip sorts. Everything else is handed straight to AppKit:
        // it already knows how to tell a click from a column drag, and its own
        // tracking loop is what performs the reorder. Selection is driven from
        // the didClick delegate, which fires on a click but not after a drag —
        // reimplementing that discrimination here got the reorder wrong.
        let cellRect = headerRect(ofColumn: index)
        if point.x >= cellRect.maxX - Self.indicatorZoneWidth {
            onSortColumn?(dataColumn)
            return
        }
        super.mouseDown(with: event)
    }
}

// MARK: - NSTableView subclass: cell-range selection, copy/cut/paste, menus
//
// AppKit's own selection is row-at-a-time, so the rectangular selection that
// copy/paste of columns needs is tracked here instead: an anchor cell, a focus
// cell, and whether the user grabbed cells, whole rows or whole columns.
//
// AppKit's row selection is still kept in step underneath (with its highlight
// switched off, since the cells draw their own). That keeps every existing
// row operation — delete, insert, duplicate — working against
// `selectedRowIndexes` exactly as before.

final class CopyableTableView: NSTableView {

    /// What the user grabbed. Whole rows and whole columns are ordinary ranges
    /// that happen to span the full width or height, so one code path serves
    /// all three.
    enum SelectionSpan { case cells, wholeRows, wholeColumns }

    var copyHandler:      (() -> Void)?
    var cutHandler:       (() -> Void)?
    var pasteHandler:     (() -> Void)?
    var deleteHandler:    (() -> Void)?
    var insertHandler:    (() -> Void)?
    var duplicateHandler: (() -> Void)?
    var clearHandler:     (() -> Void)?

    var insertColumnHandler: ((Int) -> Void)?
    var deleteColumnHandler: (() -> Void)?
    var renameColumnHandler: ((Int) -> Void)?
    var sortColumnHandler:   ((Int) -> Void)?

    var selectionChanged: (() -> Void)?
    var beginEditRequested: ((Int, Int) -> Void)?

    /// Number of data columns, excluding the row-number column. Set by
    /// rebuildColumns so whole-row selection knows how far right to reach.
    var dataColumnCount: Int = 0

    private(set) var anchor: GridCellAddress?
    private(set) var focus:  GridCellAddress?
    private(set) var span:   SelectionSpan = .cells

    // MARK: Selection

    /// The current selection as a rectangle in display coordinates.
    var selectedRange: GridRange? {
        guard let anchor, let focus, numberOfRows > 0, dataColumnCount > 0 else { return nil }
        switch span {
        case .cells:
            return GridRange(anchorRow: anchor.row, anchorColumn: anchor.column,
                             focusRow: focus.row,   focusColumn: focus.column)
                .clamped(rowCount: numberOfRows, columnCount: dataColumnCount)
        case .wholeRows:
            return GridRange(topRow: min(anchor.row, focus.row),
                             bottomRow: max(anchor.row, focus.row),
                             leftColumn: 0, rightColumn: dataColumnCount - 1)
                .clamped(rowCount: numberOfRows, columnCount: dataColumnCount)
        case .wholeColumns:
            return GridRange(topRow: 0, bottomRow: numberOfRows - 1,
                             leftColumn: min(anchor.column, focus.column),
                             rightColumn: max(anchor.column, focus.column))
                .clamped(rowCount: numberOfRows, columnCount: dataColumnCount)
        }
    }

    /// Columns wholly covered by the selection — what the column operations act on.
    var fullySelectedColumns: IndexSet {
        guard let range = selectedRange else { return [] }
        guard span == .wholeColumns || range.rowCount >= numberOfRows else { return [] }
        return IndexSet(range.leftColumn...range.rightColumn)
    }

    func setSelection(anchor newAnchor: GridCellAddress,
                      focus newFocus: GridCellAddress? = nil,
                      span newSpan: SelectionSpan = .cells) {
        anchor = newAnchor
        focus  = newFocus ?? newAnchor
        span   = newSpan
        syncRowSelection()
        selectionChanged?()
    }

    func extendSelection(to newFocus: GridCellAddress) {
        guard anchor != nil else { setSelection(anchor: newFocus); return }
        focus = newFocus
        syncRowSelection()
        selectionChanged?()
    }

    func selectColumn(_ column: Int, extending: Bool) {
        // Selecting from the header bypasses this view's mouseDown entirely,
        // so focus has to be claimed here as well or ⌘C would do nothing.
        window?.makeFirstResponder(self)
        let address = GridCellAddress(row: 0, column: column)
        if extending, anchor != nil, span == .wholeColumns {
            focus = address
            syncRowSelection()
            selectionChanged?()
        } else {
            setSelection(anchor: address, focus: address, span: .wholeColumns)
        }
    }

    func selectRow(_ row: Int, extending: Bool) {
        let address = GridCellAddress(row: row, column: 0)
        if extending, anchor != nil, span == .wholeRows {
            focus = address
            syncRowSelection()
            selectionChanged?()
        } else {
            setSelection(anchor: address, focus: address, span: .wholeRows)
        }
    }

    func clearSelection() {
        anchor = nil
        focus  = nil
        span   = .cells
        deselectAll(nil)
        selectionChanged?()
    }

    /// Mirrors the rectangle onto AppKit's row selection. The highlight is off,
    /// so this is invisible — it exists so the row operations that already read
    /// `selectedRowIndexes` keep seeing what the user selected.
    private func syncRowSelection() {
        guard let range = selectedRange else { deselectAll(nil); return }
        let rows = IndexSet(integersIn: range.topRow...range.bottomRow)
        selectRowIndexes(rows, byExtendingSelection: false)
    }

    // MARK: Hit testing

    /// Data column index at a point, or nil over the row-number column / margin.
    func dataColumn(at point: NSPoint) -> Int? {
        let index = column(at: point)
        guard index >= 0, index < tableColumns.count else { return nil }
        let identifier = tableColumns[index].identifier.rawValue
        guard identifier != "col_rownum",
              let suffix = identifier.split(separator: "_").last,
              let value  = Int(suffix) else { return nil }
        return value
    }

    private func isOverRowNumberColumn(_ point: NSPoint) -> Bool {
        let index = column(at: point)
        guard index >= 0, index < tableColumns.count else { return false }
        return tableColumns[index].identifier.rawValue == "col_rownum"
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0 else { super.mouseDown(with: event); return }

        // Claim first responder by hand. Normally super.mouseDown does this, but
        // the selection paths below deliberately skip super to keep receiving
        // mouseDragged — and without this the table never takes focus, so ⌘C
        // and the arrow keys never reach keyDown at all.
        window?.makeFirstResponder(self)

        // The row-number column selects the whole row, like a spreadsheet gutter.
        if isOverRowNumberColumn(point) {
            selectRow(clickedRow, extending: event.modifierFlags.contains(.shift))
            return
        }

        guard let clickedColumn = dataColumn(at: point) else {
            super.mouseDown(with: event); return
        }

        // Double-click opens the cell for editing. Single click only selects —
        // dragging out a range is impossible if the first click starts an edit.
        if event.clickCount >= 2 {
            beginEditRequested?(clickedRow, clickedColumn)
            return
        }

        let address = GridCellAddress(row: clickedRow, column: clickedColumn)
        if event.modifierFlags.contains(.shift) {
            extendSelection(to: address)
        } else {
            setSelection(anchor: address)
        }
        // Deliberately not calling super: AppKit would start its own row-drag
        // tracking and we would stop receiving mouseDragged for the rubber band.
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let dragRow = row(at: point)
        guard dragRow >= 0 else { return }

        switch span {
        case .wholeRows:
            focus = GridCellAddress(row: dragRow, column: 0)
        case .wholeColumns:
            guard let dragColumn = dataColumn(at: point) else { return }
            focus = GridCellAddress(row: 0, column: dragColumn)
        case .cells:
            guard let dragColumn = dataColumn(at: point) else { return }
            focus = GridCellAddress(row: dragRow, column: dragColumn)
        }
        syncRowSelection()
        selectionChanged?()
        autoscroll(with: event)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c": copyHandler?();  return
            case "x": cutHandler?();   return
            case "v": pasteHandler?(); return
            default:  super.keyDown(with: event); return
            }
        }

        let extending = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 123: moveFocus(rowDelta: 0,  columnDelta: -1, extending: extending); return  // ←
        case 124: moveFocus(rowDelta: 0,  columnDelta: 1,  extending: extending); return  // →
        case 125: moveFocus(rowDelta: 1,  columnDelta: 0,  extending: extending); return  // ↓
        case 126: moveFocus(rowDelta: -1, columnDelta: 0,  extending: extending); return  // ↑
        case 36, 76:                                                                      // Return
            if let focus { beginEditRequested?(focus.row, focus.column) }
            return
        case 51, 117:                                                                     // Delete
            clearHandler?()
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    /// Moves the focus cell, extending the selection when shift is held and
    /// collapsing it to a single cell when it is not.
    private func moveFocus(rowDelta: Int, columnDelta: Int, extending: Bool) {
        guard numberOfRows > 0, dataColumnCount > 0 else { return }
        let base = (extending ? focus : nil) ?? focus ?? anchor
            ?? GridCellAddress(row: 0, column: 0)
        let moved = GridCellAddress(
            row:    max(0, min(base.row + rowDelta, numberOfRows - 1)),
            column: max(0, min(base.column + columnDelta, dataColumnCount - 1)))

        if extending {
            // Extending from whole rows or columns first pins the anchor to a
            // real cell, or the range would keep snapping back to full width.
            if span != .cells, let anchor {
                self.anchor = anchor
                span = .cells
            }
            extendSelection(to: moved)
        } else {
            setSelection(anchor: moved)
        }
        scrollRowToVisible(moved.row)
    }

    // MARK: Menu validation

    @objc func copy(_ sender: Any?)  { copyHandler?() }
    @objc func cut(_ sender: Any?)   { cutHandler?() }
    @objc func paste(_ sender: Any?) { pasteHandler?() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):  return copyHandler  != nil && selectedRange != nil
        case #selector(cut(_:)):   return cutHandler   != nil && selectedRange != nil
        case #selector(paste(_:)): return pasteHandler != nil
        default: return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        // Right-clicking outside the selection moves it there first, so the menu
        // always acts on what the user is pointing at.
        if clickedRow >= 0, let clickedColumn = dataColumn(at: point),
           selectedRange?.contains(row: clickedRow, column: clickedColumn) != true {
            setSelection(anchor: GridCellAddress(row: clickedRow, column: clickedColumn))
        }

        let menu = NSMenu()
        let hasSelection = selectedRange != nil

        if hasSelection {
            addItem(to: menu, "Copy",  #selector(copy(_:)))
            addItem(to: menu, "Cut",   #selector(cut(_:)))
        }
        if NSPasteboard.general.string(forType: .string) != nil {
            addItem(to: menu, "Paste", #selector(paste(_:)))
        }

        // ── Column operations ────────────────────────────────────────────────
        if let clickedColumn = dataColumn(at: point) {
            menu.addItem(.separator())
            let columns = fullySelectedColumns

            addItem(to: menu, "Insert Column Left",  #selector(insertColumnLeft(_:)))
            addItem(to: menu, "Insert Column Right", #selector(insertColumnRight(_:)))
            if !columns.isEmpty {
                let label = columns.count == 1 ? "Delete Column" : "Delete \(columns.count) Columns"
                addItem(to: menu, label, #selector(deleteColumns(_:)))
            }
            addItem(to: menu, "Rename Column…", #selector(renameColumn(_:)))

            menu.addItem(.separator())
            addItem(to: menu, "Sort by This Column", #selector(sortByColumn(_:)))
            menuColumn = clickedColumn
        }

        // ── Row operations ───────────────────────────────────────────────────
        menu.addItem(.separator())
        addItem(to: menu, "Insert Row", #selector(insertRow(_:)))

        if !selectedRowIndexes.isEmpty {
            let count = selectedRowIndexes.count
            addItem(to: menu, count == 1 ? "Duplicate Row" : "Duplicate \(count) Rows",
                    #selector(duplicateRows(_:)))
            menu.addItem(.separator())
            addItem(to: menu, count == 1 ? "Delete Row" : "Delete \(count) Rows",
                    #selector(deleteRows(_:)))
        }

        return menu.items.isEmpty ? nil : menu
    }

    /// Column the context menu was opened over — the column operations act here
    /// rather than on the keyboard focus, which may be elsewhere.
    private var menuColumn: Int = 0

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func deleteRows(_ sender: Any?)    { deleteHandler?() }
    @objc private func insertRow(_ sender: Any?)     { insertHandler?() }
    @objc private func duplicateRows(_ sender: Any?) { duplicateHandler?() }

    @objc private func insertColumnLeft(_ sender: Any?)  { insertColumnHandler?(menuColumn) }
    @objc private func insertColumnRight(_ sender: Any?) { insertColumnHandler?(menuColumn + 1) }
    @objc private func deleteColumns(_ sender: Any?)     { deleteColumnHandler?() }
    @objc private func renameColumn(_ sender: Any?)      { renameColumnHandler?(menuColumn) }
    @objc private func sortByColumn(_ sender: Any?)      { sortColumnHandler?(menuColumn) }
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
        // The cells draw their own selection, so AppKit's row highlight is off.
        // Row selection is still kept in sync underneath — see syncRowSelection.
        dataTable.selectionHighlightStyle = .none
        dataTable.allowsColumnReordering  = true

        // Header: click selects the column, the trailing indicator zone sorts.
        let header = GridHeaderView()
        header.onSortColumn = { [weak coord] column in coord?.toggleSort(column: column) }
        dataTable.headerView = header

        dataTable.copyHandler      = { [weak coord] in coord?.copySelection() }
        dataTable.cutHandler       = { [weak coord] in coord?.cutSelection() }
        dataTable.pasteHandler     = { [weak coord] in coord?.pasteFromClipboard() }
        dataTable.clearHandler     = { [weak coord] in coord?.clearSelectedCells() }
        dataTable.deleteHandler    = { [weak coord] in coord?.deleteSelectedRows() }
        dataTable.insertHandler    = { [weak coord] in coord?.insertRowBelowSelection() }
        dataTable.duplicateHandler = { [weak coord] in coord?.duplicateSelectedRows() }

        dataTable.insertColumnHandler = { [weak coord] at in coord?.insertColumn(at: at) }
        dataTable.deleteColumnHandler = { [weak coord] in coord?.deleteSelectedColumns() }
        dataTable.renameColumnHandler = { [weak coord] column in coord?.renameColumn(column) }
        dataTable.sortColumnHandler   = { [weak coord] column in coord?.toggleSort(column: column) }

        dataTable.selectionChanged    = { [weak coord] in coord?.selectionDidChange() }
        dataTable.beginEditRequested  = { [weak coord] row, column in
            coord?.beginEditing(row: row, column: column)
        }

        let scrollView = NSScrollView()
        scrollView.documentView          = dataTable
        scrollView.borderType            = .noBorder
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers    = true

        coord.tableView  = dataTable
        coord.dataScroll = scrollView
        coord.installKeyMonitor()
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

        /// Alignment per data column, inferred from the sampled values in
        /// rebuildColumns. Numbers right, short codes centered, text left.
        private var columnAlignments: [ColumnAlignment] = []

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
        private var lastStructureVersion: Int = 0
        private var lastFontSize:         CGFloat?
        private var lastGridRequestID:    Int?

        // Local key monitor for ⌘V — bypasses AppKit's menu key-equivalent
        // interception so paste reaches us before the Edit menu consumes it.
        private var keyMonitor: Any?

        // MARK: Fonts
        //
        // The grid is monospaced for the same reason the editor is: in a column of
        // numbers the digits have to line up, and a proportional font makes "1.00"
        // and "88.75" different widths. It also means the column-width maths can
        // measure one character instead of guessing an average.

        private var gridFont: NSFont {
            .monospacedSystemFont(ofSize: document?.fontSize ?? 13, weight: .regular)
        }

        /// Exact advance of one character — correct by definition for a monospaced
        /// font, where the old `chars * 8.0` guess was only ever close.
        private var charWidth: CGFloat {
            ("0" as NSString).size(withAttributes: [.font: gridFont]).width
        }

        private var rowHeight: CGFloat {
            let font = gridFont
            return ceil(font.ascender - font.descender + font.leading) + 6
        }

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
            let cellWidth = charWidth

            if doc.csvShowRowNumbers {
                let digits = dataCount > 0 ? Int(log10(Double(dataCount))) + 1 : 1
                let numCol = NSTableColumn(identifier: .init("col_rownum"))
                numCol.title                  = "#"
                numCol.isEditable             = false
                numCol.minWidth               = 30
                numCol.width                  = max(30, CGFloat(digits) * cellWidth + 16)
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

            columnAlignments = Array(repeating: .leading, count: colCount)

            for i in 0..<colCount {
                let title: String = showHeaders
                    ? { let t = titleRow[i]; return t.isEmpty ? "Column \(i+1)" : t }()
                    : columnLetter(i)

                let col = NSTableColumn(identifier: .init("col_\(i)"))
                col.title      = title
                col.isEditable = true
                // The header row deliberately keeps the system font: NSTableHeaderCell
                // ignores a font override under the .inset table style anyway, and the
                // native small header reads as chrome, which separates it from the
                // monospaced data below.

                // Width from the LONGEST value in the sample, not the average. With a
                // proportional font the average was a reasonable hedge; with a
                // monospaced one the exact width is knowable, and averaging meant any
                // cell longer than typical (a four-digit quantity in a column of
                // single digits) truncated for no reason. Capped at 40 characters so
                // one long note column can't push everything else off screen.
                // One pass over the sample serves both jobs: the widest value sets
                // the column width, and the values together decide its alignment.
                var columnValues: [String] = []
                columnValues.reserveCapacity(sample.count)
                var widest: CGFloat = 0
                for row in sample where i < row.cells.count {
                    let value = row.cells[i]
                    widest = max(widest, CGFloat(value.count))
                    columnValues.append(value)
                }

                columnAlignments[i] = inferColumnAlignment(columnValues)
                // Headers stay centered whatever the column holds. A spreadsheet
                // aligns the header to its data; here the data is monospaced and the
                // header is not, so centering keeps the header reading as chrome
                // rather than as a misaligned first row.
                col.headerCell.alignment = .center
                let firstRowChars = i < firstRowCells.count ? CGFloat(firstRowCells[i].count) : 0
                let chars = min(40, max(CGFloat(title.count), widest, firstRowChars))
                col.minWidth = 30
                col.width    = min(360, max(30, chars * cellWidth + 12))
                dt.addTableColumn(col)
            }

            dt.dataColumnCount = colCount

            rebuildDisplayOrder(in: doc)
            applySortIndicators()
            dt.reloadData()
        }

        // MARK: Commit cell edit

        func commitEdit(tableRow: Int, colIdx: Int, value: String) {
            guard let doc = document,
                  displayOrder.indices.contains(tableRow) else { return }

            let csvIdx = displayOrder[tableRow]
            guard csvIdx < doc.csvRows.count else { return }

            doc.mutateCSV(actionName: "Edit Cell") { rows in
                // Ragged rows are legal CSV. Pad short rows so their trailing cells
                // stay editable instead of silently swallowing the edit.
                if colIdx >= rows[csvIdx].cells.count {
                    rows[csvIdx].cells.append(contentsOf: Array(
                        repeating: "", count: colIdx - rows[csvIdx].cells.count + 1))
                }
                rows[csvIdx].cells[colIdx] = value
            }
        }

        // MARK: Delete selected rows

        func deleteSelectedRows() {
            guard let dt  = tableView,
                  let doc = document else { return }

            let selected = dt.selectedRowIndexes
            guard !selected.isEmpty else { return }

            let csvIndices = IndexSet(selected.compactMap {
                displayOrder.indices.contains($0) ? displayOrder[$0] : nil
            })
            let label = csvIndices.count == 1 ? "Delete Row" : "Delete Rows"
            doc.mutateCSV(actionName: label) { rows in
                rows.remove(atOffsets: csvIndices)
            }

            rebuildDisplayOrder(in: doc)
            dt.reloadData()
        }

        // MARK: Insert / duplicate rows

        /// Inserts a blank row below the selection (or at the end when nothing is
        /// selected), matching the current column count.
        func insertRowBelowSelection() {
            guard let dt = tableView, let doc = document else { return }
            let columnCount = doc.csvRows.map(\.cells.count).max() ?? 1
            let anchor = dt.selectedRowIndexes.max()
            let insertAt: Int = {
                guard let anchor, displayOrder.indices.contains(anchor) else {
                    return doc.csvRows.count
                }
                return displayOrder[anchor] + 1
            }()
            doc.mutateCSV(actionName: "Insert Row") { rows in
                rows.insert(CSVRow(cells: Array(repeating: "", count: max(1, columnCount))),
                            at: min(insertAt, rows.count))
            }
            rebuildDisplayOrder(in: doc)
            dt.reloadData()
        }

        /// Copies each selected row directly beneath itself.
        func duplicateSelectedRows() {
            guard let dt = tableView, let doc = document else { return }
            let csvIndices = dt.selectedRowIndexes.compactMap {
                displayOrder.indices.contains($0) ? displayOrder[$0] : nil
            }.sorted()
            guard !csvIndices.isEmpty else { return }

            let label = csvIndices.count == 1 ? "Duplicate Row" : "Duplicate Rows"
            doc.mutateCSV(actionName: label) { rows in
                // Walk backwards so the earlier insertion points stay valid.
                for index in csvIndices.reversed() where rows.indices.contains(index) {
                    rows.insert(CSVRow(cells: rows[index].cells), at: index + 1)
                }
            }
            rebuildDisplayOrder(in: doc)
            dt.reloadData()
        }

        // MARK: Column header click → sort

        /// Cycles a column's sort: ascending → descending → unsorted.
        ///
        /// Reached from the sort indicator zone in the header and from the
        /// right-click menu. Plain header clicks now select the column instead,
        /// so this is no longer the `didClick` delegate callback.
        func toggleSort(column: Int) {
            guard let doc = document, let dt = tableView else { return }

            if let index = doc.csvSortKeys.firstIndex(where: { $0.column == column }) {
                if doc.csvSortKeys[index].ascending {
                    doc.csvSortKeys[index].ascending = false
                } else {
                    doc.csvSortKeys.remove(at: index)
                }
            } else {
                doc.csvSortKeys.append(CSVSortKey(column: column, ascending: true))
            }

            rebuildDisplayOrder(in: doc)
            applySortIndicators()
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

                // ── Zoom ──────────────────────────────────────────────────────
                // ⌘+ / ⌘− and the status-bar zoom control have always changed
                // doc.fontSize; in grid mode nothing was listening, so they did
                // nothing at all. Column widths and row height both derive from the
                // font, so a size change means a full rebuild.
                let fontSize = doc.fontSize
                if fontSize != lastFontSize {
                    lastFontSize = fontSize
                    rebuildColumns()
                    dt.noteHeightOfRows(withIndexesChanged: IndexSet(0..<dt.numberOfRows))
                    return
                }

                // ── Grid mutation changed the table's shape → rebuild columns ──
                let structureVersion = doc.csvStructureVersion
                if structureVersion != lastStructureVersion {
                    lastStructureVersion = structureVersion
                    rebuildColumns()
                    return
                }

                // ── Go to Row ─────────────────────────────────────────────────
                if let request = doc.gridRowRequest, request.id != lastGridRequestID {
                    lastGridRequestID = request.id
                    let row = request.range.location
                    if row < displayOrder.count {
                        dt.scrollRowToVisible(row)
                        dt.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    }
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

        // MARK: Key monitor

        func installKeyMonitor() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      event.modifierFlags.contains(.command),
                      event.charactersIgnoringModifiers == "v",
                      self.document?.csvIsTableView == true,
                      // Every open CSV tab installs one of these monitors, so without
                      // a key-window check the paste could land in a background tab's
                      // document. Only the grid the user is looking at may claim ⌘V.
                      self.tableView?.window?.isKeyWindow == true
                else { return event }

                // Don't intercept if a cell text field is being edited
                let fr = NSApp.keyWindow?.firstResponder
                if fr is NSText || fr is NSTextField { return event }

                self.pasteFromClipboard()
                return nil   // consume — prevent the event reaching the Edit menu
            }
        }

        deinit {
            if let m = keyMonitor { NSEvent.removeMonitor(m) }
        }

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

        // MARK: Selection → clipboard

        /// The selected block, or nil when nothing is selected.
        private func selectedCells() -> [[String]]? {
            guard let dt = tableView, let doc = document,
                  let range = dt.selectedRange else { return nil }
            let cells = gridCells(from: doc.csvRows, range: range, displayOrder: displayOrder)
            return cells.isEmpty ? nil : cells
        }

        func copySelection() {
            guard let cells = selectedCells() else { return }
            // Always TSV regardless of the file's own delimiter — Google Sheets
            // and every other spreadsheet split pasted text on tabs, not commas.
            // The file's real format lives in doc.text and is untouched by this.
            let rows = cells.map { CSVRow(cells: $0) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(serializeDelimited(rows, delimiter: "\t"),
                                           forType: .string)
        }

        func cutSelection() {
            guard selectedCells() != nil else { return }
            copySelection()
            clearSelectedCells(actionName: "Cut")
        }

        /// Blanks the selected cells without moving anything around them.
        func clearSelectedCells(actionName: String = "Clear Cells") {
            guard let dt = tableView, let doc = document,
                  let range = dt.selectedRange else { return }
            let order = displayOrder
            doc.mutateCSV(actionName: actionName) { rows in
                clearCells(in: &rows, range: range, displayOrder: order)
            }
            dt.reloadData()
        }

        // MARK: Paste

        func pasteFromClipboard() {
            guard let dt  = tableView,
                  let doc = document,
                  doc.csvDelimiter != nil else { return }
            guard let clip = NSPasteboard.general.string(forType: .string),
                  !clip.isEmpty else { return }

            let clipGrid = parseClipboardGrid(clip)
            guard !clipGrid.isEmpty else { return }

            // Anchor at the top-left of the selection. With no selection the
            // paste lands at the first cell rather than being dropped.
            let range  = dt.selectedRange
            let anchorRow    = range?.topRow ?? 0
            let anchorColumn = range?.leftColumn ?? 0
            let order = displayOrder

            doc.mutateCSV(actionName: "Paste") { rows in
                pasteGrid(clipGrid, into: &rows,
                          atRow: anchorRow, column: anchorColumn, displayOrder: order)
            }

            // A changed shape needs new NSTableColumns, not just a reload.
            rebuildDisplayOrder(in: doc)
            rebuildColumns()

            // Leave the pasted block selected, the way a spreadsheet does.
            let height = clipGrid.count
            let width  = clipGrid.map(\.count).max() ?? 1
            dt.setSelection(anchor: GridCellAddress(row: anchorRow, column: anchorColumn),
                            focus: GridCellAddress(row: anchorRow + height - 1,
                                                   column: anchorColumn + width - 1))
        }

        // MARK: Column operations

        func insertColumn(at index: Int) {
            guard let dt = tableView, let doc = document else { return }
            doc.mutateCSV(actionName: "Insert Column") { rows in
                Notepad.insertColumn(in: &rows, at: index)
            }
            rebuildDisplayOrder(in: doc)
            rebuildColumns()
            dt.setSelection(anchor: GridCellAddress(row: 0, column: index),
                            focus: GridCellAddress(row: 0, column: index),
                            span: .wholeColumns)
        }

        func deleteSelectedColumns() {
            guard let dt = tableView, let doc = document else { return }
            let columns = dt.fullySelectedColumns
            guard !columns.isEmpty else { return }
            let label = columns.count == 1 ? "Delete Column" : "Delete Columns"
            doc.mutateCSV(actionName: label) { rows in
                deleteColumns(in: &rows, at: columns)
            }
            dt.clearSelection()
            rebuildDisplayOrder(in: doc)
            rebuildColumns()
        }

        /// Renames a column by editing the header cell of the file, which is only
        /// meaningful when the first row is being shown as headers.
        func renameColumn(_ column: Int) {
            guard let doc = document else { return }
            guard doc.csvShowHeaders, let header = doc.csvRows.first else {
                NSSound.beep(); return
            }
            let current = column < header.cells.count ? header.cells[column] : ""

            let alert = NSAlert.make()
            alert.messageText     = "Rename Column"
            alert.informativeText = "This edits the header row of the file."
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")

            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.stringValue = current
            alert.accessoryView = field
            alert.window.initialFirstResponder = field

            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let newName = field.stringValue

            doc.mutateCSV(actionName: "Rename Column") { rows in
                guard !rows.isEmpty else { return }
                if column >= rows[0].cells.count {
                    rows[0].cells.append(contentsOf: Array(
                        repeating: "", count: column - rows[0].cells.count + 1))
                }
                rows[0].cells[column] = newName
            }
            rebuildDisplayOrder(in: doc)
            rebuildColumns()
        }

        // MARK: Selection changes

        func selectionDidChange() {
            guard let dt = tableView, let doc = document else { return }

            let rowCount = dt.selectedRange.map(\.rowCount) ?? 0
            if doc.csvSelectedRowCount != rowCount { doc.csvSelectedRowCount = rowCount }

            // Publish only WHICH cells are selected, resolved to csvRows indices.
            // The arithmetic is derived in the status bar from the live cell
            // values, so it cannot go stale after an undo and nothing here has to
            // write a computed property back into the observed document.
            let range = dt.selectedRange
            let rows = range.map { r in
                (r.topRow...r.bottomRow).compactMap {
                    displayOrder.indices.contains($0) ? displayOrder[$0] : nil
                }
            } ?? []
            let columns = range.map { $0.leftColumn...$0.rightColumn }

            if doc.csvSelectionRows != rows { doc.csvSelectionRows = rows }
            if doc.csvSelectionColumns != columns { doc.csvSelectionColumns = columns }

            refreshSelectionDisplay()
        }

        /// Repaints the visible cells so the selection tint follows the selection.
        private func refreshSelectionDisplay() {
            guard let dt = tableView else { return }
            let visible = dt.rows(in: dt.visibleRect)
            guard visible.length > 0, !dt.tableColumns.isEmpty else { return }
            dt.reloadData(
                forRowIndexes: IndexSet(integersIn: visible.location..<visible.location + visible.length),
                columnIndexes: IndexSet(integersIn: 0..<dt.tableColumns.count))
        }

        /// Opens one cell for editing — double-click, or Return on the focused cell.
        func beginEditing(row: Int, column: Int) {
            guard let dt = tableView,
                  let columnIndex = dt.tableColumns.firstIndex(where: {
                      $0.identifier.rawValue == "col_\(column)"
                  }),
                  let field = dt.view(atColumn: columnIndex, row: row, makeIfNecessary: true)
                      as? CSVEditableField
            else { return }

            field.isEditingEnabled = true
            dt.window?.makeFirstResponder(field)
            field.selectText(nil)
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
            guard let col = tableColumn, let doc = document,
                  let tableView = tableView as? CopyableTableView else { return nil }

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
                // Set on every pass, not just on creation: these views are reused,
                // and the font changes when the user zooms.
                lbl?.font        = gridFont
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
            f.font        = gridFont
            f.alignment   = columnAlignments.indices.contains(colIdx)
                ? columnAlignments[colIdx].textAlignment
                : .left

            // Views are recycled, so editing state has to be cleared on every pass
            // or a cell can inherit the previous occupant's open editor.
            f.isEditingEnabled = false

            // Background priority: a find hit outranks the selection, because the
            // point of finding something is seeing where it landed.
            let match     = CSVMatch(row: row, col: colIdx)
            let isCurrent = currentMatchIndex >= 0
                          && currentMatchIndex < findMatches.count
                          && findMatches[currentMatchIndex] == match
            let isAny     = !isCurrent && findMatches.contains(match)

            let selection   = tableView.selectedRange
            let isSelected  = selection?.contains(row: row, column: colIdx) ?? false
            let isFocusCell = tableView.anchor == GridCellAddress(row: row, column: colIdx)

            if isCurrent {
                f.drawsBackground = true
                f.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.45)
            } else if isAny {
                f.drawsBackground = true
                f.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.35)
            } else if isSelected {
                f.drawsBackground = true
                // The anchor reads a little stronger, so the cell the keyboard
                // acts on stays findable inside a large selection.
                f.backgroundColor = NSColor.selectedContentBackgroundColor
                    .withAlphaComponent(isFocusCell ? 0.42 : 0.24)
            } else {
                f.drawsBackground = false
                f.backgroundColor = .clear
            }

            return f
        }

        /// A header click that AppKit did not treat as the start of a column drag.
        /// This is where column selection happens — letting AppKit make the
        /// click-vs-drag call is what keeps drag-to-reorder working.
        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let dt = self.tableView,
                  tableColumn.identifier.rawValue != "col_rownum",
                  let suffix = tableColumn.identifier.rawValue.split(separator: "_").last,
                  let column = Int(suffix) else { return }
            let extending = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            dt.selectColumn(column, extending: extending)
        }

        // MARK: Column reordering
        //
        // AppKit moves the NSTableColumn on screen; the move only becomes real
        // once it is written back into csvRows. rebuildColumns then regenerates
        // the columns from data order, which reverses AppKit's visual move and
        // re-applies it from the model — leaving exactly one move in effect.

        func tableView(_ tableView: NSTableView,
                       shouldReorderColumn columnIndex: Int,
                       toColumn newColumnIndex: Int) -> Bool {
            // The row-number gutter is chrome: it never moves, and nothing may
            // be dropped in front of it.
            guard tableView.tableColumns.first?.identifier.rawValue == "col_rownum"
            else { return true }
            return columnIndex != 0 && newColumnIndex != 0
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let doc = document,
                  let oldIndex = notification.userInfo?["NSOldColumn"] as? Int,
                  let newIndex = notification.userInfo?["NSNewColumn"] as? Int,
                  let dt = tableView else { return }

            // Visual indices include the row-number gutter; data indices do not.
            let offset = dt.tableColumns.first?.identifier.rawValue == "col_rownum" ? 1 : 0
            let from = oldIndex - offset
            let to   = newIndex - offset
            guard from >= 0, to >= 0, from != to else { return }

            doc.mutateCSV(actionName: "Move Column") { rows in
                moveColumn(in: &rows, from: from, to: to)
            }

            // Sort keys address columns by index, so a move that did not update
            // them would leave the grid sorted by whatever slid into that slot.
            doc.csvSortKeys = doc.csvSortKeys.map {
                CSVSortKey(column: Self.remapColumn($0.column, from: from, to: to),
                           ascending: $0.ascending)
            }

            dt.clearSelection()
            rebuildDisplayOrder(in: doc)
            rebuildColumns()
        }

        /// Where a column index ends up after the column at `from` moves to `to`.
        static func remapColumn(_ index: Int, from: Int, to: Int) -> Int {
            if index == from { return to }
            if from < to { return (index > from && index <= to) ? index - 1 : index }
            return (index >= to && index < from) ? index + 1 : index
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeight }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

        // MARK: Double-click column divider → auto-size

        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            guard let doc = document, column < tableView.tableColumns.count else { return 80 }
            let col = tableView.tableColumns[column]

            if col.identifier.rawValue == "col_rownum" { return col.width }

            guard let colIdxStr = col.identifier.rawValue.split(separator: "_").last,
                  let colIdx    = Int(colIdxStr) else { return 80 }

            let cellWidth   = charWidth
            let headerWidth = CGFloat(col.title.count) * cellWidth + 12
            var maxChars: CGFloat = 0
            for csvIdx in displayOrder {
                if colIdx < doc.csvRows[csvIdx].cells.count {
                    maxChars = max(maxChars, CGFloat(doc.csvRows[csvIdx].cells[colIdx].count))
                }
            }
            return min(600, max(30, max(headerWidth, maxChars * cellWidth + 12)))
        }
    }
}
