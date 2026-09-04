import AppKit

// MARK: - Language

enum Language {
    case json, xml, html, markdown, csv, tsv, plain

    static func detect(from url: URL?) -> Language {
        switch url?.pathExtension.lowercased() {
        case "json": return .json
        case "xml":  return .xml
        case "html", "htm": return .html
        case "md", "markdown": return .markdown
        case "csv": return .csv
        case "tsv", "tab": return .tsv
        default: return .plain
        }
    }

    var canPrettyPrint: Bool {
        switch self { case .json, .xml, .html: return true; default: return false }
    }

    var isTabular: Bool {
        switch self { case .csv, .tsv: return true; default: return false }
    }

    /// Delimiter character for CSV/TSV; nil for all other languages.
    var tabularDelimiter: Character? {
        switch self {
        case .csv: return ","
        case .tsv: return "\t"
        default:   return nil
        }
    }
}

// MARK: - CSV Row Model

/// One row of a parsed delimited file. UUID identity is intentional:
/// future cell editing / row insertion tracks by id, not index position.
nonisolated struct CSVRow: Identifiable, Sendable {
    let id   = UUID()
    var cells: [String]
}

// MARK: - Column Alignment Inference

/// How a grid column should be aligned, inferred from the values it holds.
/// Shared by the on-screen table and the printer so a printed sheet matches
/// what was on screen.
enum ColumnAlignment {
    case leading    // text
    case center     // short codes — Y/N, M/F, USA
    case trailing   // numbers

    var textAlignment: NSTextAlignment {
        switch self {
        case .leading:  return .left
        case .center:   return .center
        case .trailing: return .right
        }
    }
}

/// Share of non-empty cells that must agree before a column takes on a
/// non-default alignment. Matches the ratio the auto-grid paste detector uses.
private let columnAlignmentThreshold = 0.8

/// Cells this short read as codes rather than prose — "Y", "No", "USA".
private let shortCellLength = 3

/// Infers alignment from a column's values.
///
/// Numeric beats short: a column of 1/0 flags is still a column of numbers, and
/// right-aligning it keeps the digits under each other. Empty cells are ignored
/// entirely — a column that is mostly blank shouldn't read as "short".
nonisolated func inferColumnAlignment(_ values: [String]) -> ColumnAlignment {
    var populated = 0
    var numeric   = 0
    var short     = 0

    for value in values {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { continue }
        populated += 1
        if looksNumeric(trimmed)                { numeric += 1 }
        if trimmed.count <= shortCellLength     { short   += 1 }
    }

    guard populated > 0 else { return .leading }
    let total = Double(populated)
    if Double(numeric) / total >= columnAlignmentThreshold { return .trailing }
    if Double(short)   / total >= columnAlignmentThreshold { return .center }
    return .leading
}

/// Lenient numeric test for real spreadsheet exports: tolerates a leading
/// currency symbol, thousands separators, a trailing percent sign, and
/// parenthesised negatives like "(1,200.00)" that accounting exports produce.
///
/// Defined in terms of `numericValue` so the selection summary in the status bar
/// adds up exactly the cells the grid right-aligns. Two separate notions of
/// "is this a number" would eventually disagree, and a column that displays as
/// numeric but refuses to total is a bug report.
nonisolated func looksNumeric(_ value: String) -> Bool {
    numericValue(value) != nil
}

/// The number a cell holds, or nil when it isn't one. Accepts exactly what
/// `looksNumeric` accepts.
///
/// Accounting parentheses yield a negative. A trailing percent sign is dropped
/// rather than divided by 100 — the status bar totals what is on screen, so a
/// column of "12%" and "8%" sums to 20, which is what someone reading those
/// cells expects to see.
nonisolated func numericValue(_ value: String) -> Double? {
    var text = value
    var parenthesisedNegative = false

    if text.hasPrefix("("), text.hasSuffix(")") {
        text = String(text.dropFirst().dropLast())
        parenthesisedNegative = true
    }
    if let first = text.first, "$€£¥".contains(first) {
        text = String(text.dropFirst())
    }
    if text.hasSuffix("%") { text = String(text.dropLast()) }
    text = text.replacingOccurrences(of: ",", with: "")
               .trimmingCharacters(in: .whitespaces)

    guard !text.isEmpty else { return nil }

    // A leading zero followed by another digit means an identifier, not a
    // quantity: student IDs, zip codes and account numbers all look like this,
    // and they belong on the left with the other labels. "0" and "0.89" are
    // still numbers.
    var digits = Substring(text)
    if digits.first == "-" || digits.first == "+" { digits = digits.dropFirst() }
    if digits.first == "0", digits.dropFirst().first?.isNumber == true { return nil }

    guard let number = Double(text) else { return nil }
    return parenthesisedNegative ? -abs(number) : number
}

// MARK: - Delimited File Parsing & Serialization

/// RFC 4180-compliant parser. Strips quotes for display; never touches document.text.
/// `nonisolated` so the background parse in parseCSVInBackground is a legal
/// cross-actor call (the project defaults every declaration to @MainActor).
nonisolated func parseDelimited(_ text: String, delimiter: Character) -> [CSVRow] {
    var result:   [CSVRow]  = []
    var row:      [String]  = []
    var field     = ""
    var inQuotes  = false
    var quoted    = false   // this field opened with a quote
    var i         = text.startIndex

    while i < text.endIndex {
        let c    = text[i]
        let next = text.index(after: i)

        if inQuotes {
            if c == "\"" {
                if next < text.endIndex && text[next] == "\"" {
                    field.append("\""); i = next          // escaped ""
                } else {
                    inQuotes = false
                }
            } else { field.append(c) }
        } else {
            // A quote only OPENS a quoted field at the very start of that field.
            // Anywhere else it is a literal character — an inch mark (5" pipe) or a
            // stray quote must not swallow the following delimiters and newlines,
            // which merged rows and silently corrupted the file on the next save.
            if      c == "\"" && field.isEmpty && !quoted { inQuotes = true; quoted = true }
            else if c == delimiter { row.append(field); field = ""; quoted = false }
            else if c == "\r\n" || c == "\n" || c == "\r" {
                // Swift treats \r\n as ONE Character (a single grapheme cluster),
                // so we must match it explicitly — c == "\r" alone will never fire
                // for CRLF files, causing the entire file to parse as one row.
                row.append(field); field = ""; quoted = false
                result.append(CSVRow(cells: row)); row = []
            } else { field.append(c) }
        }
        i = text.index(after: i)
    }
    // Flush last row (no trailing newline)
    row.append(field)
    if !row.allSatisfy({ $0.isEmpty }) { result.append(CSVRow(cells: row)) }
    return result
}

/// Re-serializes rows to proper CSV/TSV for clipboard. Quotes fields that need it.
/// Only used for copy; document.text is never modified.
func serializeDelimited(_ rows: [CSVRow], delimiter: Character) -> String {
    rows.map { row in
        row.cells.map { field in
            let needs = field.contains(delimiter) || field.contains("\"")
                     || field.contains("\n")      || field.contains("\r")
            if needs { return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            return field
        }.joined(separator: String(delimiter))
    }.joined(separator: "\n")
}

/// Scans the first 20 lines and returns comma or tab — whichever appears more.
func autoDetectDelimiter(in text: String) -> Character {
    let sample = text.components(separatedBy: .newlines).prefix(20)
    var commas = 0; var tabs = 0
    for line in sample {
        commas += line.filter { $0 == "," }.count
        tabs   += line.filter { $0 == "\t" }.count
    }
    return tabs > commas ? "\t" : ","
}

// MARK: - Pretty Printer / Minifier

func prettyPrint(text: String, language: Language) -> String? {
    switch language {
    case .json:
        guard let data  = text.data(using: .utf8),
              let obj   = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                       options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8)
        else { return nil }
        return result
    case .xml:
        return prettyPrintXML(text)
    case .html:
        return prettyPrintHTML(text)
    default:
        return nil
    }
}

func minify(text: String, language: Language) -> String? {
    switch language {
    case .json:
        guard let data    = text.data(using: .utf8),
              let obj     = try? JSONSerialization.jsonObject(with: data),
              let compact = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let result  = String(data: compact, encoding: .utf8)
        else { return nil }
        return result
    case .xml:
        return minifyXML(text)
    case .html:
        return minifyHTML(text)
    default:
        return nil
    }
}

// Strict XML pretty print
private func prettyPrintXML(_ src: String) -> String? {
    guard let data = src.data(using: .utf8),
          let doc  = try? XMLDocument(data: data, options: [.nodePreserveWhitespace])
    else { return nil }
    return doc.xmlString(options: [.nodePrettyPrint])
}

// HTML pretty print — uses libxml2's lenient HTML parser so real-world HTML works
private func prettyPrintHTML(_ src: String) -> String? {
    guard let data = src.data(using: .utf8),
          let doc  = try? XMLDocument(data: data, options: [.documentTidyHTML])
    else { return nil }
    return doc.xmlString(options: [.nodePrettyPrint])
}

private func minifyXML(_ src: String) -> String? {
    guard let data = src.data(using: .utf8),
          let doc  = try? XMLDocument(data: data, options: [])
    else { return nil }
    return doc.xmlString(options: [])
}

private func minifyHTML(_ src: String) -> String? {
    guard let data = src.data(using: .utf8),
          let doc  = try? XMLDocument(data: data, options: [.documentTidyHTML])
    else { return nil }
    return doc.xmlString(options: [])
}

// MARK: - Syntax Highlighter

final class SyntaxHighlighter: NSObject, NSTextStorageDelegate {
    var language: Language = .plain
    /// The base ink color for the current paper theme. Set this whenever the
    /// theme changes so plain text and non-token regions always render correctly
    /// in dark / sepia / light mode rather than falling back to system black.
    var inkColor: NSColor = .labelColor
    /// The editor's current font. Bold markdown runs are derived from this so they
    /// track the monospaced face and the zoom level instead of a fixed system font.
    var baseFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var isHighlighting = false

    /// Token highlighting rescans the whole document on every keystroke. Past this
    /// size that cost dominates typing, so large files render as plain text.
    private static let maxHighlightLength = 500_000

    func textStorage(
        _ textStorage: NSTextStorage,
        willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !isHighlighting,
              editedMask.contains(.editedCharacters)
        else { return }

        isHighlighting = true
        let full = NSRange(location: 0, length: textStorage.length)

        if language == .plain {
            // For plain text, only paint the edited range — NOT the full document.
            //
            // Painting the full range inside willProcessEditing corrupts
            // NSTextInputContext's internal replacement-range tracking: on the
            // very next keystroke it uses that full range as the insertion's
            // replacementRange, replacing the entire document instead of
            // inserting at the cursor position.
            //
            // The edited range IS the full range for initial load and for the
            // programmatic ts.edited(…range: full…) we fire on theme changes,
            // so those paths are still fully colored.
            textStorage.addAttribute(.foregroundColor, value: inkColor, range: editedRange)
            isHighlighting = false
            return
        }

        guard textStorage.length <= Self.maxHighlightLength else {
            textStorage.addAttribute(.foregroundColor, value: inkColor, range: full)
            isHighlighting = false
            return
        }

        // Syntax-highlighted languages: paint everything first (needed to clear
        // stale token colors when the language switches), then apply tokens.
        textStorage.addAttribute(.foregroundColor, value: inkColor, range: full)
        switch language {
        case .json: applyJSON(textStorage)
        case .xml, .html: applyXML(textStorage)
        case .markdown: applyMarkdown(textStorage)
        default: break
        }
        isHighlighting = false
    }

    // MARK: JSON

    private func applyJSON(_ ts: NSTextStorage) {
        let str = ts.string
        let patterns: [(String, NSColor)] = [
            (#""([^"\\]|\\.)*"\s*(?=:)"#, .systemBlue),       // keys
            (#"(?<=:\s)"([^"\\]|\\.)*""#, .systemOrange),      // string values
            (#"\b-?\d+(\.\d+)?([eE][+-]?\d+)?\b"#, .systemPurple), // numbers
            (#"\b(true|false|null)\b"#, .systemRed),            // keywords
        ]
        applyPatterns(patterns, to: ts, in: str)
    }

    // MARK: XML/HTML

    private func applyXML(_ ts: NSTextStorage) {
        let str = ts.string
        let patterns: [(String, NSColor)] = [
            (#"<!--[\s\S]*?-->"#, .systemGreen),                // comments
            (#"<[/!?]?[a-zA-Z][^>]*>"#, .systemBlue),          // tags
            (#"\b[a-zA-Z][\w-]*(?=\s*=)"#, .systemPurple),     // attributes
            (#"(?<==)"[^"]*""#, .systemOrange),                 // attr values
        ]
        applyPatterns(patterns, to: ts, in: str)
    }

    // MARK: Markdown

    private func applyMarkdown(_ ts: NSTextStorage) {
        let str = ts.string
        let patterns: [(String, NSColor)] = [
            (#"^#{1,6}\s.+$"#, .systemBlue),                   // headers
            (#"`[^`]+`"#, .systemOrange),                       // inline code
            (#"\[([^\]]+)\]\([^)]+\)"#, .systemTeal),           // links
            (#"\*\*[^*]+\*\*|__[^_]+__"#, .labelColor),        // bold (keep default, will bold)
        ]
        applyPatterns(patterns, to: ts, in: str)

        // Bold — derived from the editor's own font so it stays monospaced and
        // follows zoom, instead of snapping to 13pt system.
        let bold = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        apply(pattern: #"\*\*[^*]+\*\*|__[^_]+__"#, to: ts, in: str) { range in
            ts.addAttribute(.font, value: bold, range: range)
        }
    }

    // MARK: Helpers

    private func applyPatterns(_ patterns: [(String, NSColor)], to ts: NSTextStorage, in str: String) {
        for (pattern, color) in patterns {
            apply(pattern: pattern, to: ts, in: str) { range in
                ts.addAttribute(.foregroundColor, value: color, range: range)
            }
        }
    }

    private func apply(
        pattern: String,
        to ts: NSTextStorage,
        in str: String,
        options: NSRegularExpression.Options = [.anchorsMatchLines],
        action: (NSRange) -> Void
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        let full = NSRange(location: 0, length: (str as NSString).length)
        regex.enumerateMatches(in: str, options: [], range: full) { match, _, _ in
            guard let range = match?.range else { return }
            action(range)
        }
    }
}
