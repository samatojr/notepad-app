import Foundation
import Testing
@testable import Notepad

// Tests for the pure grid layer behind v4's cell selection, copy/paste and
// column editing.
//
// The three mappings these lock down are the ones that will otherwise corrupt a
// file, because each is invisible in the UI until the data is already wrong:
//   * SORT — a visual rectangle is not a contiguous slice of csvRows.
//   * HEADERS — csvRows[0] is the header and displayOrder skips it, but a
//     column index addresses the header row like any other.
//   * RAGGED ROWS — rows may legally differ in length.

// MARK: - Fixtures

/// Builds rows from a literal grid.
private func makeRows(_ grid: [[String]]) -> [CSVRow] {
    grid.map { CSVRow(cells: $0) }
}

/// The cell contents, for comparing whole grids in one expectation.
private func cells(_ rows: [CSVRow]) -> [[String]] {
    rows.map(\.cells)
}

/// A header row plus three data rows, unsorted: displayOrder skips the header.
private let sampleGrid = [
    ["name",  "qty", "price"],   // header — csvRows[0]
    ["bolt",  "10",  "1.50"],    // csvRows[1], display 0
    ["nut",   "25",  "0.75"],    // csvRows[2], display 1
    ["washer", "5",  "0.25"],    // csvRows[3], display 2
]
private let unsortedOrder = [1, 2, 3]

// MARK: - GridRange

@MainActor
struct GridRangeTests {

    @Test("A range normalizes whichever corner the drag started from")
    func normalizesCorners() {
        let downRight = GridRange(anchorRow: 1, anchorColumn: 1, focusRow: 3, focusColumn: 4)
        let upLeft    = GridRange(anchorRow: 3, anchorColumn: 4, focusRow: 1, focusColumn: 1)
        #expect(downRight == upLeft)
        #expect(downRight.topRow == 1 && downRight.bottomRow == 3)
        #expect(downRight.leftColumn == 1 && downRight.rightColumn == 4)
    }

    @Test("A single cell is a 1x1 range")
    func singleCell() {
        let range = GridRange(anchorRow: 2, anchorColumn: 2, focusRow: 2, focusColumn: 2)
        #expect(range.rowCount == 1)
        #expect(range.columnCount == 1)
        #expect(!range.isEmpty)
    }

    @Test("Dimensions and membership")
    func dimensions() {
        let range = GridRange(topRow: 1, bottomRow: 3, leftColumn: 0, rightColumn: 2)
        #expect(range.rowCount == 3)
        #expect(range.columnCount == 3)
        #expect(range.contains(row: 2, column: 1))
        #expect(!range.contains(row: 0, column: 1))
        #expect(!range.contains(row: 2, column: 3))
    }

    @Test("A selection that outlived a delete clamps instead of addressing missing cells")
    func clampsToGrid() {
        let stale = GridRange(topRow: 0, bottomRow: 99, leftColumn: 0, rightColumn: 99)
        let clamped = stale.clamped(rowCount: 3, columnCount: 2)
        #expect(clamped == GridRange(topRow: 0, bottomRow: 2, leftColumn: 0, rightColumn: 1))
    }

    @Test("Clamping to an empty grid yields no range at all")
    func clampToEmpty() {
        let range = GridRange(topRow: 0, bottomRow: 2, leftColumn: 0, rightColumn: 2)
        #expect(range.clamped(rowCount: 0, columnCount: 0) == nil)
        #expect(range.clamped(rowCount: 3, columnCount: 0) == nil)
    }
}

// MARK: - Reading a selection

@MainActor
struct GridCellsTests {

    @Test("Reads the block the range covers, skipping the header row")
    func readsBlock() {
        let rows = makeRows(sampleGrid)
        let range = GridRange(topRow: 0, bottomRow: 1, leftColumn: 0, rightColumn: 1)
        #expect(gridCells(from: rows, range: range, displayOrder: unsortedOrder)
                == [["bolt", "10"], ["nut", "25"]])
    }

    @Test("A whole column is just a range one column wide")
    func wholeColumn() {
        let rows = makeRows(sampleGrid)
        let range = GridRange(topRow: 0, bottomRow: 2, leftColumn: 1, rightColumn: 1)
        #expect(gridCells(from: rows, range: range, displayOrder: unsortedOrder)
                == [["10"], ["25"], ["5"]])
    }

    // The mapping that matters most: under a sort the visual rectangle is not a
    // contiguous slice of csvRows, so copy has to read THROUGH displayOrder.
    @Test("Copying from a sorted grid takes the rows as displayed, not as stored")
    func readsThroughSort() {
        let rows = makeRows(sampleGrid)
        // Sorted by qty ascending: washer(5), bolt(10), nut(25).
        let sorted = [3, 1, 2]
        let range = GridRange(topRow: 0, bottomRow: 2, leftColumn: 0, rightColumn: 0)
        #expect(gridCells(from: rows, range: range, displayOrder: sorted)
                == [["washer"], ["bolt"], ["nut"]])
    }

    @Test("Ragged rows read as rectangular, padded with empties")
    func raggedReadsRectangular() {
        let rows = makeRows([["h1", "h2", "h3"], ["a"], ["b", "c", "d"]])
        let range = GridRange(topRow: 0, bottomRow: 1, leftColumn: 0, rightColumn: 2)
        // The short row must not shift its neighbours left.
        #expect(gridCells(from: rows, range: range, displayOrder: [1, 2])
                == [["a", "", ""], ["b", "c", "d"]])
    }

    @Test("An empty range reads nothing")
    func emptyRange() {
        let rows = makeRows(sampleGrid)
        let range = GridRange(topRow: 0, bottomRow: -1, leftColumn: 0, rightColumn: 0)
        #expect(gridCells(from: rows, range: range, displayOrder: unsortedOrder).isEmpty)
    }

    @Test("Display rows past the end are skipped rather than crashing")
    func pastEndSkipped() {
        let rows = makeRows(sampleGrid)
        let range = GridRange(topRow: 1, bottomRow: 50, leftColumn: 0, rightColumn: 0)
        #expect(gridCells(from: rows, range: range, displayOrder: unsortedOrder)
                == [["nut"], ["washer"]])
    }
}

// MARK: - Paste

@MainActor
struct PasteGridTests {

    @Test("Pastes a block at the anchor cell")
    func pastesAtAnchor() {
        var rows = makeRows(sampleGrid)
        pasteGrid([["X", "Y"]], into: &rows, atRow: 0, column: 0, displayOrder: unsortedOrder)
        #expect(cells(rows)[1] == ["X", "Y", "1.50"])
        #expect(cells(rows)[0] == ["name", "qty", "price"])   // header untouched
    }

    // Pasting at display row 0 must hit the first DATA row. If it ever writes to
    // csvRows[0] the user's column titles are silently replaced by data.
    @Test("A paste can never overwrite the header row")
    func headerIsUnreachable() {
        var rows = makeRows(sampleGrid)
        pasteGrid([["A", "B", "C"], ["D", "E", "F"]],
                  into: &rows, atRow: 0, column: 0, displayOrder: unsortedOrder)
        #expect(cells(rows)[0] == ["name", "qty", "price"])
    }

    @Test("Pasting into a sorted grid writes to the rows that were on screen")
    func writesThroughSort() {
        var rows = makeRows(sampleGrid)
        let sorted = [3, 1, 2]        // washer, bolt, nut
        // Overwrite the FIRST DISPLAYED row, which is stored at csvRows[3].
        pasteGrid([["SCREW"]], into: &rows, atRow: 0, column: 0, displayOrder: sorted)
        #expect(cells(rows)[3][0] == "SCREW")
        #expect(cells(rows)[1][0] == "bolt")    // untouched
        #expect(cells(rows)[2][0] == "nut")
    }

    @Test("A paste taller than the grid grows it instead of dropping the overflow")
    func growsRows() {
        var rows = makeRows(sampleGrid)
        pasteGrid([["a"], ["b"], ["c"], ["d"], ["e"]],
                  into: &rows, atRow: 0, column: 0, displayOrder: unsortedOrder)
        // 1 header + 3 existing + 2 appended.
        #expect(rows.count == 6)
        #expect(cells(rows)[4] == ["d"])
        #expect(cells(rows)[5] == ["e"])
    }

    @Test("A paste wider than the grid grows the rows it lands in")
    func growsColumns() {
        var rows = makeRows(sampleGrid)
        pasteGrid([["p", "q", "r"]], into: &rows, atRow: 0, column: 2, displayOrder: unsortedOrder)
        #expect(cells(rows)[1] == ["bolt", "10", "p", "q", "r"])
    }

    @Test("Pasting past the right edge pads the gap with empties")
    func padsGap() {
        var rows = makeRows(sampleGrid)
        pasteGrid([["z"]], into: &rows, atRow: 0, column: 5, displayOrder: unsortedOrder)
        #expect(cells(rows)[1] == ["bolt", "10", "1.50", "", "", "z"])
    }

    @Test("An empty clipboard changes nothing")
    func emptyClipboardIsNoOp() {
        var rows = makeRows(sampleGrid)
        let before = cells(rows)
        pasteGrid([], into: &rows, atRow: 0, column: 0, displayOrder: unsortedOrder)
        #expect(cells(rows) == before)
    }

    @Test("A negative anchor is refused rather than trapping")
    func negativeAnchorIsNoOp() {
        var rows = makeRows(sampleGrid)
        let before = cells(rows)
        pasteGrid([["x"]], into: &rows, atRow: -1, column: 0, displayOrder: unsortedOrder)
        pasteGrid([["x"]], into: &rows, atRow: 0, column: -1, displayOrder: unsortedOrder)
        #expect(cells(rows) == before)
    }

    // The property that protects the file end to end: copying a block and
    // pasting it back where it came from must leave the grid untouched.
    @Test("Copy then paste in place is a no-op", arguments: [
        GridRange(topRow: 0, bottomRow: 2, leftColumn: 0, rightColumn: 2),
        GridRange(topRow: 1, bottomRow: 2, leftColumn: 1, rightColumn: 2),
        GridRange(topRow: 0, bottomRow: 0, leftColumn: 0, rightColumn: 0),
    ])
    func copyPasteInPlaceIsIdentity(range: GridRange) {
        var rows = makeRows(sampleGrid)
        let before = cells(rows)
        let copied = gridCells(from: rows, range: range, displayOrder: unsortedOrder)
        pasteGrid(copied, into: &rows,
                  atRow: range.topRow, column: range.leftColumn, displayOrder: unsortedOrder)
        #expect(cells(rows) == before)
    }

    @Test("Copy then paste in place is a no-op under a sort too")
    func copyPasteInPlaceUnderSort() {
        var rows = makeRows(sampleGrid)
        let sorted = [3, 1, 2]
        let before = cells(rows)
        let range = GridRange(topRow: 0, bottomRow: 2, leftColumn: 0, rightColumn: 2)
        let copied = gridCells(from: rows, range: range, displayOrder: sorted)
        pasteGrid(copied, into: &rows, atRow: 0, column: 0, displayOrder: sorted)
        #expect(cells(rows) == before)
    }

    @Test("Moving a column's values via copy/paste lands them intact")
    func moveValuesBetweenColumns() {
        var rows = makeRows(sampleGrid)
        let source = GridRange(topRow: 0, bottomRow: 2, leftColumn: 1, rightColumn: 1)
        let copied = gridCells(from: rows, range: source, displayOrder: unsortedOrder)
        pasteGrid(copied, into: &rows, atRow: 0, column: 3, displayOrder: unsortedOrder)
        #expect(cells(rows)[1] == ["bolt", "10", "1.50", "10"])
        #expect(cells(rows)[2] == ["nut", "25", "0.75", "25"])
        #expect(cells(rows)[3] == ["washer", "5", "0.25", "5"])
    }
}

// MARK: - Cut / clear

@MainActor
struct ClearCellsTests {

    @Test("Clearing blanks the cells in place without moving anything")
    func blanksInPlace() {
        var rows = makeRows(sampleGrid)
        let range = GridRange(topRow: 0, bottomRow: 1, leftColumn: 1, rightColumn: 2)
        clearCells(in: &rows, range: range, displayOrder: unsortedOrder)
        #expect(cells(rows)[1] == ["bolt", "", ""])
        #expect(cells(rows)[2] == ["nut", "", ""])
        #expect(cells(rows)[3] == ["washer", "5", "0.25"])   // outside the range
        #expect(cells(rows)[0] == ["name", "qty", "price"])  // header safe
    }

    @Test("Clearing follows the sort")
    func clearsThroughSort() {
        var rows = makeRows(sampleGrid)
        clearCells(in: &rows,
                   range: GridRange(topRow: 0, bottomRow: 0, leftColumn: 0, rightColumn: 0),
                   displayOrder: [3, 1, 2])
        #expect(cells(rows)[3][0] == "")      // washer was displayed first
        #expect(cells(rows)[1][0] == "bolt")
    }

    @Test("Clearing past a short row's end does not extend it")
    func doesNotExtendShortRows() {
        var rows = makeRows([["h1", "h2", "h3"], ["a"]])
        clearCells(in: &rows,
                   range: GridRange(topRow: 0, bottomRow: 0, leftColumn: 0, rightColumn: 2),
                   displayOrder: [1])
        #expect(cells(rows)[1] == [""])
    }
}

// MARK: - Column structure

@MainActor
struct ColumnStructureTests {

    // A column index addresses the same slot in every row INCLUDING the header.
    // A header left behind would put every title one column out of step.
    @Test("Insert adds the column to the header row as well as the data")
    func insertHitsHeader() {
        var rows = makeRows(sampleGrid)
        insertColumn(in: &rows, at: 1)
        #expect(cells(rows)[0] == ["name", "", "qty", "price"])
        #expect(cells(rows)[1] == ["bolt", "", "10", "1.50"])
        #expect(cells(rows)[3] == ["washer", "", "5", "0.25"])
    }

    @Test("Insert at the right edge appends")
    func insertAtEnd() {
        var rows = makeRows(sampleGrid)
        insertColumn(in: &rows, at: 3)
        #expect(cells(rows)[0] == ["name", "qty", "price", ""])
    }

    @Test("Insert past the right edge appends rather than padding out to meet it")
    func insertPastEnd() {
        var rows = makeRows(sampleGrid)
        insertColumn(in: &rows, at: 40)
        #expect(cells(rows)[0].count == 4)
        #expect(cells(rows)[0] == ["name", "qty", "price", ""])
    }

    @Test("Insert squares off a ragged grid so every row gains the column")
    func insertSquaresRaggedGrid() {
        var rows = makeRows([["h1", "h2", "h3"], ["a"], ["b", "c"]])
        insertColumn(in: &rows, at: 1)
        #expect(cells(rows) == [["h1", "", "h2", "h3"],
                                ["a",  "", "",   ""],
                                ["b",  "", "c",  ""]])
    }

    @Test("Delete removes the column from the header row too")
    func deleteHitsHeader() {
        var rows = makeRows(sampleGrid)
        deleteColumns(in: &rows, at: IndexSet(integer: 1))
        #expect(cells(rows)[0] == ["name", "price"])
        #expect(cells(rows)[1] == ["bolt", "1.50"])
    }

    @Test("Deleting several columns at once removes exactly those")
    func deleteMultiple() {
        var rows = makeRows([["a", "b", "c", "d", "e"], ["1", "2", "3", "4", "5"]])
        deleteColumns(in: &rows, at: IndexSet([1, 3]))
        #expect(cells(rows) == [["a", "c", "e"], ["1", "3", "5"]])
    }

    @Test("Deleting every column empties the grid rather than leaving hollow rows")
    func deleteAllColumns() {
        var rows = makeRows([["a", "b"], ["1", "2"]])
        deleteColumns(in: &rows, at: IndexSet([0, 1]))
        #expect(rows.isEmpty)
    }

    @Test("Deleting a column a short row never had still aligns the rest")
    func deleteFromRaggedGrid() {
        var rows = makeRows([["h1", "h2", "h3"], ["a"], ["b", "c", "d"]])
        deleteColumns(in: &rows, at: IndexSet(integer: 1))
        // Without squaring off first, the short row would keep "a" while every
        // other row shifted — silently misaligning the file.
        #expect(cells(rows) == [["h1", "h3"], ["a", ""], ["b", "d"]])
    }

    @Test("Out-of-range delete indices are ignored")
    func deleteOutOfRange() {
        var rows = makeRows([["a", "b"], ["1", "2"]])
        deleteColumns(in: &rows, at: IndexSet([5, 9]))
        #expect(cells(rows) == [["a", "b"], ["1", "2"]])
    }

    @Test("Move carries the header along with its data")
    func moveCarriesHeader() {
        var rows = makeRows(sampleGrid)
        moveColumn(in: &rows, from: 2, to: 0)       // price to the front
        #expect(cells(rows)[0] == ["price", "name", "qty"])
        #expect(cells(rows)[1] == ["1.50", "bolt", "10"])
        #expect(cells(rows)[3] == ["0.25", "washer", "5"])
    }

    @Test("Move to the right shifts the columns in between back")
    func moveRight() {
        var rows = makeRows([["a", "b", "c", "d"]])
        moveColumn(in: &rows, from: 0, to: 2)
        #expect(cells(rows)[0] == ["b", "c", "a", "d"])
    }

    @Test("Moving a column onto itself changes nothing")
    func moveToSelfIsNoOp() {
        var rows = makeRows(sampleGrid)
        let before = cells(rows)
        moveColumn(in: &rows, from: 1, to: 1)
        #expect(cells(rows) == before)
    }

    @Test("A move addressing a column that does not exist changes nothing at all")
    func moveOutOfRangeIsNoOp() {
        var rows = makeRows(sampleGrid)
        let before = cells(rows)
        moveColumn(in: &rows, from: 0, to: 99)
        moveColumn(in: &rows, from: 99, to: 0)
        // Not even the padding should have happened.
        #expect(cells(rows) == before)
    }

    @Test("Moving a column and moving it back is a round trip")
    func moveRoundTrip() {
        var rows = makeRows(sampleGrid)
        let before = cells(rows)
        moveColumn(in: &rows, from: 0, to: 2)
        moveColumn(in: &rows, from: 2, to: 0)
        #expect(cells(rows) == before)
    }

    @Test("Column operations on an empty grid are safe")
    func emptyGridIsSafe() {
        var rows: [CSVRow] = []
        insertColumn(in: &rows, at: 0)
        deleteColumns(in: &rows, at: IndexSet(integer: 0))
        moveColumn(in: &rows, from: 0, to: 1)
        #expect(rows.isEmpty)
    }
}

// MARK: - Selection summary

@MainActor
struct SelectionSummaryTests {

    @Test("Counts cells, filled cells and numbers separately")
    func counts() {
        let summary = summarize([["1", "2", ""], ["3", "text", "4"]])
        #expect(summary.cellCount == 6)
        #expect(summary.filledCount == 5)
        #expect(summary.numericCount == 4)
    }

    @Test("Sums, averages and bounds the numeric cells")
    func arithmetic() {
        let summary = summarize([["10"], ["20"], ["30"]])
        #expect(summary.sum == 60)
        #expect(summary.average == 20)
        #expect(summary.minimum == 10)
        #expect(summary.maximum == 30)
    }

    @Test("Non-numeric cells are counted but excluded from the arithmetic")
    func ignoresText() {
        let summary = summarize([["10"], ["n/a"], ["20"]])
        #expect(summary.sum == 30)
        #expect(summary.numericCount == 2)
        #expect(summary.average == 15)
    }

    @Test("A selection with no numbers reports no arithmetic at all")
    func noNumbers() {
        let summary = summarize([["alpha"], ["bravo"]])
        #expect(!summary.hasNumbers)
        #expect(summary.average == nil)
        #expect(summary.minimum == nil)
        #expect(summary.sum == 0)
    }

    @Test("Spreadsheet formats total correctly, and accounting parentheses subtract")
    func spreadsheetFormats() {
        let summary = summarize([["$1,200.00"], ["(200.00)"], ["50"]])
        #expect(summary.numericCount == 3)
        #expect(summary.sum == 1050)       // 1200 - 200 + 50
        #expect(summary.minimum == -200)
    }

    @Test("An empty selection summarizes to nothing")
    func emptySelection() {
        let summary = summarize([])
        #expect(summary.cellCount == 0)
        #expect(!summary.hasNumbers)
    }

    // The status bar must total exactly the cells the grid right-aligns, or a
    // column that displays as numeric but refuses to add up becomes a bug report.
    @Test("What summarize counts is exactly what looksNumeric accepts", arguments: [
        "1", "0", "-3", "3.14", "$1,200.00", "12%", "(1,200.00)",
        "01234", "n/a", "", "abc", "1.2.3",
    ])
    func agreesWithAlignmentInference(value: String) {
        let countedByStatusBar = summarize([[value]]).numericCount == 1
        #expect(countedByStatusBar == looksNumeric(value))
    }
}

// MARK: - Numeric value extraction

@MainActor
struct NumericValueTests {

    @Test("Plain and formatted numbers parse to their value", arguments: [
        ("42", 42.0), ("-3", -3.0), ("3.14", 3.14),
        ("$1,200.00", 1200.0), ("1,000,000", 1000000.0), ("12%", 12.0),
    ])
    func parsesValues(value: String, expected: Double) {
        #expect(numericValue(value) == expected)
    }

    @Test("Accounting parentheses mean negative")
    func parenthesesNegate() {
        #expect(numericValue("(1,200.00)") == -1200)
        #expect(numericValue("(50)") == -50)
    }

    @Test("A percent keeps its face value rather than being divided by 100")
    func percentKeepsMagnitude() {
        // The status bar totals what is on screen: 12% and 8% read as 20.
        #expect(numericValue("12%") == 12)
    }

    @Test("Non-numbers yield nil", arguments: ["", "abc", "01234", "1.2.3", "-", "$"])
    func rejectsNonNumbers(value: String) {
        #expect(numericValue(value) == nil)
    }
}
