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
        // Ctrl-click is a right-click here too, not a column selection.
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }

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

    /// A right-click on the header shows the same menu the grid does.
    ///
    /// NSTableHeaderView is its own view, so a right-click here never reaches the
    /// table's `menu(for:)`. Without this the header had no menu at all and the
    /// column operations were only reachable by selecting the column and then
    /// right-clicking down in the data — which is not where anyone looks for them.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let index = column(at: point)
        guard let table = tableView as? CopyableTableView,
              index >= 0, index < table.tableColumns.count else { return nil }

        let identifier = table.tableColumns[index].identifier.rawValue
        guard identifier != "col_rownum",
              let suffix = identifier.split(separator: "_").last,
              let dataColumn = Int(suffix) else { return nil }

        // Point at a column that is not selected and the menu should act on the
        // one being pointed at, so select it first — the same rule the grid uses.
        if !table.fullySelectedColumns.contains(dataColumn) {
            table.selectColumn(dataColumn, extending: false)
        }
        return table.contextMenu(forColumn: dataColumn, includingRowOperations: false)
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

    var fillDownHandler:  (() -> Void)?
    var fillRightHandler: (() -> Void)?
    var clearSortHandler: (() -> Void)?

    // 4.1 quick actions. Column-taking handlers receive the column the context
    // menu was opened over, or nil from the menu bar to mean "the selection".
    var fillSeriesHandler:   (() -> Void)?
    var calculateHandler:    ((Int?) -> Void)?
    var totalsHandler:       (() -> Void)?
    var transformHandler:    ((TextTransform) -> Void)?
    var joinColumnsHandler:  (() -> Void)?
    var splitColumnHandler:  ((Int?) -> Void)?
    var moveRowsHandler:     ((Int) -> Void)?          // -1 up, +1 down
    var keepSortHandler:     (() -> Void)?
    /// Asked before a row drag starts. False means the grid is sorted, and the
    /// handler explains why the rows can't move instead of starting the drag.
    var rowMoveAllowed:      (() -> Bool)?
    var rowMoveRefused:      (() -> Void)?
    /// Statistics for the context menu, and where a clicked one goes.
    var summaryProvider:     (() -> SelectionSummary?)?
    var copyStatisticHandler: ((_ value: String, _ name: String) -> Void)?

    var selectionChanged: (() -> Void)?
    var beginEditRequested: ((Int, Int) -> Void)?

    /// Number of data columns, excluding the row-number column. Set by
    /// rebuildColumns so whole-row selection knows how far right to reach.
    var dataColumnCount: Int = 0 {
        // A change of shape leaves ⌘-clicked pieces addressing columns that
        // moved; the operations that change shape reselect what they made.
        didSet { if dataColumnCount != oldValue { extraPieces = [] } }
    }

    private(set) var anchor: GridCellAddress?
    private(set) var focus:  GridCellAddress?
    private(set) var span:   SelectionSpan = .cells

    /// One rectangle of the selection, kept as the user made it — two corners
    /// and what they grabbed — so a whole-column piece still reaches the last
    /// row after rows are added.
    struct SelectionPiece: Equatable {
        var anchor: GridCellAddress
        var focus: GridCellAddress
        var span: SelectionSpan
    }

    /// Earlier pieces kept by ⌘-click, for picking cells that aren't next to
    /// each other. The ACTIVE piece — the one shift-click and the arrow keys
    /// act on — is still anchor / focus / span, so everything that works on a
    /// single rectangle keeps working on the one the user is shaping.
    private(set) var extraPieces: [SelectionPiece] = []

    // MARK: Selection

    private func resolve(anchor: GridCellAddress, focus: GridCellAddress,
                         span: SelectionSpan) -> GridRange? {
        guard numberOfRows > 0, dataColumnCount > 0 else { return nil }
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

    /// The ACTIVE rectangle in display coordinates — what every single-range
    /// operation (paste, move rows, insert column) acts on.
    var selectedRange: GridRange? {
        guard let anchor, let focus else { return nil }
        return resolve(anchor: anchor, focus: focus, span: span)
    }

    /// Every rectangle selected, ⌘-clicked pieces first and the active one last.
    var selectedRanges: [GridRange] {
        extraPieces.compactMap { resolve(anchor: $0.anchor, focus: $0.focus, span: $0.span) }
            + (selectedRange.map { [$0] } ?? [])
    }

    var hasMultipleRanges: Bool { !extraPieces.isEmpty && selectedRange != nil }

    func isCellSelected(row: Int, column: Int) -> Bool {
        selectedRanges.contains { $0.contains(row: row, column: column) }
    }

    /// Every column any piece touches, left to right — what Join acts on.
    var selectedColumns: [Int] {
        Set(selectedRanges.flatMap { $0.leftColumn...$0.rightColumn }).sorted()
    }

    /// Columns wholly covered by the selection — what the column operations
    /// act on. ⌘-clicking two headers makes both of them whole.
    var fullySelectedColumns: IndexSet {
        var columns = IndexSet()
        for range in selectedRanges where range.rowCount >= numberOfRows {
            columns.insert(integersIn: range.leftColumn...range.rightColumn)
        }
        return columns
    }

    /// `adding` keeps what is already selected as extra pieces (⌘-click);
    /// otherwise the selection starts over.
    func setSelection(anchor newAnchor: GridCellAddress,
                      focus newFocus: GridCellAddress? = nil,
                      span newSpan: SelectionSpan = .cells,
                      adding: Bool = false) {
        if adding, let anchor, let focus {
            extraPieces.append(SelectionPiece(anchor: anchor, focus: focus, span: span))
        } else {
            extraPieces = []
        }
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

    /// ⌘-click on a cell: adds it as a new piece of the selection, or takes it
    /// back out when it is already a piece on its own — how a mis-click is undone.
    func toggleCell(_ address: GridCellAddress) {
        let single = SelectionPiece(anchor: address, focus: address, span: .cells)
        if let index = extraPieces.firstIndex(of: single) {
            extraPieces.remove(at: index)
        } else if anchor == address, focus == address, span == .cells {
            // The active piece is this cell: step back to the previous piece,
            // or deselect entirely when it was the only thing selected.
            guard let previous = extraPieces.popLast() else { clearSelection(); return }
            anchor = previous.anchor
            focus  = previous.focus
            span   = previous.span
        } else {
            setSelection(anchor: address, adding: true)
            return
        }
        syncRowSelection()
        selectionChanged?()
    }

    func selectColumn(_ column: Int, extending: Bool, adding: Bool = false) {
        // Selecting from the header bypasses this view's mouseDown entirely,
        // so focus has to be claimed here as well or ⌘C would do nothing.
        window?.makeFirstResponder(self)
        let address = GridCellAddress(row: 0, column: column)
        if extending, anchor != nil, span == .wholeColumns {
            focus = address
            syncRowSelection()
            selectionChanged?()
        } else {
            setSelection(anchor: address, focus: address, span: .wholeColumns, adding: adding)
        }
    }

    func selectRow(_ row: Int, extending: Bool, adding: Bool = false) {
        let address = GridCellAddress(row: row, column: 0)
        if extending, anchor != nil, span == .wholeRows {
            focus = address
            syncRowSelection()
            selectionChanged?()
        } else {
            setSelection(anchor: address, focus: address, span: .wholeRows, adding: adding)
        }
    }

    func clearSelection() {
        anchor = nil
        focus  = nil
        span   = .cells
        extraPieces = []
        deselectAll(nil)
        selectionChanged?()
    }

    /// Mirrors the selection onto AppKit's row selection. The highlight is off,
    /// so this is invisible — it exists so the row operations that already read
    /// `selectedRowIndexes` keep seeing what the user selected, every piece of it:
    /// ⌘-clicking rows 2 and 5 and choosing Delete Rows deletes both.
    private func syncRowSelection() {
        let ranges = selectedRanges
        guard !ranges.isEmpty else { deselectAll(nil); return }
        var rows = IndexSet()
        for range in ranges { rows.insert(integersIn: range.topRow...range.bottomRow) }
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

    // MARK: Row dragging
    //
    // Rows move the way they do in a spreadsheet: select them in the # gutter,
    // then press on the selection and drag. Pressing on rows that are already
    // selected is ambiguous until the mouse moves — it may be a drag or just a
    // click to select one row — so the press is parked in `pendingRowDrag` and
    // resolved by whichever comes first, a drag past a few points or a mouseUp.
    //
    // The drop itself is NSTableView's own machinery (validateDrop / acceptDrop
    // in the coordinator), which draws the insertion line and autoscrolls.

    private var pendingRowDrag: (row: Int, origin: NSPoint)?
    private lazy var rowDragSource = RowDragSource(table: self)

    /// Whether a gutter press at `row` lands on a whole-row selection.
    private func isOnSelectedRows(_ row: Int) -> Bool {
        // Rows move as one block; a ⌘-clicked selection of scattered rows can't.
        guard span == .wholeRows, extraPieces.isEmpty, let range = selectedRange else { return false }
        return row >= range.topRow && row <= range.bottomRow
    }

    private func beginRowDrag(with event: NSEvent) {
        guard let range = selectedRange else { return }
        guard rowMoveAllowed?() ?? false else { rowMoveRefused?(); return }

        let rowsRect = rect(ofRow: range.topRow).union(rect(ofRow: range.bottomRow))
        let visible = rowsRect.intersection(visibleRect)
        guard !visible.isEmpty else { return }

        let item = NSPasteboardItem()
        item.setString("\(range.topRow)-\(range.bottomRow)", forType: .notepadGridRows)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(visible, contents: snapshot(of: visible))
        let session = beginDraggingSession(with: [dragItem], event: event, source: rowDragSource)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    /// A picture of the rows being dragged, selection tint and all.
    private func snapshot(of rect: NSRect) -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: rect) else { return NSImage(size: rect.size) }
        cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return image
    }

    // An open hand over selected rows in the gutter says "these can be dragged".
    private var gutterTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let gutterTrackingArea { removeTrackingArea(gutterTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        gutterTrackingArea = area
    }

    private var showingGrabCursor = false

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let grabbable = isOverRowNumberColumn(point) && isOnSelectedRows(row(at: point))
        if grabbable { NSCursor.openHand.set() } else if showingGrabCursor { NSCursor.arrow.set() }
        showingGrabCursor = grabbable
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        // Ctrl-click is the Mac's right-click. This override used to treat it as
        // a plain click, which threw the selection away instead of showing the
        // menu for it — the worst outcome for anyone with a Windows habit of
        // Ctrl-clicking to add cells.
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }

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
            let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
            if modifiers.isEmpty, isOnSelectedRows(clickedRow) {
                pendingRowDrag = (clickedRow, event.locationInWindow)
                return
            }
            selectRow(clickedRow, extending: event.modifierFlags.contains(.shift),
                      adding: event.modifierFlags.contains(.command))
            return
        }

        guard let clickedColumn = dataColumn(at: point) else {
            super.mouseDown(with: event); return
        }

        let address = GridCellAddress(row: clickedRow, column: clickedColumn)

        // ⌘-click picks cells that aren't next to each other — the Mac's
        // version of Ctrl-click in Windows spreadsheets (Ctrl-click here is a
        // right-click). Dragging on from here adds a whole range.
        if event.modifierFlags.contains(.command) {
            toggleCell(address)
            return
        }

        // Double-click opens the cell for editing. Single click only selects —
        // dragging out a range is impossible if the first click starts an edit.
        // Only a second click on the SAME cell counts, and never with shift: a
        // quick click-then-shift-click across the grid can arrive with a click
        // count of 2, and it means "select this range", not "edit that cell".
        if event.clickCount >= 2, !event.modifierFlags.contains(.shift), anchor == address {
            beginEditRequested?(clickedRow, clickedColumn)
            return
        }

        if event.modifierFlags.contains(.shift) {
            extendSelection(to: address)
        } else {
            setSelection(anchor: address)
        }
        // Deliberately not calling super: AppKit would start its own row-drag
        // tracking and we would stop receiving mouseDragged for the rubber band.
    }

    override func mouseUp(with event: NSEvent) {
        if let pending = pendingRowDrag {
            // Pressed on the selected rows and let go without moving: a plain
            // click, which selects just that row like any other gutter click.
            pendingRowDrag = nil
            selectRow(pending.row, extending: false)
            return
        }
        super.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if let pending = pendingRowDrag {
            let dx = event.locationInWindow.x - pending.origin.x
            let dy = event.locationInWindow.y - pending.origin.y
            guard dx * dx + dy * dy >= 16 else { return }
            pendingRowDrag = nil
            beginRowDrag(with: event)
            return
        }

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
        let extending = event.modifierFlags.contains(.shift)

        if event.modifierFlags.contains(.command) {
            // ⌥⌘↑ / ⌥⌘↓ move the selected rows. Normally the Table menu's key
            // equivalent catches these first; this is the path when it can't.
            if event.modifierFlags.contains(.option), event.keyCode == 125 || event.keyCode == 126 {
                moveRowsHandler?(event.keyCode == 126 ? -1 : 1)
                return
            }
            // ⌘ + arrow jumps to the edge of the grid, the way a spreadsheet does.
            switch event.keyCode {
            case 123: jumpToEdge(rowDelta: 0,  columnDelta: -1, extending: extending); return
            case 124: jumpToEdge(rowDelta: 0,  columnDelta: 1,  extending: extending); return
            case 125: jumpToEdge(rowDelta: 1,  columnDelta: 0,  extending: extending); return
            case 126: jumpToEdge(rowDelta: -1, columnDelta: 0,  extending: extending); return
            default: break
            }
            switch event.charactersIgnoringModifiers {
            case "c": copyHandler?();      return
            case "x": cutHandler?();       return
            case "v": pasteHandler?();     return
            case "d": fillDownHandler?();  return
            case "r": fillRightHandler?(); return
            default:  super.keyDown(with: event); return
            }
        }

        switch event.keyCode {
        case 48:                                                                          // Tab
            // Tab walks cell to cell and wraps at the edges — shift-Tab goes back.
            moveByCell(forward: !extending)
            return
        case 115: moveToRowEdge(trailing: false, extending: extending); return             // Home
        case 119: moveToRowEdge(trailing: true,  extending: extending); return             // End
        case 123: moveFocus(rowDelta: 0,  columnDelta: -1, extending: extending); return   // ←
        case 124: moveFocus(rowDelta: 0,  columnDelta: 1,  extending: extending); return   // →
        case 125: moveFocus(rowDelta: 1,  columnDelta: 0,  extending: extending); return   // ↓
        case 126: moveFocus(rowDelta: -1, columnDelta: 0,  extending: extending); return   // ↑
        case 36, 76:                                                                       // Return
            if let focus { beginEditRequested?(focus.row, focus.column) }
            return
        case 51, 117:                                                                      // Delete
            clearHandler?()
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    /// Tab / shift-Tab: one cell along, wrapping to the next or previous row.
    private func moveByCell(forward: Bool) {
        guard numberOfRows > 0, dataColumnCount > 0 else { return }
        let base = focus ?? anchor ?? GridCellAddress(row: 0, column: 0)
        var row = base.row
        var column = base.column + (forward ? 1 : -1)
        if column >= dataColumnCount {
            column = 0
            row = min(row + 1, numberOfRows - 1)
        } else if column < 0 {
            column = dataColumnCount - 1
            row = max(row - 1, 0)
        }
        setSelection(anchor: GridCellAddress(row: row, column: column))
        scrollRowToVisible(row)
    }

    /// ⌘ + arrow: straight to the far edge in that direction.
    private func jumpToEdge(rowDelta: Int, columnDelta: Int, extending: Bool) {
        guard numberOfRows > 0, dataColumnCount > 0 else { return }
        let base = focus ?? anchor ?? GridCellAddress(row: 0, column: 0)
        let target = GridCellAddress(
            row:    rowDelta == 0    ? base.row    : (rowDelta > 0 ? numberOfRows - 1 : 0),
            column: columnDelta == 0 ? base.column : (columnDelta > 0 ? dataColumnCount - 1 : 0))
        if extending { extendSelection(to: target) } else { setSelection(anchor: target) }
        scrollRowToVisible(target.row)
    }

    /// Home / End: first or last column of the current row.
    private func moveToRowEdge(trailing: Bool, extending: Bool) {
        jumpToEdge(rowDelta: 0, columnDelta: trailing ? 1 : -1, extending: extending)
    }

    /// ⌘A selects every cell, not every row — the grid's unit is the cell.
    override func selectAll(_ sender: Any?) {
        guard numberOfRows > 0, dataColumnCount > 0 else { return }
        setSelection(anchor: GridCellAddress(row: 0, column: 0),
                     focus: GridCellAddress(row: numberOfRows - 1,
                                            column: dataColumnCount - 1))
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
        case #selector(selectAll(_:)):
            return numberOfRows > 0 && dataColumnCount > 0
        case #selector(fillDownAction(_:)), #selector(fillSeriesAction(_:)):
            // Needs a piece at least two rows tall: with one row there is
            // nothing to fill into. Each piece fills on its own.
            return selectedRanges.contains { $0.rowCount > 1 }
        case #selector(fillRightAction(_:)):
            return selectedRanges.contains { $0.columnCount > 1 }
        case #selector(insertColumnBeforeAction(_:)),
             #selector(insertColumnAfterAction(_:)),
             #selector(renameColumnAction(_:)):
            // "Before the selection" means nothing when it is in several places.
            return selectedRange != nil && !hasMultipleRanges
        case #selector(deleteColumnsAction(_:)):
            return !fullySelectedColumns.isEmpty
        case #selector(duplicateRowsAction(_:)), #selector(deleteRowsAction(_:)):
            return !selectedRowIndexes.isEmpty
        case #selector(insertRowAction(_:)):
            return true
        case #selector(joinColumnsAction(_:)):
            return selectedColumns.count > 1
        case #selector(splitColumnAction(_:)):
            return selectedColumns.count == 1
        case #selector(splitClickedColumn(_:)), #selector(calculateFromClickedColumn(_:)),
             #selector(calculateAction(_:)), #selector(totalsAction(_:)):
            return dataColumnCount > 0 && numberOfRows > 0
        case #selector(trimSpacesAction(_:)), #selector(uppercaseAction(_:)),
             #selector(lowercaseAction(_:)), #selector(titleCaseAction(_:)):
            return selectedRange != nil
        case #selector(moveRowsUpAction(_:)):
            guard let range = selectedRange, !hasMultipleRanges else { return false }
            return range.topRow > 0 || !(rowMoveAllowed?() ?? true)
        case #selector(moveRowsDownAction(_:)):
            guard let range = selectedRange, !hasMultipleRanges else { return false }
            return range.bottomRow < numberOfRows - 1 || !(rowMoveAllowed?() ?? true)
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
           !isCellSelected(row: clickedRow, column: clickedColumn) {
            setSelection(anchor: GridCellAddress(row: clickedRow, column: clickedColumn))
        }
        // The same rule in the # gutter, which is where rows are handled from.
        if clickedRow >= 0, isOverRowNumberColumn(point),
           !selectedRanges.contains(where: { clickedRow >= $0.topRow && clickedRow <= $0.bottomRow
                                             && $0.columnCount == dataColumnCount }) {
            selectRow(clickedRow, extending: false)
        }
        return contextMenu(forColumn: dataColumn(at: point), includingRowOperations: true)
    }

    /// Builds the grid's context menu.
    ///
    /// Shared with the column header, which reaches it through its own
    /// `menu(for:)`: NSTableHeaderView is a separate view and a right-click there
    /// never travels to the table, so without this the header offered no menu at
    /// all — you had to select the column and then right-click down in the data.
    ///
    /// `column` is nil over the row-number gutter, where the column operations
    /// have nothing to act on. Row operations are left out for the header, where
    /// "Delete Row" would be about a row the user never pointed at.
    func contextMenu(forColumn column: Int?, includingRowOperations: Bool) -> NSMenu {
        let menu = NSMenu()
        contextColumn = column

        // ── Statistics ───────────────────────────────────────────────────────
        if let summary = summaryProvider?(), summary.cellCount > 1 {
            addStatistics(summary, to: menu)
            menu.addItem(.separator())
        }

        if selectedRange != nil {
            addItem(to: menu, "Copy", #selector(copy(_:)))
            addItem(to: menu, "Cut",  #selector(cut(_:)))
        }
        if NSPasteboard.general.string(forType: .string) != nil {
            addItem(to: menu, "Paste", #selector(paste(_:)))
        }

        // ── Quick actions ────────────────────────────────────────────────────
        if selectedRange != nil || column != nil {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(submenu("Calculate", [
                ("New Column from Calculation…", #selector(calculateFromClickedColumn(_:))),
                ("Add Totals Row",               #selector(totalsAction(_:))),
                ("Fill Series",                  #selector(fillSeriesAction(_:))),
            ]))
            menu.addItem(submenu("Text", [
                ("Trim Spaces", #selector(trimSpacesAction(_:))),
                ("UPPERCASE",   #selector(uppercaseAction(_:))),
                ("lowercase",   #selector(lowercaseAction(_:))),
                ("Title Case",  #selector(titleCaseAction(_:))),
                nil,
                ("Join Columns…", #selector(joinColumnsAction(_:))),
                ("Split Column…", column != nil ? #selector(splitClickedColumn(_:))
                                                : #selector(splitColumnAction(_:))),
            ]))
        }

        // ── Column operations ────────────────────────────────────────────────
        if let column {
            menuColumn = column
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            addItem(to: menu, "Insert Column Left",  #selector(insertColumnLeft(_:)))
            addItem(to: menu, "Insert Column Right", #selector(insertColumnRight(_:)))

            let columns = fullySelectedColumns
            if !columns.isEmpty {
                let label = columns.count == 1 ? "Delete Column" : "Delete \(columns.count) Columns"
                addItem(to: menu, label, #selector(deleteColumns(_:)))
            }
            addItem(to: menu, "Rename Column…", #selector(renameColumn(_:)))

            menu.addItem(.separator())
            addItem(to: menu, "Sort by This Column", #selector(sortByColumn(_:)))
        }

        // ── Row operations ───────────────────────────────────────────────────
        if includingRowOperations {
            menu.addItem(.separator())
            addItem(to: menu, "Insert Row", #selector(insertRow(_:)))

            if !selectedRowIndexes.isEmpty {
                let count = selectedRowIndexes.count
                addItem(to: menu, count == 1 ? "Duplicate Row" : "Duplicate \(count) Rows",
                        #selector(duplicateRows(_:)))
                addItem(to: menu, count == 1 ? "Move Row Up" : "Move Rows Up",
                        #selector(moveRowsUpAction(_:)), arrow: NSUpArrowFunctionKey)
                addItem(to: menu, count == 1 ? "Move Row Down" : "Move Rows Down",
                        #selector(moveRowsDownAction(_:)), arrow: NSDownArrowFunctionKey)
                menu.addItem(.separator())
                addItem(to: menu, count == 1 ? "Delete Row" : "Delete \(count) Rows",
                        #selector(deleteRows(_:)))
            }
        }

        return menu
    }

    /// Column the context menu was opened over — the column operations act here
    /// rather than on the keyboard focus, which may be elsewhere.
    private var menuColumn: Int = 0

    /// The same, but nil over the # gutter, for the quick actions that fall
    /// back to the selection when no column was pointed at.
    private var contextColumn: Int?

    /// `arrow` shows ⌥⌘ plus that arrow beside the item, matching the Table
    /// menu. In a context menu it is a label only; the Table menu owns the key.
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, arrow: Int? = nil) {
        let key = arrow.flatMap(UnicodeScalar.init).map { String(Character($0)) } ?? ""
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if arrow != nil { item.keyEquivalentModifierMask = [.command, .option] }
        item.target = self
        menu.addItem(item)
    }

    /// A submenu of items targeting this table; nil entries become separators.
    private func submenu(_ title: String, _ entries: [(String, Selector)?]) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        for entry in entries {
            if let (itemTitle, action) = entry {
                addItem(to: submenu, itemTitle, action)
            } else {
                submenu.addItem(.separator())
            }
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Sum, average, count, min and max of the selection, values lined up on
    /// the right. Choosing one copies its exact value as a plain number. A
    /// selection with no numbers in it shows only how many cells are filled.
    private func addStatistics(_ summary: SelectionSummary, to menu: NSMenu) {
        menu.addItem(.sectionHeader(title: "Selection — click to copy"))

        var rows: [(name: String, shown: String, copied: String)] = []
        func add(_ name: String, _ value: Double, isAverage: Bool = false) {
            rows.append((name,
                         summary.formatted(value, isAverage: isAverage, grouped: true),
                         summary.formatted(value, isAverage: isAverage, grouped: false)))
        }
        if summary.hasNumbers { add("Sum", summary.sum) }
        if let average = summary.average { add("Average", average, isAverage: true) }
        rows.append(("Count", "\(summary.filledCount)", "\(summary.filledCount)"))
        if let minimum = summary.minimum, let maximum = summary.maximum {
            add("Min", minimum)
            add("Max", maximum)
        }

        let font   = NSFont.menuFont(ofSize: 0)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
        let nameWidth  = rows.map { ($0.name as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let valueWidth = rows.map { ($0.shown as NSString).size(withAttributes: [.font: digits]).width }.max() ?? 0
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: ceil(nameWidth + 40 + valueWidth))]

        for row in rows {
            let title = NSMutableAttributedString(string: row.name + "\t",
                                                  attributes: [.font: font, .paragraphStyle: style])
            title.append(NSAttributedString(string: row.shown,
                                            attributes: [.font: digits, .paragraphStyle: style]))
            let item = NSMenuItem(title: "\(row.name) \(row.shown)",
                                  action: #selector(copyStatistic(_:)), keyEquivalent: "")
            item.attributedTitle = title
            item.representedObject = [row.copied, row.name]
            item.toolTip = "Copy \(row.copied)"
            item.target = self
            menu.addItem(item)
        }
    }

    @objc private func copyStatistic(_ sender: NSMenuItem) {
        guard let parts = sender.representedObject as? [String], parts.count == 2 else { return }
        copyStatisticHandler?(parts[0], parts[1])
    }

    // MARK: Menu-bar actions
    //
    // The Table menu sends these up the responder chain with
    // NSApp.sendAction(_:to:nil:), so they fire only while a grid actually has
    // focus — a text document simply never answers them. They act on the
    // SELECTION, unlike the context-menu versions below, which act on whatever
    // column was right-clicked.

    /// Column the menu-bar column operations act on: the left edge of the selection.
    private var selectionColumn: Int? { selectedRange?.leftColumn }

    @objc func fillDownAction(_ sender: Any?)  { fillDownHandler?() }
    @objc func fillRightAction(_ sender: Any?) { fillRightHandler?() }
    @objc func clearSortAction(_ sender: Any?) { clearSortHandler?() }

    @objc func insertColumnBeforeAction(_ sender: Any?) {
        guard let column = selectionColumn else { return }
        insertColumnHandler?(column)
    }

    @objc func insertColumnAfterAction(_ sender: Any?) {
        guard let range = selectedRange else { return }
        insertColumnHandler?(range.rightColumn + 1)
    }

    @objc func deleteColumnsAction(_ sender: Any?) { deleteColumnHandler?() }

    @objc func renameColumnAction(_ sender: Any?) {
        guard let column = selectionColumn else { return }
        renameColumnHandler?(column)
    }

    @objc func insertRowAction(_ sender: Any?)     { insertHandler?() }
    @objc func duplicateRowsAction(_ sender: Any?) { duplicateHandler?() }
    @objc func deleteRowsAction(_ sender: Any?)    { deleteHandler?() }

    @objc private func deleteRows(_ sender: Any?)    { deleteHandler?() }
    @objc private func insertRow(_ sender: Any?)     { insertHandler?() }
    @objc private func duplicateRows(_ sender: Any?) { duplicateHandler?() }

    // Quick actions — shared by the Table menu and the context menu.
    @objc func fillSeriesAction(_ sender: Any?)   { fillSeriesHandler?() }
    @objc func calculateAction(_ sender: Any?)    { calculateHandler?(nil) }
    @objc func totalsAction(_ sender: Any?)       { totalsHandler?() }
    @objc func trimSpacesAction(_ sender: Any?)   { transformHandler?(.trimSpaces) }
    @objc func uppercaseAction(_ sender: Any?)    { transformHandler?(.uppercase) }
    @objc func lowercaseAction(_ sender: Any?)    { transformHandler?(.lowercase) }
    @objc func titleCaseAction(_ sender: Any?)    { transformHandler?(.titleCase) }
    @objc func joinColumnsAction(_ sender: Any?)  { joinColumnsHandler?() }
    @objc func splitColumnAction(_ sender: Any?)  { splitColumnHandler?(nil) }
    @objc func moveRowsUpAction(_ sender: Any?)   { moveRowsHandler?(-1) }
    @objc func moveRowsDownAction(_ sender: Any?) { moveRowsHandler?(1) }
    @objc func keepSortAction(_ sender: Any?)     { keepSortHandler?() }

    @objc private func calculateFromClickedColumn(_ sender: Any?) { calculateHandler?(contextColumn) }
    @objc private func splitClickedColumn(_ sender: Any?)         { splitColumnHandler?(contextColumn) }

    @objc private func insertColumnLeft(_ sender: Any?)  { insertColumnHandler?(menuColumn) }
    @objc private func insertColumnRight(_ sender: Any?) { insertColumnHandler?(menuColumn + 1) }
    @objc private func deleteColumns(_ sender: Any?)     { deleteColumnHandler?() }
    @objc private func renameColumn(_ sender: Any?)      { renameColumnHandler?(menuColumn) }
    @objc private func sortByColumn(_ sender: Any?)      { sortColumnHandler?(menuColumn) }
}

// MARK: - Row drag source

extension NSPasteboard.PasteboardType {
    /// Private to this app, so a dragged row can't be dropped as text somewhere
    /// it would read as a paste — the only thing that accepts it is a grid.
    static let notepadGridRows = NSPasteboard.PasteboardType("com.josephsea.notepad.grid-rows")
}

/// Source for a row drag. Kept separate from the table rather than leaning on
/// NSTableView's own source methods, which expect a drag the table started
/// itself through super.mouseDown — a path the grid deliberately never takes.
final class RowDragSource: NSObject, NSDraggingSource {
    weak var table: CopyableTableView?

    init(table: CopyableTableView) {
        self.table = table
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
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

        dataTable.fillDownHandler  = { [weak coord] in coord?.fillDown() }
        dataTable.fillRightHandler = { [weak coord] in coord?.fillRight() }
        dataTable.clearSortHandler = { [weak coord] in coord?.clearSort() }

        dataTable.fillSeriesHandler  = { [weak coord] in coord?.fillSeries() }
        dataTable.calculateHandler   = { [weak coord] column in coord?.addCalculatedColumn(from: column) }
        dataTable.totalsHandler      = { [weak coord] in coord?.addTotalsRow() }
        dataTable.transformHandler   = { [weak coord] transform in coord?.transformSelection(transform) }
        dataTable.joinColumnsHandler = { [weak coord] in coord?.joinSelectedColumns() }
        dataTable.splitColumnHandler = { [weak coord] column in coord?.splitColumn(column) }
        dataTable.moveRowsHandler    = { [weak coord] delta in coord?.moveSelectedRows(by: delta) }
        dataTable.keepSortHandler    = { [weak coord] in coord?.keepSortedOrder() }
        dataTable.rowMoveAllowed     = { [weak coord] in coord?.document?.csvSortKeys.isEmpty ?? false }
        dataTable.rowMoveRefused     = { [weak coord] in coord?.explainSortedMove() }
        dataTable.summaryProvider    = { [weak coord] in coord?.selectionSummary() }
        dataTable.copyStatisticHandler = { [weak coord] value, name in
            coord?.document?.copyStatistic(value, named: name)
        }
        dataTable.registerForDraggedTypes([.notepadGridRows])

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
            let previous = displayOrder
            computeDisplayOrder(in: doc)
            // A new order means the same display rows now hold different csvRows.
            // Deferred because this also runs inside the observation closure,
            // where writing observed document state would re-trigger it.
            if displayOrder != previous {
                DispatchQueue.main.async { [weak self] in self?.publishSelection() }
            }
        }

        private func computeDisplayOrder(in doc: NotepadDocument) {
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

        /// Copies the selection as TSV. Returns false when there was nothing to copy.
        @discardableResult
        func copySelection() -> Bool {
            guard let dt = tableView, let doc = document else { return false }
            guard let copied = combinedCells(from: doc.csvRows, ranges: dt.selectedRanges,
                                             displayOrder: displayOrder),
                  !copied.grid.isEmpty else { return false }
            let cells = copied.grid
            // Always TSV regardless of the file's own delimiter — Google Sheets
            // and every other spreadsheet split pasted text on tabs, not commas.
            // The file's real format lives in doc.text and is untouched by this.
            let rows = cells.map { CSVRow(cells: $0) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(serializeDelimited(rows, delimiter: "\t"),
                                           forType: .string)
            // Say so when the gaps between the pieces were closed up, so a paste
            // that comes out more compact than the selection isn't a surprise.
            if copied.closedGaps {
                let count = cells.reduce(0) { $0 + $1.count }
                doc.showStatusNotice("Copied \(count) cells, gaps left out", symbol: "list.bullet")
            }
            return true
        }

        func cutSelection() {
            // Only clear what actually reached the clipboard.
            guard copySelection() else { return }
            clearSelectedCells(actionName: "Cut")
        }

        /// Blanks every selected cell, in every piece, without moving anything
        /// around them.
        func clearSelectedCells(actionName: String = "Clear Cells") {
            guard let dt = tableView, let doc = document else { return }
            let ranges = dt.selectedRanges
            guard !ranges.isEmpty else { return }
            let order = displayOrder
            doc.mutateCSV(actionName: actionName) { rows in
                for range in ranges { clearCells(in: &rows, range: range, displayOrder: order) }
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

        // MARK: Fill

        /// ⌘D. Continues a pattern when the top two cells make one (1, 2 ·
        /// Mon, Tue · Item 1, Item 2) and copies the top cell down otherwise.
        func fillDown()   { fill(mode: .continuePatternOrCopy, actionName: "Fill Down") }

        /// Always counts: one seed steps by 1, an empty column numbers from 1.
        func fillSeries() { fill(mode: .series, actionName: "Fill Series") }

        /// Each selected piece fills from its own top cells, the way a
        /// spreadsheet fills a ⌘-clicked selection one range at a time.
        private func fill(mode: FillMode, actionName: String) {
            guard let dt = tableView, let doc = document else { return }
            let ranges = dt.selectedRanges.filter { $0.rowCount > 1 }
            guard !ranges.isEmpty else { return }
            let order = displayOrder
            doc.mutateCSV(actionName: actionName) { rows in
                for range in ranges {
                    Notepad.fillSeries(in: &rows, range: range, displayOrder: order, mode: mode)
                }
            }
            dt.reloadData()
        }

        func fillRight() {
            guard let dt = tableView, let doc = document else { return }
            let ranges = dt.selectedRanges.filter { $0.columnCount > 1 }
            guard !ranges.isEmpty else { return }
            let order = displayOrder
            doc.mutateCSV(actionName: "Fill Right") { rows in
                for range in ranges {
                    Notepad.fillRight(in: &rows, range: range, displayOrder: order)
                }
            }
            dt.reloadData()
        }

        func clearSort() {
            guard let dt = tableView, let doc = document, !doc.csvSortKeys.isEmpty else { return }
            doc.csvSortKeys = []
            rebuildDisplayOrder(in: doc)
            applySortIndicators()
            dt.reloadData()
        }

        // MARK: Column operations

        func insertColumn(at index: Int) {
            guard let dt = tableView, let doc = document else { return }
            doc.mutateCSV(actionName: "Insert Column") { rows in
                Notepad.insertColumn(in: &rows, at: index)
            }
            shiftSortKeys(insertedAt: index, count: 1)
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
            // A sort on a deleted column goes with it; the rest shift left.
            doc.csvSortKeys = doc.csvSortKeys.compactMap { key in
                Self.columnAfterDelete(key.column, deleted: columns)
                    .map { CSVSortKey(column: $0, ascending: key.ascending) }
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

        // MARK: Sort keys across column changes
        //
        // Sort keys address columns by index. An insert or delete that doesn't
        // carry them along leaves the grid sorted by whatever slid into that
        // slot — the same trap the column move already handles with remapColumn.

        private func shiftSortKeys(insertedAt index: Int, count: Int) {
            guard let doc = document, !doc.csvSortKeys.isEmpty else { return }
            doc.csvSortKeys = doc.csvSortKeys.map {
                CSVSortKey(column: Self.columnAfterInsert($0.column, at: index, count: count),
                           ascending: $0.ascending)
            }
        }

        static func columnAfterInsert(_ column: Int, at index: Int, count: Int) -> Int {
            column >= index ? column + count : column
        }

        /// Where a column lands after `deleted` are removed, or nil if it was one of them.
        static func columnAfterDelete(_ column: Int, deleted: IndexSet) -> Int? {
            deleted.contains(column) ? nil : column - deleted.count(in: 0..<column)
        }

        // MARK: Statistics

        /// The selection's numbers for the context menu. Capped like the status
        /// bar's, so a whole column of a huge file can't stall the menu.
        func selectionSummary() -> SelectionSummary? {
            guard let dt = tableView, let doc = document else { return nil }
            let ranges = dt.selectedRanges
            guard !ranges.isEmpty,
                  ranges.reduce(0, { $0 + $1.rowCount * $1.columnCount }) <= 200_000 else { return nil }
            let blocks = selectionBlocks(for: ranges, displayOrder: displayOrder)
            return summarize([selectedCellValues(in: doc.csvRows, blocks: blocks)])
        }

        // MARK: Quick actions

        /// 1 when the first row is showing as headers, 0 when it is data.
        private var headerRows: Int { document?.csvShowHeaders == true ? 1 : 0 }

        /// What each data column is called on screen: its header, or its letter.
        private func dataColumnTitles() -> [String] {
            guard let dt = tableView else { return [] }
            return (0..<dt.dataColumnCount).map { index in
                dt.tableColumns.first { $0.identifier.rawValue == "col_\(index)" }?.title
                    ?? columnLetter(index)
            }
        }

        /// Leaves the columns a quick action just made selected and in view.
        private func selectColumns(_ columns: ClosedRange<Int>) {
            guard let dt = tableView else { return }
            dt.setSelection(anchor: GridCellAddress(row: 0, column: columns.lowerBound),
                            focus: GridCellAddress(row: 0, column: columns.upperBound),
                            span: .wholeColumns)
            if let index = dt.tableColumns.firstIndex(where: {
                $0.identifier.rawValue == "col_\(columns.upperBound)"
            }) { dt.scrollColumnToVisible(index) }
        }

        func addCalculatedColumn(from column: Int?) {
            guard let dt = tableView, let doc = document, dt.dataColumnCount > 0 else { return }
            let columns = dataColumnTitles().enumerated().map { index, title in
                ColumnCalculationForm.Column(
                    title: title,
                    isNumeric: columnAlignments.indices.contains(index)
                        && columnAlignments[index] == .trailing)
            }
            let samples = displayOrder.prefix(200).enumerated().map {
                (displayRow: $0.offset, cells: doc.csvRows[$0.element].cells)
            }
            guard let result = QuickActionDialogs.askCalculation(
                columns: columns, sampleRows: samples,
                preferredLeft: column ?? dt.selectedColumns.first ?? 0,
                // Two columns picked (say ⌘-clicked Price and Qty): use both.
                preferredRight: column == nil && dt.selectedColumns.count == 2
                    ? dt.selectedColumns.last : nil) else { return }

            let headerRows = headerRows
            doc.mutateCSV(actionName: "New Column from Calculation") { rows in
                insertCalculatedColumn(in: &rows, at: result.insertAt, title: result.title,
                                       calculation: result.calculation, headerRows: headerRows)
            }
            shiftSortKeys(insertedAt: result.insertAt, count: 1)
            rebuildDisplayOrder(in: doc)
            rebuildColumns()
            selectColumns(result.insertAt...result.insertAt)
        }

        func addTotalsRow() {
            guard let dt = tableView, let doc = document else { return }
            let headerRows = headerRows
            let totals = totalsRow(for: doc.csvRows, headerRows: headerRows)
            guard totals.contains(where: { !$0.isEmpty && $0 != totalsLabel }) else {
                NSSound.beep()
                doc.showStatusNotice("No number columns to total",
                                     symbol: "exclamationmark.circle")
                return
            }
            let replacing = doc.csvRows.count > headerRows + 1
                && doc.csvRows.last.map(isTotalsRow) == true
            doc.mutateCSV(actionName: replacing ? "Update Totals Row" : "Add Totals Row") { rows in
                appendTotalsRow(to: &rows, headerRows: headerRows)
            }
            rebuildDisplayOrder(in: doc)
            dt.reloadData()
            if let row = displayOrder.firstIndex(of: doc.csvRows.count - 1) {
                dt.selectRow(row, extending: false)
                dt.scrollRowToVisible(row)
            }
        }

        func transformSelection(_ transform: TextTransform) {
            guard let dt = tableView, let doc = document else { return }
            let ranges = dt.selectedRanges
            guard !ranges.isEmpty else { return }
            let order = displayOrder
            doc.mutateCSV(actionName: transform.title) { rows in
                // Overlapping pieces would transform a shared cell twice; every
                // transform here gives the same answer the second time, so that
                // is harmless and not worth deduplicating.
                for range in ranges { transformCells(in: &rows, range: range, displayOrder: order, transform) }
            }
            dt.reloadData()
        }

        /// Joins every column the selection touches — neighbours, or columns
        /// ⌘-clicked apart like First and Last with Age between them.
        func joinSelectedColumns() {
            guard let dt = tableView, let doc = document else { return }
            let columns = dt.selectedColumns
            guard columns.count > 1, let last = columns.last else { NSSound.beep(); return }
            let titles = dataColumnTitles()
            let names = columns.map { titles.indices.contains($0) ? titles[$0] : columnLetter($0) }
            guard let separator = QuickActionDialogs.askSeparator(
                title: "Join Columns",
                message: "Joins \(names.formatted(.list(type: .and))) into a new column to "
                    + "their right. The original columns stay as they are.",
                button: "Join",
                choices: QuickActionDialogs.joinSeparators) else { return }

            let headerRows = headerRows
            doc.mutateCSV(actionName: "Join Columns") { rows in
                joinColumns(in: &rows, columns: columns, separator: separator, headerRows: headerRows)
            }
            shiftSortKeys(insertedAt: last + 1, count: 1)
            rebuildDisplayOrder(in: doc)
            rebuildColumns()
            selectColumns((last + 1)...(last + 1))
        }

        /// Splits `requested`, or the one selected column when called from the
        /// menu bar with no column pointed at.
        func splitColumn(_ requested: Int?) {
            guard let dt = tableView, let doc = document else { return }
            let selected = dt.selectedColumns.count == 1 ? dt.selectedColumns.first : nil
            guard let column = requested ?? selected else { NSSound.beep(); return }
            let titles = dataColumnTitles()
            let name = titles.indices.contains(column) ? titles[column] : columnLetter(column)

            guard let separator = QuickActionDialogs.askSeparator(
                title: "Split Column",
                message: "Splits “\(name)” into new columns to its right. "
                    + "The original column stays as it is.",
                button: "Split",
                choices: QuickActionDialogs.splitSeparators) else { return }

            let headerRows = headerRows
            let count = splitColumnCount(in: doc.csvRows, column: column,
                                         separator: separator, headerRows: headerRows)
            guard count > 1 else {
                let alert = NSAlert.make()
                alert.messageText = "Nothing to split"
                alert.informativeText = "No cell in “\(name)” contains that separator."
                alert.runModal()
                return
            }
            // Splitting a notes column on spaces can mean hundreds of columns.
            if count > 10 {
                let alert = NSAlert.make()
                alert.messageText = "Split into \(count) columns?"
                alert.informativeText = "The longest cell in “\(name)” has \(count) parts, "
                    + "so this adds \(count) columns."
                alert.addButton(withTitle: "Split")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }

            doc.mutateCSV(actionName: "Split Column") { rows in
                Notepad.splitColumn(in: &rows, column: column, separator: separator,
                                    headerRows: headerRows)
            }
            shiftSortKeys(insertedAt: column + 1, count: count)
            rebuildDisplayOrder(in: doc)
            rebuildColumns()
            selectColumns((column + 1)...(column + count))
        }

        // MARK: Moving rows

        /// ⌥⌘↑ / ⌥⌘↓: nudges the selected rows one place.
        func moveSelectedRows(by delta: Int) {
            guard let dt = tableView, let range = dt.selectedRange else { return }
            guard !dt.hasMultipleRanges else { refuseScatteredMove(); return }
            guard document?.csvSortKeys.isEmpty == true else { explainSortedMove(); return }
            let gap = delta < 0 ? range.topRow - 1 : range.bottomRow + 2
            guard gap >= 0, gap <= displayOrder.count else { NSSound.beep(); return }
            moveSelectedRows(toGap: gap)
        }

        /// Moves the selected rows in front of display row `gap` and keeps them
        /// selected in their new place. Shared by the drag and the keyboard.
        @discardableResult
        func moveSelectedRows(toGap gap: Int) -> Bool {
            guard let dt = tableView, let doc = document, let range = dt.selectedRange else { return false }
            guard !dt.hasMultipleRanges else { refuseScatteredMove(); return false }
            guard doc.csvSortKeys.isEmpty else { explainSortedMove(); return false }
            let order = displayOrder
            var moved: ClosedRange<Int>?
            doc.mutateCSV(actionName: range.rowCount == 1 ? "Move Row" : "Move Rows") { rows in
                moved = moveRows(in: &rows, displayRows: range.topRow...range.bottomRow,
                                 toGap: gap, displayOrder: order)
            }
            guard let moved else { return false }
            rebuildDisplayOrder(in: doc)
            dt.reloadData()
            dt.setSelection(anchor: GridCellAddress(row: moved.lowerBound, column: range.leftColumn),
                            focus: GridCellAddress(row: moved.upperBound, column: range.rightColumn),
                            span: dt.span == .wholeRows ? .wholeRows : .cells)
            dt.scrollRowToVisible(gap <= range.topRow ? moved.lowerBound : moved.upperBound)
            return true
        }

        private func refuseScatteredMove() {
            NSSound.beep()
            document?.showStatusNotice("Only rows that are together can move",
                                       symbol: "exclamationmark.circle")
        }

        /// A sort only changes how rows are SHOWN, so there is no order to move
        /// a row within. Rather than silently refusing, offer the two ways out.
        func explainSortedMove() {
            guard let window = tableView?.window, window.attachedSheet == nil else { return }
            let alert = NSAlert.make()
            alert.messageText = "Rows can’t be moved while the table is sorted"
            alert.informativeText = "Sorting only changes how the rows are shown — the file "
                + "keeps its own order. Keep the sorted order to make it the file’s order, "
                + "or clear the sort to go back to the file’s order."
            alert.addButton(withTitle: "Keep Sorted Order")
            alert.addButton(withTitle: "Clear Sort")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                switch response {
                case .alertFirstButtonReturn:  self?.keepSortedOrder()
                case .alertSecondButtonReturn: self?.clearSort()
                default: break
                }
            }
        }

        /// Writes the sort into the file and drops the sort, so what is on screen
        /// is now the file's real order — and what Save writes.
        func keepSortedOrder() {
            guard let dt = tableView, let doc = document, !doc.csvSortKeys.isEmpty else { return }
            let order = displayOrder
            doc.mutateCSV(actionName: "Keep Sorted Order") { rows in
                applyDisplayOrder(to: &rows, displayOrder: order)
            }
            doc.csvSortKeys = []
            rebuildDisplayOrder(in: doc)
            applySortIndicators()
            dt.reloadData()
        }

        // MARK: Row drag and drop
        //
        // Only drags this grid started are accepted — the source is checked, so
        // rows can't be dropped into another tab's table, where the selection
        // the move reads from would belong to a different document.

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int,
                       proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
            guard let dt = self.tableView,
                  (info.draggingSource as? RowDragSource)?.table === dt,
                  document?.csvSortKeys.isEmpty == true,
                  let range = dt.selectedRange else { return [] }
            tableView.setDropRow(row, dropOperation: .above)
            // Dropping the rows where they already are would move nothing.
            if row >= range.topRow && row <= range.bottomRow + 1 { return [] }
            return .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let dt = self.tableView,
                  (info.draggingSource as? RowDragSource)?.table === dt else { return false }
            return moveSelectedRows(toGap: row)
        }

        // MARK: Selection changes

        func selectionDidChange() {
            publishSelection()
            refreshSelectionDisplay()
        }

        /// Tells the document which csvRows the selection covers — what the
        /// status bar totals and the Table menu enables from.
        ///
        /// Selection lives in DISPLAY rows, so anything that changes which csvRow
        /// sits at a display row (a sort, Keep Sorted Order, an undo) changes what
        /// is selected without the selection moving. Republished from
        /// rebuildDisplayOrder for that reason: before 4.1 a sort left the status
        /// bar totalling the rows that had been there, not the ones on screen.
        private func publishSelection() {
            guard let dt = tableView, let doc = document else { return }
            // Publish only WHICH cells are selected, resolved to csvRows indices.
            // The arithmetic is derived in the status bar from the live cell
            // values, so it cannot go stale after an undo and nothing here has to
            // write a computed property back into the observed document.
            let blocks = selectionBlocks(for: dt.selectedRanges, displayOrder: displayOrder)
            if doc.csvSelectionBlocks != blocks { doc.csvSelectionBlocks = blocks }
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

            let isSelected  = tableView.isCellSelected(row: row, column: colIdx)
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
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            dt.selectColumn(column, extending: modifiers.contains(.shift),
                            adding: modifiers.contains(.command))
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
