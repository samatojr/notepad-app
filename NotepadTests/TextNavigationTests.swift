import Foundation
import Testing
@testable import Notepad

// Line addressing backs Go to Line today and will back the grid's row jumps and
// a line-number gutter later. The edge cases below are the ones that turn into
// an out-of-range crash or an off-by-one jump.

@MainActor
struct TextNavigationTests {

    // MARK: - Counting

    @Test("Line counts", arguments: [
        ("",              1),   // an empty document is still one line
        ("single",        1),
        ("a\nb",          2),   // no trailing newline — the last line still counts
        ("a\nb\n",        3),   // trailing newline opens an empty final line
        ("\n",            2),
        ("a\nb\nc\nd",    4),
    ])
    func lineCounts(text: String, expected: Int) {
        #expect(lineCount(in: text) == expected)
    }

    @Test("Counting is done at the scalar level, so CRLF is one break")
    func crlfCountsOnce() {
        // "\r\n" is a single Swift Character; counting Characters would work here
        // by accident, but the buffer is LF-normalized before it ever gets here.
        #expect(lineCount(in: TextFileIO.normalizeNewlines("a\r\nb\r\nc")) == 3)
    }

    // MARK: - Ranges

    @Test("Each line maps to its own text, with the terminator trimmed off")
    func rangesPerLine() {
        let text = "alpha\nbravo\ncharlie"
        let ns = text as NSString
        #expect(ns.substring(with: lineRange(for: 1, in: text)) == "alpha")
        #expect(ns.substring(with: lineRange(for: 2, in: text)) == "bravo")
        #expect(ns.substring(with: lineRange(for: 3, in: text)) == "charlie")
    }

    @Test("The line terminator is never part of the range")
    func terminatorTrimmed() {
        let text = "alpha\nbravo\n"
        let range = lineRange(for: 1, in: text)
        #expect((text as NSString).substring(with: range) == "alpha")
        #expect(range.length == 5)
    }

    @Test("A line past the end clamps to the last line instead of crashing")
    func pastEndClamps() {
        let text = "one\ntwo"
        let range = lineRange(for: 999, in: text)
        #expect(NSMaxRange(range) <= (text as NSString).length)
        #expect((text as NSString).substring(with: range) == "two")
    }

    @Test("Line 0 and negative lines clamp to the first line")
    func belowRangeClamps() {
        let text = "one\ntwo"
        #expect((text as NSString).substring(with: lineRange(for: 0, in: text)) == "one")
        #expect((text as NSString).substring(with: lineRange(for: -5, in: text)) == "one")
    }

    @Test("An empty document yields an empty range, not a crash")
    func emptyDocument() {
        let range = lineRange(for: 1, in: "")
        #expect(range.location == 0)
        #expect(range.length == 0)
    }

    @Test("An empty line has a zero-length range at the right offset")
    func emptyLineInMiddle() {
        let text = "one\n\nthree"
        let range = lineRange(for: 2, in: text)
        #expect(range.length == 0)
        #expect(range.location == 4)
    }

    @Test("Every line in the document is addressable and in range")
    func allLinesAddressable() {
        let text = "a\nbb\nccc\ndddd\n"
        let ns = text as NSString
        for line in 1...lineCount(in: text) {
            let range = lineRange(for: line, in: text)
            #expect(range.location >= 0)
            #expect(NSMaxRange(range) <= ns.length)
        }
    }
}
