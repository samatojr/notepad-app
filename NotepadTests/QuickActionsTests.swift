import Foundation
import Testing
@testable import Notepad

// Tests for 4.1's quick actions. Every one of these writes into the user's
// file, so the cases that matter most are the ones that would corrupt it
// quietly: a moved header, a total that double-counts itself on a second run,
// a sum that loses its decimals, a split that eats the original column.

// MARK: - Fixtures

private func makeRows(_ grid: [[String]]) -> [CSVRow] {
    grid.map { CSVRow(cells: $0) }
}

private func cells(_ rows: [CSVRow]) -> [[String]] {
    rows.map(\.cells)
}

/// A header plus five data rows, unsorted — display row n is csvRows[n + 1].
private let letters = [["id"], ["a"], ["b"], ["c"], ["d"], ["e"]]
private let lettersOrder = [1, 2, 3, 4, 5]

private func column(_ rows: [CSVRow], _ index: Int) -> [String] {
    rows.map { index < $0.cells.count ? $0.cells[index] : "" }
}

// MARK: - Number formatting

@MainActor
struct NumberFormattingTests {

    @Test("Copied numbers are exact but free of binary noise")
    func plainIsExact() {
        #expect(plainNumberString(0.1 + 0.2) == "0.3")
        #expect(plainNumberString(1_234_567.5) == "1234567.5")
        #expect(plainNumberString(1234.567) == "1234.567")
        #expect(plainNumberString(3) == "3")
        #expect(plainNumberString(-2.5) == "-2.5")
    }

    @Test("Copied numbers never use exponents or grouping")
    func plainHasNoExponent() {
        #expect(plainNumberString(1e20) == "100000000000000000000")
        #expect(plainNumberString(0.000001) == "0.000001")
        #expect(!plainNumberString(9_876_543.21).contains(","))
    }

    @Test("A total that cancels out reads 0, not -0")
    func noNegativeZero() {
        #expect(plainNumberString(-0.0) == "0")
        #expect(plainNumberString(0.1 - 0.1) == "0")
    }

    @Test("Statistics round to the selection's own decimals; averages get two")
    func statisticRounding() {
        let money = summarize([["$1.50"], ["$0.75"], ["$2.35"]])
        #expect(money.decimalPlaces == 2)
        #expect(money.formatted(money.sum, grouped: true) == "4.60")
        #expect(money.formatted(money.average!, isAverage: true, grouped: true) == "1.53")

        // The first 4.1 build showed this average as "22.558333".
        let mixed = summarize([["0.25", "5"], ["0.10", "120"], ["2.00", "8"]])
        #expect(mixed.formatted(mixed.average!, isAverage: true, grouped: true) == "22.56")

        let whole = summarize([["10"], ["25"]])
        #expect(whole.formatted(whole.sum, grouped: true) == "35")
        #expect(whole.formatted(whole.average!, isAverage: true, grouped: true) == "17.5")
    }

    @Test("What is copied is what is shown, minus the thousands separators")
    func copiedMatchesShown() {
        let summary = summarize([["1,234,567.5"], ["1"]])
        // The v4.0 status bar showed this one as "1.23457e+06".
        #expect(summary.formatted(summary.sum, grouped: true) == "1,234,568.5")
        #expect(summary.formatted(summary.sum, grouped: false) == "1234568.5")
        #expect(numericValue(summary.formatted(summary.sum, grouped: false)) == 1_234_568.5)
    }

    @Test("A column's style carries over: decimals, currency, grouping, percent")
    func styleSampling() {
        #expect(NumberStyle(sampling: ["$1.50", "$0.75"]).format(2.25) == "$2.25")
        #expect(NumberStyle(sampling: ["1,200", "3"]).format(4500) == "4,500")
        #expect(NumberStyle(sampling: ["10%", "5%"]).format(15) == "15%")
        #expect(NumberStyle(sampling: ["1.5", "2"]).format(3.5) == "3.5")
        #expect(NumberStyle(sampling: ["1.5", "2.25"]).format(3.75) == "3.75")
    }

    @Test("A symbol only carries over when every cell has it")
    func mixedSymbols() {
        #expect(NumberStyle(sampling: ["$5", "6"]).format(11) == "11")
        #expect(NumberStyle(sampling: ["$5", "€6"]).format(11) == "11")
        #expect(NumberStyle(sampling: ["10%", "5"]).format(15) == "15")
    }

    @Test("Negative money is written the way it reads back")
    func negativeMoney() {
        let written = NumberStyle(sampling: ["$5.00"]).format(-12.5)
        #expect(written == "-$12.50")
        #expect(numericValue(written) == -12.5)
        #expect(numericValue("+$3") == 3)
        #expect(numericValue("$-3") == -3)   // the older spelling still works
    }
}

// MARK: - Moving rows

@MainActor
struct MoveRowsTests {

    @Test("Moving a row down lands it in front of the gap")
    func moveDown() {
        var rows = makeRows(letters)
        // Drag "a" (display 0) to above "d" (display 3).
        let moved = moveRows(in: &rows, displayRows: 0...0, toGap: 3, displayOrder: lettersOrder)
        #expect(column(rows, 0) == ["id", "b", "c", "a", "d", "e"])
        #expect(moved == 2...2)
    }

    @Test("Moving a row up")
    func moveUp() {
        var rows = makeRows(letters)
        let moved = moveRows(in: &rows, displayRows: 3...3, toGap: 0, displayOrder: lettersOrder)
        #expect(column(rows, 0) == ["id", "d", "a", "b", "c", "e"])
        #expect(moved == 0...0)
    }

    @Test("A block of rows moves together, in order")
    func moveBlock() {
        var rows = makeRows(letters)
        let moved = moveRows(in: &rows, displayRows: 0...1, toGap: 5, displayOrder: lettersOrder)
        #expect(column(rows, 0) == ["id", "c", "d", "e", "a", "b"])
        #expect(moved == 3...4)
    }

    @Test("Moving to the very top never displaces the header")
    func headerStays() {
        var rows = makeRows(letters)
        moveRows(in: &rows, displayRows: 4...4, toGap: 0, displayOrder: lettersOrder)
        #expect(rows[0].cells == ["id"])
        #expect(column(rows, 0) == ["id", "e", "a", "b", "c", "d"])
    }

    @Test("Dropping a block onto itself or its own edges changes nothing",
          arguments: [1, 2, 3])
    func dropOnSelf(gap: Int) {
        var rows = makeRows(letters)
        let moved = moveRows(in: &rows, displayRows: 1...2, toGap: gap, displayOrder: lettersOrder)
        #expect(moved == nil)
        #expect(cells(rows) == letters)
    }

    @Test("A sorted grid refuses to move rows")
    func refusesSorted() {
        var rows = makeRows(letters)
        let moved = moveRows(in: &rows, displayRows: 0...0, toGap: 3, displayOrder: [5, 4, 3, 2, 1])
        #expect(moved == nil)
        #expect(cells(rows) == letters)
    }

    @Test("Without a header row, display row 0 is csvRows[0]")
    func noHeader() {
        var rows = makeRows([["a"], ["b"], ["c"]])
        moveRows(in: &rows, displayRows: 0...0, toGap: 3, displayOrder: [0, 1, 2])
        #expect(column(rows, 0) == ["b", "c", "a"])
    }

    @Test("Out-of-range moves are refused rather than trapping")
    func outOfRange() {
        var rows = makeRows(letters)
        #expect(moveRows(in: &rows, displayRows: 4...5, toGap: 0, displayOrder: lettersOrder) == nil)
        #expect(moveRows(in: &rows, displayRows: 0...0, toGap: 9, displayOrder: lettersOrder) == nil)
        #expect(cells(rows) == letters)
    }

    @Test("Keeping a sort writes the on-screen order into the file, header first")
    func applyOrder() {
        var rows = makeRows(letters)
        applyDisplayOrder(to: &rows, displayOrder: [3, 1, 5, 2, 4])
        #expect(column(rows, 0) == ["id", "c", "a", "e", "b", "d"])
    }

    @Test("A malformed display order leaves the file alone")
    func applyOrderRefusesDuplicates() {
        var rows = makeRows(letters)
        applyDisplayOrder(to: &rows, displayOrder: [1, 1, 2])
        #expect(cells(rows) == letters)
    }
}

// MARK: - Column math

private let invoice = [
    ["item",  "price",  "qty", "rate"],
    ["bolt",  "$1.50",  "10",  "8%"],
    ["nut",   "$0.75",  "4",   "8%"],
    ["note",  "n/a",    "2",   ""],
]

@MainActor
struct ColumnMathTests {

    @Test("Price × Qty keeps the price column's money format")
    func priceTimesQty() {
        var rows = makeRows(invoice)
        let calc = ColumnCalculation(left: 1, operation: .multiply, right: .column(2))
        insertCalculatedColumn(in: &rows, at: 4, title: "total", calculation: calc, headerRows: 1)
        #expect(column(rows, 4) == ["total", "$15.00", "$3.00", ""])
    }

    @Test("A percent operand is a fraction: price × rate is the tax")
    func percentIsFraction() {
        let calc = ColumnCalculation(left: 1, operation: .multiply, right: .column(3), decimalPlaces: 2)
        #expect(calc.value(for: invoice[1]) == "$0.12")
        #expect(operandNumber("8%") == 0.08)
        #expect(operandNumber("108%") == 1.08)
    }

    @Test("A typed number works as the right-hand side")
    func constant() {
        let calc = ColumnCalculation(left: 2, operation: .multiply, right: .number(1.5))
        #expect(calc.value(for: invoice[1]) == "15")
        #expect(calc.value(for: invoice[2]) == "6")
    }

    @Test("Automatic decimals never round a result that doesn't fit them")
    func automaticDecimals() {
        let halves = ColumnCalculation(left: 0, operation: .divide, right: .column(1))
        #expect(halves.value(for: ["10", "4"]) == "2.5")
        let tax = ColumnCalculation(left: 0, operation: .multiply, right: .number(1.08))
        #expect(tax.value(for: ["$19.99"]) == "$21.5892")
        let noise = ColumnCalculation(left: 0, operation: .multiply, right: .number(3))
        #expect(noise.value(for: ["1.1"]) == "3.3")
    }

    @Test("Fixed decimals round to exactly that many places")
    func fixedDecimals() {
        let tax = ColumnCalculation(left: 0, operation: .multiply, right: .number(1.08), decimalPlaces: 2)
        #expect(tax.value(for: ["$19.99"]) == "$21.59")
        let whole = ColumnCalculation(left: 0, operation: .add, right: .number(0), decimalPlaces: 2)
        #expect(whole.value(for: ["60"]) == "60.00")
    }

    @Test("Blank when a side isn't a number, or on division by zero")
    func blanks() {
        let calc = ColumnCalculation(left: 1, operation: .divide, right: .column(2))
        #expect(calc.value(for: ["x", "n/a", "2"]) == "")
        #expect(calc.value(for: ["x", "6", ""]) == "")
        #expect(calc.value(for: ["x", "6", "0"]) == "")
        #expect(calc.value(for: ["x"]) == "")          // short row
    }

    @Test("Subtracting into a negative writes readable negative money")
    func negativeResult() {
        let calc = ColumnCalculation(left: 0, operation: .subtract, right: .column(1))
        #expect(calc.value(for: ["$5.00", "$7.50"]) == "-$2.50")
    }

    @Test("Without a header row every row is data, and nothing is titled")
    func noHeader() {
        var rows = makeRows([["2", "3"], ["4", "5"]])
        let calc = ColumnCalculation(left: 0, operation: .add, right: .column(1))
        insertCalculatedColumn(in: &rows, at: 2, title: "sum", calculation: calc, headerRows: 0)
        #expect(cells(rows) == [["2", "3", "5"], ["4", "5", "9"]])
    }

    @Test("A column inserted in the middle computes from the columns as they were")
    func insertInMiddle() {
        var rows = makeRows([["a", "b"], ["2", "3"]])
        let calc = ColumnCalculation(left: 0, operation: .multiply, right: .column(1))
        insertCalculatedColumn(in: &rows, at: 1, title: "a×b", calculation: calc, headerRows: 1)
        #expect(cells(rows) == [["a", "a×b", "b"], ["2", "6", "3"]])
    }
}

// MARK: - Totals row

@MainActor
struct TotalsRowTests {

    @Test("Sums every all-number column, labels the first text column")
    func basic() {
        var rows = makeRows([
            ["item", "qty", "price"],
            ["bolt", "10",  "$1.50"],
            ["nut",  "25",  "$0.75"],
        ])
        appendTotalsRow(to: &rows, headerRows: 1)
        #expect(rows.last?.cells == ["Total", "35", "$2.25"])
        #expect(rows.count == 4)
    }

    @Test("A column with any text in it is not summed")
    func mixedColumnBlank() {
        let rows = makeRows([["n", "note"], ["1", "5"], ["2", "see below"]])
        #expect(totalsRow(for: rows, headerRows: 1) == ["3", "Total"])
    }

    @Test("Running it again refreshes the total instead of adding it in")
    func rerunReplaces() {
        var rows = makeRows([["item", "qty"], ["a", "1"], ["b", "2"]])
        appendTotalsRow(to: &rows, headerRows: 1)
        rows[1].cells[1] = "10"
        appendTotalsRow(to: &rows, headerRows: 1)
        #expect(rows.count == 4)
        #expect(rows.last?.cells == ["Total", "12"])
    }

    @Test("Keeps the column's decimals: 1.50 + 0.50 totals 2.00, not 2")
    func keepsDecimals() {
        let rows = makeRows([["x", "v"], ["a", "1.50"], ["b", "0.50"]])
        #expect(totalsRow(for: rows, headerRows: 1)[1] == "2.00")
    }

    @Test("Blank cells are skipped, not treated as text")
    func blanksIgnored() {
        let rows = makeRows([["x", "v"], ["a", "4"], ["b", ""], ["c", "6"]])
        #expect(totalsRow(for: rows, headerRows: 1) == ["Total", "10"])
    }

    @Test("Nothing to add up means no row is added")
    func nothingNumeric() {
        var rows = makeRows([["name"], ["a"], ["b"]])
        appendTotalsRow(to: &rows, headerRows: 1)
        #expect(rows.count == 3)
    }

    @Test("When every column is summed there is nowhere to put the label")
    func allNumeric() {
        let rows = makeRows([["1", "2"], ["3", "4"]])
        #expect(totalsRow(for: rows, headerRows: 0) == ["4", "6"])
    }
}

// MARK: - Fill series

@MainActor
struct FillSeriesTests {

    /// One column, the top cells filled in, the rest blank, no header.
    private func filled(_ seeds: [String], length: Int = 5,
                        mode: FillMode = .continuePatternOrCopy) -> [String] {
        var rows = makeRows((0..<length).map { $0 < seeds.count ? [seeds[$0]] : [""] })
        fillSeries(in: &rows,
                   range: GridRange(topRow: 0, bottomRow: length - 1, leftColumn: 0, rightColumn: 0),
                   displayOrder: Array(0..<length), mode: mode)
        return column(rows, 0)
    }

    @Test("Two numbers continue by their step")
    func numbers() {
        #expect(filled(["1", "2"]) == ["1", "2", "3", "4", "5"])
        #expect(filled(["5", "10"]) == ["5", "10", "15", "20", "25"])
        #expect(filled(["10", "8"]) == ["10", "8", "6", "4", "2"])
        #expect(filled(["0.5", "1.0"]) == ["0.5", "1.0", "1.5", "2.0", "2.5"])
        #expect(filled(["$1.00", "$1.25"], length: 3) == ["$1.00", "$1.25", "$1.50"])
    }

    @Test("Day and month names cycle, keeping their spelling and case")
    func names() {
        #expect(filled(["Mon", "Tue"]) == ["Mon", "Tue", "Wed", "Thu", "Fri"])
        #expect(filled(["Saturday", "Sunday"], length: 4) == ["Saturday", "Sunday", "Monday", "Tuesday"])
        #expect(filled(["JAN", "FEB"], length: 3) == ["JAN", "FEB", "MAR"])
        #expect(filled(["nov", "dec"], length: 4) == ["nov", "dec", "jan", "feb"])
        #expect(filled(["Jan", "Mar"], length: 4) == ["Jan", "Mar", "May", "Jul"])
    }

    @Test("A number inside text counts, padding and all")
    func numberedText() {
        #expect(filled(["Item 1", "Item 2"], length: 4) == ["Item 1", "Item 2", "Item 3", "Item 4"])
        #expect(filled(["Q1", "Q2"], length: 3) == ["Q1", "Q2", "Q3"])
        #expect(filled(["001", "002"], length: 4) == ["001", "002", "003", "004"])
        #expect(filled(["Room 9B", "Room 10B"], length: 3) == ["Room 9B", "Room 10B", "Room 11B"])
    }

    @Test("⌘D with no pattern copies the top cell down, as it always has")
    func copyWithoutPattern() {
        #expect(filled(["x", "y"], length: 3) == ["x", "x", "x"])
        #expect(filled(["7"], length: 3) == ["7", "7", "7"])
        #expect(filled(["1", "Mon"], length: 3) == ["1", "1", "1"])
    }

    @Test("⌘D on just two rows copies — there is nothing past the seeds to continue")
    func twoRowsCopies() {
        #expect(filled(["1", "2"], length: 2) == ["1", "1"])
    }

    @Test("Fill Series counts from one seed, or from 1 in an empty column")
    func seriesMode() {
        #expect(filled(["1"], length: 4, mode: .series) == ["1", "2", "3", "4"])
        #expect(filled([], length: 3, mode: .series) == ["1", "2", "3"])
        #expect(filled(["Mon"], length: 3, mode: .series) == ["Mon", "Tue", "Wed"])
        #expect(filled(["Step 4"], length: 3, mode: .series) == ["Step 4", "Step 5", "Step 6"])
        #expect(filled(["hello"], length: 3, mode: .series) == ["hello", "hello", "hello"])
    }

    @Test("Columns fill independently")
    func perColumn() {
        var rows = makeRows([["1", "Mon"], ["2", "Tue"], ["", ""], ["", ""]])
        fillSeries(in: &rows, range: GridRange(topRow: 0, bottomRow: 3, leftColumn: 0, rightColumn: 1),
                   displayOrder: [0, 1, 2, 3], mode: .continuePatternOrCopy)
        #expect(cells(rows) == [["1", "Mon"], ["2", "Tue"], ["3", "Wed"], ["4", "Thu"]])
    }

    @Test("Under a sort the fill follows the rows as displayed")
    func followsSort() {
        // Stored a, b, c; displayed c, b, a.
        var rows = makeRows([["h"], ["a"], ["b"], ["c"]])
        rows[3].cells = ["1"]; rows[2].cells = ["2"]; rows[1].cells = [""]
        fillSeries(in: &rows, range: GridRange(topRow: 0, bottomRow: 2, leftColumn: 0, rightColumn: 0),
                   displayOrder: [3, 2, 1], mode: .continuePatternOrCopy)
        #expect(cells(rows) == [["h"], ["3"], ["2"], ["1"]])
    }

    @Test("Filling never touches the header or anything outside the range")
    func staysInRange() {
        var rows = makeRows([["h", "h2"], ["1", "x"], ["2", "y"], ["", "z"]])
        fillSeries(in: &rows, range: GridRange(topRow: 0, bottomRow: 2, leftColumn: 0, rightColumn: 0),
                   displayOrder: [1, 2, 3], mode: .continuePatternOrCopy)
        #expect(cells(rows) == [["h", "h2"], ["1", "x"], ["2", "y"], ["3", "z"]])
    }
}

// MARK: - Text cleanup

@MainActor
struct TextCleanupTests {

    @Test("Trim removes edges, collapses runs, and normalizes web spaces")
    func trim() {
        #expect(TextTransform.trimSpaces.apply("  hello   world  ") == "hello world")
        #expect(TextTransform.trimSpaces.apply("\u{00A0}price\u{00A0}\u{00A0}list") == "price list")
        #expect(TextTransform.trimSpaces.apply("a\tb") == "a b")
        #expect(TextTransform.trimSpaces.apply("line one  \n  line two") == "line one\nline two")
    }

    @Test("Case changes")
    func casing() {
        #expect(TextTransform.uppercase.apply("Mixed case") == "MIXED CASE")
        #expect(TextTransform.lowercase.apply("Mixed CASE") == "mixed case")
        #expect(TextTransform.titleCase.apply("jane o'neil-smith") == "Jane O'neil-Smith")
        #expect(TextTransform.titleCase.apply("don't STOP") == "Don't Stop")
    }

    @Test("A transform touches only the selected cells, following the sort")
    func transformRange() {
        var rows = makeRows([["Name", "City"], ["ann", "rome"], ["bob", "oslo"]])
        // Displayed bob, ann; select the first displayed row's name only.
        transformCells(in: &rows, range: GridRange(topRow: 0, bottomRow: 0, leftColumn: 0, rightColumn: 0),
                       displayOrder: [2, 1], .uppercase)
        #expect(cells(rows) == [["Name", "City"], ["ann", "rome"], ["BOB", "oslo"]])
    }

    @Test("Join makes a new column to the right and keeps the originals")
    func join() {
        var rows = makeRows([["First", "Last", "Age"], ["Ann", "Lee", "30"], ["Bo", "", "41"]])
        let added = joinColumns(in: &rows, columns: [0, 1], separator: " ", headerRows: 1)
        #expect(added == 2)
        #expect(cells(rows) == [
            ["First", "Last", "First Last", "Age"],
            ["Ann", "Lee", "Ann Lee", "30"],
            ["Bo", "", "Bo", "41"],   // no trailing separator for a missing part
        ])
    }

    @Test("Join uses the chosen separator for data but a space for the title")
    func joinSeparator() {
        var rows = makeRows([["City", "State"], ["Austin", "TX"]])
        joinColumns(in: &rows, columns: [0, 1], separator: ", ", headerRows: 1)
        #expect(column(rows, 2) == ["City State", "Austin, TX"])
    }

    @Test("Columns that aren't neighbours join left to right, after the last one")
    func joinApart() {
        var rows = makeRows([["First", "Age", "Last"], ["Ann", "30", "Lee"]])
        let added = joinColumns(in: &rows, columns: [2, 0], separator: " ", headerRows: 1)
        #expect(added == 3)
        #expect(cells(rows) == [["First", "Age", "Last", "First Last"], ["Ann", "30", "Lee", "Ann Lee"]])
    }

    @Test("Split makes new columns to the right and keeps the original")
    func split() {
        var rows = makeRows([["Name", "Age"], ["Lee, Ann", "30"], ["Smith, Bo", "41"]])
        let added = splitColumn(in: &rows, column: 0, separator: ",", headerRows: 1)
        #expect(added == 2)
        #expect(cells(rows) == [
            ["Name", "Name 1", "Name 2", "Age"],
            ["Lee, Ann", "Lee", "Ann", "30"],
            ["Smith, Bo", "Smith", "Bo", "41"],
        ])
    }

    @Test("Splitting on a space splits on runs of spaces")
    func splitSpaces() {
        #expect(splitParts("Mary  Ann   Smith", on: " ") == ["Mary", "Ann", "Smith"])
        #expect(splitParts("a,,b", on: ",") == ["a", "", "b"])
        #expect(splitParts("", on: ",") == [])
    }

    @Test("Ragged splits pad with blanks; the widest row sets the column count")
    func splitRagged() {
        var rows = makeRows([["Full"], ["Ann Lee"], ["Mary Ann Smith"], ["Cher"]])
        #expect(splitColumnCount(in: rows, column: 0, separator: " ", headerRows: 1) == 3)
        splitColumn(in: &rows, column: 0, separator: " ", headerRows: 1)
        #expect(rows[1].cells == ["Ann Lee", "Ann", "Lee", ""])
        #expect(rows[3].cells == ["Cher", "Cher", "", ""])
    }

    @Test("A column with nothing to split is left alone")
    func splitNothing() {
        var rows = makeRows([["Name"], ["Ann"], ["Bo"]])
        #expect(splitColumn(in: &rows, column: 0, separator: ",", headerRows: 1) == 0)
        #expect(cells(rows) == [["Name"], ["Ann"], ["Bo"]])
    }
}

// MARK: - Sort keys across column changes

@MainActor
struct SortKeyRemapTests {

    @Test("An insert at or left of a sorted column moves the sort along with it")
    func insertShifts() {
        #expect(CSVTableView.Coordinator.columnAfterInsert(2, at: 1, count: 1) == 3)
        #expect(CSVTableView.Coordinator.columnAfterInsert(2, at: 2, count: 3) == 5)
        #expect(CSVTableView.Coordinator.columnAfterInsert(2, at: 3, count: 1) == 2)
    }

    @Test("A delete drops a sort on a deleted column and shifts the rest left")
    func deleteShifts() {
        let deleted = IndexSet([1, 3])
        #expect(CSVTableView.Coordinator.columnAfterDelete(0, deleted: deleted) == 0)
        #expect(CSVTableView.Coordinator.columnAfterDelete(1, deleted: deleted) == nil)
        #expect(CSVTableView.Coordinator.columnAfterDelete(2, deleted: deleted) == 1)
        #expect(CSVTableView.Coordinator.columnAfterDelete(5, deleted: deleted) == 3)
    }
}

// MARK: - Selections of several ranges

@MainActor
struct MultiRangeSelectionTests {

    private let grid = makeRows([
        ["h1", "h2", "h3"],
        ["1",  "10", "x"],
        ["2",  "20", "y"],
        ["3",  "30", "z"],
    ])
    private let order = [1, 2, 3]

    private func cell(_ row: Int, _ column: Int) -> GridRange {
        GridRange(topRow: row, bottomRow: row, leftColumn: column, rightColumn: column)
    }

    @Test("Two cells that aren't neighbours sum together")
    func sumsApart() {
        let blocks = selectionBlocks(for: [cell(0, 0), cell(2, 1)], displayOrder: order)
        let summary = summarize([selectedCellValues(in: grid, blocks: blocks)])
        #expect(summary.cellCount == 2)
        #expect(summary.sum == 31)
    }

    @Test("Overlapping ranges count their shared cells once")
    func overlapCountsOnce() {
        let a = GridRange(topRow: 0, bottomRow: 1, leftColumn: 0, rightColumn: 0)
        let b = GridRange(topRow: 1, bottomRow: 2, leftColumn: 0, rightColumn: 0)
        let blocks = selectionBlocks(for: [a, b], displayOrder: order)
        let summary = summarize([selectedCellValues(in: grid, blocks: blocks)])
        #expect(summary.cellCount == 3)
        #expect(summary.sum == 6)
    }

    @Test("Blocks follow the sort to the rows actually on screen")
    func blocksFollowSort() {
        let blocks = selectionBlocks(for: [cell(0, 0)], displayOrder: [3, 2, 1])
        #expect(blocks == [SelectionBlock(rows: [3], columns: 0...0)])
    }

    @Test("Ranges in the same columns copy as stacked rows, in grid order")
    func copyStacked() {
        let copied = combinedCells(from: grid, ranges: [cell(2, 1), cell(0, 1)], displayOrder: order)
        #expect(copied == CopiedCells(grid: [["10"], ["30"]], closedGaps: false))
    }

    @Test("Ranges in the same rows copy side by side, in grid order")
    func copySideBySide() {
        let copied = combinedCells(from: grid, ranges: [cell(1, 2), cell(1, 0)], displayOrder: order)
        #expect(copied == CopiedCells(grid: [["2", "y"]], closedGaps: false))
    }

    @Test("A1, B2, C4 and D4 copy as A1 / B2 / C4⇥D4 — cells sharing a row stay together")
    func scatteredKeepsRows() {
        let square = makeRows([
            ["A", "B", "C", "D"],
            ["A1", "B1", "C1", "D1"],
            ["A2", "B2", "C2", "D2"],
            ["A3", "B3", "C3", "D3"],
            ["A4", "B4", "C4", "D4"],
        ])
        // Picked in no particular order; the copy reads top-down regardless.
        let copied = combinedCells(from: square,
                                   ranges: [cell(3, 3), cell(0, 0), cell(3, 2), cell(1, 1)],
                                   displayOrder: [1, 2, 3, 4])
        #expect(copied == CopiedCells(grid: [["A1"], ["B2"], ["C4", "D4"]], closedGaps: true))
    }

    @Test("Overlapping pieces copy each cell once")
    func copyDeduplicates() {
        let block = GridRange(topRow: 0, bottomRow: 1, leftColumn: 0, rightColumn: 1)
        let copied = combinedCells(from: grid, ranges: [block, cell(1, 1), cell(2, 2)], displayOrder: order)
        #expect(copied == CopiedCells(grid: [["1", "10"], ["2", "20"], ["z"]], closedGaps: true))
    }

    @Test("A single range copies whole, blanks inside it included")
    func singleRangeWhole() {
        let copied = combinedCells(from: makeRows([["h", "h"], ["a", ""], ["", "d"]]),
                                   ranges: [GridRange(topRow: 0, bottomRow: 1, leftColumn: 0, rightColumn: 1)],
                                   displayOrder: [1, 2])
        #expect(copied == CopiedCells(grid: [["a", ""], ["", "d"]], closedGaps: false))
    }
}

