import Foundation

// MARK: - Line addressing
//
// Shared by Go to Line and, later, anything else that needs to turn a line
// number into a range (a line-number gutter, jump-to-error, and so on).

/// Character range of `line` (1-based) in `text`, with the line terminator
/// trimmed off. Lines past the end clamp to the last line, and an empty
/// document yields an empty range rather than a crash.
nonisolated func lineRange(for line: Int, in text: String) -> NSRange {
    let ns = text as NSString
    guard line > 1 else { return trimmingTerminator(ns.lineRange(for: NSRange(location: 0, length: 0)), in: ns) }

    var index = 0
    var current = 1
    while current < line && index < ns.length {
        index = ns.lineRange(for: NSRange(location: index, length: 0)).upperBound
        current += 1
    }
    return trimmingTerminator(ns.lineRange(for: NSRange(location: min(index, ns.length), length: 0)), in: ns)
}

/// Number of lines in `text`. A document with no trailing newline still counts
/// its final line, and an empty document is one line.
nonisolated func lineCount(in text: String) -> Int {
    text.isEmpty ? 1 : text.unicodeScalars.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
}

private nonisolated func trimmingTerminator(_ range: NSRange, in ns: NSString) -> NSRange {
    var result = range
    while result.length > 0 {
        let last = ns.character(at: result.upperBound - 1)
        guard last == 10 || last == 13 else { break }
        result.length -= 1
    }
    return result
}
