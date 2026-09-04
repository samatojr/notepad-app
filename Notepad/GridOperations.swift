import Foundation

// MARK: - Grid operations
//
// The pure core behind v4's grid editing. Everything here is a plain function
// over `[CSVRow]` with no AppKit and no view state, so the parts that can
// corrupt a file are testable without a table on screen.
//
// Two coordinate systems meet in this file, and mixing them up is how the grid
// eats data:
//
//   * DISPLAY rows are what the table shows. `displayOrder[displayRow]` gives
//     the index into `csvRows`. It reflects the current sort and it already
//     excludes the header row, so display row 0 is the first DATA row and the
//     header can never be overwritten by a paste.
//   * COLUMN indices are direct indices into `CSVRow.cells`. Sorting reorders
//     rows, never columns, so a column index means the same thing everywhere —
//     including in the header row, which is why the structural column
//     operations below take the whole `rows` array, header included.

// MARK: - Selection

/// A rectangular block of cells in DISPLAY coordinates, all bounds inclusive.
nonisolated struct GridRange: Equatable, Sendable {
    var topRow: Int
    var bottomRow: Int
    var leftColumn: Int
    var rightColumn: Int

    /// Builds a range from two corners in any order — the anchor cell the user
    /// clicked first and wherever they dragged or shift-clicked to.
    init(anchorRow: Int, anchorColumn: Int, focusRow: Int, focusColumn: Int) {
        topRow      = min(anchorRow, focusRow)
        bottomRow   = max(anchorRow, focusRow)
        leftColumn  = min(anchorColumn, focusColumn)
        rightColumn = max(anchorColumn, focusColumn)
    }

    init(topRow: Int, bottomRow: Int, leftColumn: Int, rightColumn: Int) {
        self.topRow      = topRow
        self.bottomRow   = bottomRow
        self.leftColumn  = leftColumn
        self.rightColumn = rightColumn
    }

    var rowCount: Int    { max(0, bottomRow - topRow + 1) }
    var columnCount: Int { max(0, rightColumn - leftColumn + 1) }
    var isEmpty: Bool    { rowCount == 0 || columnCount == 0 }

    func contains(row: Int, column: Int) -> Bool {
        row >= topRow && row <= bottomRow && column >= leftColumn && column <= rightColumn
    }

    /// Clamps to a grid of the given size, so a selection that outlived a delete
    /// can't address cells that are no longer there.
    func clamped(rowCount rows: Int, columnCount columns: Int) -> GridRange? {
        guard rows > 0, columns > 0 else { return nil }
        let top    = max(0, min(topRow, rows - 1))
        let bottom = max(0, min(bottomRow, rows - 1))
        let left   = max(0, min(leftColumn, columns - 1))
        let right  = max(0, min(rightColumn, columns - 1))
        guard top <= bottom, left <= right else { return nil }
        return GridRange(topRow: top, bottomRow: bottom, leftColumn: left, rightColumn: right)
    }
}

// MARK: - Reading a selection

/// The cells covered by `range`, as a rectangular grid of strings.
///
/// Always rectangular even over ragged rows: a row too short to reach a column
/// contributes an empty string there. Copying a ragged block and pasting it
/// back must not shift anything sideways.
nonisolated func gridCells(from rows: [CSVRow],
                           range: GridRange,
                           displayOrder: [Int]) -> [[String]] {
    guard !range.isEmpty else { return [] }
    var result: [[String]] = []
    result.reserveCapacity(range.rowCount)

    for displayRow in range.topRow...range.bottomRow {
        guard displayOrder.indices.contains(displayRow) else { continue }
        let csvIndex = displayOrder[displayRow]
        guard rows.indices.contains(csvIndex) else { continue }
        let cells = rows[csvIndex].cells
        var line: [String] = []
        line.reserveCapacity(range.columnCount)
        for column in range.leftColumn...range.rightColumn {
            line.append(column < cells.count ? cells[column] : "")
        }
        result.append(line)
    }
    return result
}

// MARK: - Writing a selection

/// Writes `grid` into `rows` with its top-left cell at the given display row and
/// column, growing the grid rather than dropping the overflow — a 100-row paste
/// into a 10-row file must not lose 90 rows.
///
/// Rows that run past the end of `displayOrder` are appended to `rows`. That is
/// deliberate: under a sort there is no meaningful "next row" to overwrite, so
/// new content goes to the end of the file where the sort will place it on the
/// next rebuild.
nonisolated func pasteGrid(_ grid: [[String]],
                           into rows: inout [CSVRow],
                           atRow anchorRow: Int,
                           column anchorColumn: Int,
                           displayOrder: [Int]) {
    guard !grid.isEmpty, anchorRow >= 0, anchorColumn >= 0 else { return }

    for (rowOffset, line) in grid.enumerated() {
        let targetDisplayRow = anchorRow + rowOffset

        let csvIndex: Int
        if displayOrder.indices.contains(targetDisplayRow) {
            csvIndex = displayOrder[targetDisplayRow]
        } else {
            rows.append(CSVRow(cells: []))
            csvIndex = rows.count - 1
        }
        guard rows.indices.contains(csvIndex) else { continue }

        for (columnOffset, value) in line.enumerated() {
            let targetColumn = anchorColumn + columnOffset
            padRow(&rows[csvIndex], toReach: targetColumn)
            rows[csvIndex].cells[targetColumn] = value
        }
    }
}

/// Blanks every cell in `range` — the second half of Cut. Cells are emptied in
/// place rather than removed, so the rows around them keep their shape.
nonisolated func clearCells(in rows: inout [CSVRow],
                           range: GridRange,
                           displayOrder: [Int]) {
    guard !range.isEmpty else { return }
    for displayRow in range.topRow...range.bottomRow {
        guard displayOrder.indices.contains(displayRow) else { continue }
        let csvIndex = displayOrder[displayRow]
        guard rows.indices.contains(csvIndex) else { continue }
        for column in range.leftColumn...range.rightColumn
        where column < rows[csvIndex].cells.count {
            rows[csvIndex].cells[column] = ""
        }
    }
}

// MARK: - Structural column operations
//
// These take the WHOLE rows array, header included: a column index addresses
// the same slot in every row, so a header left behind after a delete would
// shift every title one column out of step with its data.
//
// Each one squares the grid off first. A structural column change on a ragged
// grid is otherwise incoherent — deleting column 3 would do nothing to a
// two-cell row while every other row shifts left, silently misaligning the file.

/// Inserts a blank column at `index`, moving that column and everything right
/// of it one place over.
nonisolated func insertColumn(in rows: inout [CSVRow], at index: Int) {
    guard index >= 0, !rows.isEmpty else { return }
    padToRectangular(&rows)
    // An index past the right edge appends rather than padding out to meet it —
    // "insert at column 40" in a 3-column grid means a fourth column, not a
    // fortieth with 36 blanks in front of it.
    let target = min(index, rows[0].cells.count)
    for i in rows.indices {
        rows[i].cells.insert("", at: target)
    }
}

/// Removes the given columns. Removing every column leaves an empty grid rather
/// than a set of zero-width rows.
nonisolated func deleteColumns(in rows: inout [CSVRow], at indices: IndexSet) {
    guard !indices.isEmpty, !rows.isEmpty else { return }
    padToRectangular(&rows)
    let width = rows[0].cells.count
    let doomed = indices.filteredIndexSet { $0 >= 0 && $0 < width }
    guard !doomed.isEmpty else { return }

    if doomed.count >= width { rows.removeAll(); return }
    // Filtered by hand rather than with remove(atOffsets:) — that one comes from
    // SwiftUI, and this file stays on Foundation so the logic can be exercised
    // without dragging a UI framework in behind it.
    for i in rows.indices {
        var kept: [String] = []
        kept.reserveCapacity(rows[i].cells.count - doomed.count)
        for (column, value) in rows[i].cells.enumerated() where !doomed.contains(column) {
            kept.append(value)
        }
        rows[i].cells = kept
    }
}

/// Moves the column at `source` so it lands at `destination`, shifting the
/// columns in between. Destination is interpreted after the source is lifted
/// out, which is how a drag reads to the person doing it.
nonisolated func moveColumn(in rows: inout [CSVRow], from source: Int, to destination: Int) {
    guard source != destination, source >= 0, destination >= 0, !rows.isEmpty else { return }
    // Bounds are checked against the widest row BEFORE squaring the grid off, so
    // a move that addresses a column which does not exist changes nothing at all
    // rather than padding the file on its way to doing nothing.
    let width = rows.map(\.cells.count).max() ?? 0
    guard source < width, destination < width else { return }
    padToRectangular(&rows)
    for i in rows.indices {
        let value = rows[i].cells.remove(at: source)
        rows[i].cells.insert(value, at: destination)
    }
}

// MARK: - Selection summary

/// What the status bar reports for the current selection. Mirrors a
/// spreadsheet's: how much is selected, and the arithmetic over whatever part
/// of it is numeric.
nonisolated struct SelectionSummary: Equatable, Sendable {
    var cellCount: Int = 0        // cells in the selection, empty ones included
    var filledCount: Int = 0      // cells holding something
    var numericCount: Int = 0
    var sum: Double = 0
    var average: Double?
    var minimum: Double?
    var maximum: Double?

    var hasNumbers: Bool { numericCount > 0 }
}

/// Summarizes a block of cells. Numeric recognition is shared with column
/// alignment inference, so the status bar counts exactly the cells the grid
/// already treats as numbers — a column that displays right-aligned always adds
/// up here.
nonisolated func summarize(_ cells: [[String]]) -> SelectionSummary {
    var summary = SelectionSummary()
    var minimum: Double?
    var maximum: Double?

    for line in cells {
        for cell in line {
            summary.cellCount += 1
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            summary.filledCount += 1
            guard let value = numericValue(trimmed) else { continue }
            summary.numericCount += 1
            summary.sum += value
            minimum = minimum.map { Swift.min($0, value) } ?? value
            maximum = maximum.map { Swift.max($0, value) } ?? value
        }
    }

    if summary.numericCount > 0 {
        summary.average = summary.sum / Double(summary.numericCount)
        summary.minimum = minimum
        summary.maximum = maximum
    }
    return summary
}

// MARK: - Shape helpers

/// Grows one row so `column` is a valid index in it.
private nonisolated func padRow(_ row: inout CSVRow, toReach column: Int) {
    guard column >= row.cells.count else { return }
    row.cells.append(contentsOf: Array(repeating: "", count: column - row.cells.count + 1))
}

/// Pads every row out to the widest one, so a structural column operation acts
/// on the same slot in each. `minimumColumns` widens the target further when the
/// operation addresses a column past the current right edge.
private nonisolated func padToRectangular(_ rows: inout [CSVRow]) {
    let width = rows.map(\.cells.count).max() ?? 0
    guard width > 0 else { return }
    for i in rows.indices where rows[i].cells.count < width {
        rows[i].cells.append(contentsOf: Array(
            repeating: "", count: width - rows[i].cells.count))
    }
}
