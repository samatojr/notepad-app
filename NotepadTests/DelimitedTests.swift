import Foundation
import Testing
@testable import Notepad

// Regression tests for the CSV parser and serializer.
//
// The grid is where v4's headline work happens, and it is also where every
// data-corruption bug of the 3.x line came from. These lock down the two that
// shipped (the inch mark and the CRLF grapheme) plus the RFC 4180 behavior the
// rest of the grid assumes.

@MainActor
struct DelimitedParsingTests {

    // MARK: - The inch-mark corruption (3.3)
    //
    // A quote that is NOT at the start of a field used to open a quoted field
    // anyway. In `5" pipe` the parser went into quoted mode mid-field and then
    // swallowed every following delimiter and newline until the next quote —
    // merging rows together, which the next ⌘S wrote back to disk.

    @Test("A quote mid-field is literal and does not swallow the rest of the file")
    func inchMarkDoesNotOpenAQuotedField() {
        let rows = parseDelimited("a,5\" pipe,b\nc,d,e\n", delimiter: ",")
        #expect(rows.count == 2)                       // was 1 before the fix
        #expect(rows[0].cells == ["a", "5\" pipe", "b"])
        #expect(rows[1].cells == ["c", "d", "e"])
    }

    @Test("An unmatched quote mid-field keeps the row structure intact")
    func strayQuoteKeepsRowsIntact() {
        let rows = parseDelimited("size,6\" x 4\",qty\n1,2,3\n", delimiter: ",")
        #expect(rows.count == 2)
        #expect(rows[0].cells.count == 3)
        #expect(rows[1].cells == ["1", "2", "3"])
    }

    // MARK: - CRLF is one Character (3.4)
    //
    // Swift treats "\r\n" as a single grapheme cluster, so a `c == "\r"` test
    // never fires for a CRLF file. The parser saw no line breaks at all and
    // returned the entire file as ONE row.

    @Test("A CRLF file parses into rows, not one giant row")
    func crlfSplitsRows() {
        let rows = parseDelimited("a,b\r\nc,d\r\ne,f\r\n", delimiter: ",")
        #expect(rows.count == 3)                       // was 1 before the fix
        #expect(rows[0].cells == ["a", "b"])
        #expect(rows[2].cells == ["e", "f"])
    }

    @Test("Rows split on every line ending style", arguments: [
        "a,b\nc,d\n", "a,b\r\nc,d\r\n", "a,b\rc,d\r",
    ])
    func allLineEndingsSplitRows(text: String) {
        let rows = parseDelimited(text, delimiter: ",")
        #expect(rows.count == 2)
        #expect(rows[0].cells == ["a", "b"])
        #expect(rows[1].cells == ["c", "d"])
    }

    // MARK: - RFC 4180

    @Test("A quoted field may contain the delimiter")
    func quotedFieldHoldsDelimiter() {
        let rows = parseDelimited("\"Smith, John\",42\n", delimiter: ",")
        #expect(rows.count == 1)
        #expect(rows[0].cells == ["Smith, John", "42"])
    }

    @Test("A doubled quote inside a quoted field is one literal quote")
    func escapedQuote() {
        let rows = parseDelimited("\"she said \"\"hi\"\"\",2\n", delimiter: ",")
        #expect(rows[0].cells == ["she said \"hi\"", "2"])
    }

    @Test("A quoted field may contain a newline")
    func quotedFieldHoldsNewline() {
        let rows = parseDelimited("\"line one\nline two\",x\n", delimiter: ",")
        #expect(rows.count == 1)
        #expect(rows[0].cells == ["line one\nline two", "x"])
    }

    @Test("Empty fields are preserved, including trailing ones")
    func emptyFieldsPreserved() {
        let rows = parseDelimited("a,,c\n,,\n", delimiter: ",")
        #expect(rows[0].cells == ["a", "", "c"])
        #expect(rows[1].cells == ["", "", ""])
    }

    @Test("A final row with no trailing newline is not dropped")
    func lastRowWithoutNewline() {
        let rows = parseDelimited("a,b\nc,d", delimiter: ",")
        #expect(rows.count == 2)
        #expect(rows[1].cells == ["c", "d"])
    }

    @Test("A trailing newline does not produce a phantom empty row")
    func noPhantomTrailingRow() {
        #expect(parseDelimited("a,b\n", delimiter: ",").count == 1)
    }

    @Test("Tab-separated input parses on the tab delimiter")
    func tabDelimiter() {
        let rows = parseDelimited("a\tb\tc\n1\t2\t3\n", delimiter: "\t")
        #expect(rows.count == 2)
        #expect(rows[0].cells == ["a", "b", "c"])
    }

    @Test("Empty input parses to no rows")
    func emptyInput() {
        #expect(parseDelimited("", delimiter: ",").isEmpty)
    }
}

// MARK: - Serialization

@MainActor
struct DelimitedSerializationTests {

    @Test("Fields needing quotes get them; plain fields are left alone")
    func quotesOnlyWhereNeeded() {
        let rows = [CSVRow(cells: ["plain", "has,comma", "has\"quote", "has\nnewline"])]
        let out = serializeDelimited(rows, delimiter: ",")
        #expect(out == "plain,\"has,comma\",\"has\"\"quote\",\"has\nnewline\"")
    }

    // The round trip is the property that actually protects the file: whatever
    // the grid holds must survive serialize → parse unchanged, or a ⌘S after a
    // cell edit rewrites the document into something else.
    @Test("Round trip preserves cells exactly", arguments: [
        ["plain", "two words", "3"],
        ["has,comma", "has\"quote", "has \"inner\" quotes"],
        ["", "", "trailing empties"],
        ["5\" pipe", "6' board", "a\nb"],
        ["Smith, John", "O'Brien", "café"],
    ])
    func roundTrip(cells: [String]) {
        let original = [CSVRow(cells: cells)]
        let reparsed = parseDelimited(serializeDelimited(original, delimiter: ","),
                                      delimiter: ",")
        #expect(reparsed.count == 1)
        #expect(reparsed[0].cells == cells)
    }

    @Test("Multi-row round trip preserves the whole grid")
    func multiRowRoundTrip() {
        let original = [
            CSVRow(cells: ["name", "note", "qty"]),
            CSVRow(cells: ["elbow", "5\" pipe, galvanized", "12"]),
            CSVRow(cells: ["tee", "he said \"fits\"", "3"]),
        ]
        let reparsed = parseDelimited(serializeDelimited(original, delimiter: ","),
                                      delimiter: ",")
        #expect(reparsed.count == original.count)
        for (parsed, source) in zip(reparsed, original) {
            #expect(parsed.cells == source.cells)
        }
    }

    @Test("Tab round trip quotes fields containing tabs")
    func tabRoundTrip() {
        let original = [CSVRow(cells: ["a\tb", "c"])]
        let reparsed = parseDelimited(serializeDelimited(original, delimiter: "\t"),
                                      delimiter: "\t")
        #expect(reparsed[0].cells == ["a\tb", "c"])
    }
}

// MARK: - Delimiter detection

@MainActor
struct DelimiterDetectionTests {

    @Test("Picks the delimiter that appears more often")
    func picksMajority() {
        #expect(autoDetectDelimiter(in: "a,b,c\n1,2,3\n") == ",")
        #expect(autoDetectDelimiter(in: "a\tb\tc\n1\t2\t3\n") == "\t")
    }

    @Test("A clear tab majority survives commas inside cells")
    func tabsWinWhenClearlyAhead() {
        // 3 columns means 2 tabs per row — comfortably ahead of the stray commas.
        #expect(autoDetectDelimiter(in: "name\tnote\tqty\nSmith, John\ta, b\t3\n") == "\t")
    }

    @Test("Known limitation: a tie breaks toward comma and mis-reads a 2-column TSV")
    func tieBreaksTowardComma() {
        // A 2-column TSV carrying "Smith, John" has 2 tabs and 2 commas, and the
        // `tabs > commas` test hands the tie to comma — which would split that
        // name across two cells. Pinned rather than fixed because the function
        // currently has NO callers; the grid's paste detector does its own thing.
        // If v4 wires this into the grid, this expectation is the thing to change.
        #expect(autoDetectDelimiter(in: "name\tnote\nSmith, John\ta, b\n") == ",")
    }

    @Test("Text with neither delimiter falls back to comma")
    func fallsBackToComma() {
        #expect(autoDetectDelimiter(in: "just some prose\n") == ",")
    }
}

// MARK: - Column alignment inference

@MainActor
struct ColumnAlignmentTests {

    @Test("Numeric columns are right-aligned so the digits line up")
    func numericIsTrailing() {
        #expect(inferColumnAlignment(["1", "22", "333", "4444"]) == .trailing)
    }

    @Test("Prose is left-aligned")
    func textIsLeading() {
        #expect(inferColumnAlignment(["alpha", "bravo", "charlie"]) == .leading)
    }

    @Test("Short codes are centered")
    func shortCodesAreCentered() {
        #expect(inferColumnAlignment(["USA", "GBR", "FRA", "DEU"]) == .center)
        #expect(inferColumnAlignment(["Y", "N", "Y", "Y"]) == .center)
    }

    @Test("Numeric beats short — a column of 1/0 flags is still numbers")
    func numericBeatsShort() {
        #expect(inferColumnAlignment(["1", "0", "1", "1", "0"]) == .trailing)
    }

    @Test("Empty cells are ignored, so a sparse column is not 'short'")
    func emptyCellsIgnored() {
        #expect(inferColumnAlignment(["", "", "Winchester", ""]) == .leading)
        #expect(inferColumnAlignment(["", "", "1234", ""]) == .trailing)
    }

    @Test("An entirely empty column defaults to leading")
    func allEmptyIsLeading() {
        #expect(inferColumnAlignment(["", "", ""]) == .leading)
        #expect(inferColumnAlignment([]) == .leading)
    }

    @Test("A column that is only mostly numeric still reads as numeric")
    func mostlyNumeric() {
        // 8 of 10 populated cells are numbers — at the 0.8 threshold.
        #expect(inferColumnAlignment(["1","2","3","4","5","6","7","8","n/a","tbd"]) == .trailing)
    }

    @Test("A column with too much prose is not numeric")
    func mixedFallsBackToLeading() {
        #expect(inferColumnAlignment(["1", "2", "pending", "review", "3"]) == .leading)
    }
}

// MARK: - Numeric recognition
//
// This is what decides alignment for real spreadsheet exports, so it has to
// cope with the shapes Excel and Google Sheets actually emit.

@MainActor
struct LooksNumericTests {

    @Test("Plain numbers", arguments: ["0", "7", "-3", "+3", "3.14", "0.89", "-0.5"])
    func plainNumbers(value: String) {
        #expect(looksNumeric(value))
    }

    @Test("Spreadsheet number formats", arguments: [
        "$1,200.00",     // currency + thousands separator
        "€45",
        "£9.99",
        "1,000,000",
        "12%",
        "(1,200.00)",    // accounting negative
    ])
    func spreadsheetFormats(value: String) {
        #expect(looksNumeric(value))
    }

    @Test("Leading-zero identifiers are NOT numbers — they belong with the labels",
          arguments: ["01234", "007", "00501"])
    func leadingZeroIdentifiers(value: String) {
        // Zip codes, student IDs and account numbers all look like this. Right-
        // aligning them under real quantities reads as a mistake.
        #expect(!looksNumeric(value))
    }

    @Test("A bare zero and a decimal below one are still numbers")
    func zeroIsStillANumber() {
        #expect(looksNumeric("0"))
        #expect(looksNumeric("0.89"))
    }

    @Test("Non-numbers", arguments: ["", "abc", "n/a", "-", "12a", "1.2.3", "$"])
    func nonNumbers(value: String) {
        #expect(!looksNumeric(value))
    }
}
