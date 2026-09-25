import Foundation

// MARK: - Quick actions
//
// The pure core behind 4.1's grid quick actions: moving rows, keeping a sort,
// column math, totals, fill series and text cleanup. Like GridOperations.swift
// this is Foundation only, so everything that writes into a file can be tested
// without a table on screen.
//
// None of this is a live formula. Every action writes plain values into the
// grid, is undone with ⌘Z like any other edit, and does not recalculate later.
// That is deliberate: a CSV has nowhere to keep a formula, so anything live
// would either leak "=SUM(…)" into the file or evaporate on reopen.
//
// Structural actions (a new column, a totals row) address the WHOLE rows array,
// header included, and take `headerRows` — 1 when the first row is being shown
// as headers, 0 when it is data — so a new column gets a title only when there
// is a header row to put it in.

// MARK: - Number formatting

nonisolated private let currencySymbols: Set<Character> = ["$", "€", "£", "¥"]

/// The exact value as plain digits — no grouping, no currency, no exponent —
/// which is what a copied number has to be to paste as a number into Sheets,
/// Excel or back into this grid. Rounded to 15 significant digits so binary
/// noise never shows: 0.1 + 0.2 copies as "0.3", not "0.30000000000000004".
nonisolated func plainNumberString(_ value: Double) -> String {
    guard value.isFinite else { return "" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.usesSignificantDigits = true
    formatter.maximumSignificantDigits = 15
    // `value + 0` turns -0 into 0, so a sum that cancels out never reads "-0".
    return formatter.string(from: NSNumber(value: value + 0)) ?? ""
}

/// How a column writes its numbers, so a computed value can be written the
/// same way: "$1,200.50" in, "$3,601.50" out — not "3601.5".
nonisolated struct NumberStyle: Equatable, Sendable {
    var fractionDigits = 0
    var currency: Character?
    var percent = false
    var grouped = false

    init(fractionDigits: Int = 0, currency: Character? = nil,
         percent: Bool = false, grouped: Bool = false) {
        self.fractionDigits = fractionDigits
        self.currency = currency
        self.percent = percent
        self.grouped = grouped
    }

    /// The style a set of cells share. Decimal places are the most any of them
    /// uses; a currency symbol or percent sign carries over only when EVERY cell
    /// has it, so one "$" in a column of plain numbers doesn't dollar the total.
    init(sampling cells: [String]) {
        var digits = 0
        var symbols: Set<Character?> = []
        var allPercent = !cells.isEmpty
        var anyGrouped = false
        for cell in cells {
            let text = cell.trimmingCharacters(in: .whitespaces)
            digits = max(digits, Self.fractionDigits(in: text))
            symbols.insert(Self.currencySymbol(in: text))
            if !text.hasSuffix("%") { allPercent = false }
            if text.contains(",") { anyGrouped = true }
        }
        fractionDigits = min(digits, 10)
        currency = symbols.count == 1 ? symbols.first ?? nil : nil
        percent  = allPercent
        grouped  = anyGrouped
    }

    func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouped
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        let magnitude = formatter.string(from: NSNumber(value: abs(value))) ?? ""
        // Rounding can take a tiny negative to zero; "-$0.00" would be noise.
        let isNegative = value < 0 && magnitude.contains(where: { $0 != "0" && $0 != "." && $0 != "," })
        return (isNegative ? "-" : "") + (currency.map(String.init) ?? "") + magnitude + (percent ? "%" : "")
    }

    /// Digits after the decimal point, ignoring any currency, percent or parentheses.
    static func fractionDigits(in text: String) -> Int {
        guard let dot = text.lastIndex(of: ".") else { return 0 }
        return text[text.index(after: dot)...].prefix(while: \.isNumber).count
    }

    static func currencySymbol(in text: String) -> Character? {
        var body = Substring(text)
        if body.first == "(" { body = body.dropFirst() }
        if body.first == "-" || body.first == "+" { body = body.dropFirst() }
        return body.first.flatMap { currencySymbols.contains($0) ? $0 : nil }
    }
}

// MARK: - Moving rows

/// Moves a contiguous block of rows so it sits in front of the row currently at
/// display row `gap` — `gap == displayOrder.count` means the end. This is the
/// coordinate a drag reports ("drop above row 7"), and it is how ⌥⌘↑/↓ express
/// a one-row nudge.
///
/// Only meaningful while the grid is UNSORTED: under a sort the display order
/// is computed, and a moved row would simply be put back where the sort wants
/// it. A sorted `displayOrder` is refused, as is any gap that lands inside the
/// block itself, and the header can never be moved or displaced because display
/// coordinates do not reach it.
///
/// Returns the block's new display rows so the caller can keep it selected, or
/// nil when nothing moved.
@discardableResult
nonisolated func moveRows(in rows: inout [CSVRow],
                          displayRows block: ClosedRange<Int>,
                          toGap gap: Int,
                          displayOrder: [Int]) -> ClosedRange<Int>? {
    guard let first = displayOrder.first,
          block.lowerBound >= 0, block.upperBound < displayOrder.count,
          gap >= 0, gap <= displayOrder.count else { return nil }
    // Unsorted means the data rows are csvRows[first...] in order.
    for (offset, index) in displayOrder.enumerated() where index != first + offset { return nil }
    guard first + displayOrder.count == rows.count else { return nil }
    // Dropping a block anywhere inside or directly around itself moves nothing.
    guard gap < block.lowerBound || gap > block.upperBound + 1 else { return nil }

    let lower = first + block.lowerBound
    let upper = first + block.upperBound
    let moving = Array(rows[lower...upper])
    rows.removeSubrange(lower...upper)

    let target = gap > block.upperBound ? gap - block.count : gap
    rows.insert(contentsOf: moving, at: first + target)
    return target...(target + block.count - 1)
}

/// Writes the current sort into the file: the rows take the order they have on
/// screen, and the header (anything `displayOrder` doesn't list) stays in front.
/// Afterwards the grid can be unsorted without anything moving.
nonisolated func applyDisplayOrder(to rows: inout [CSVRow], displayOrder: [Int]) {
    let listed = Set(displayOrder)
    guard listed.count == displayOrder.count,
          displayOrder.allSatisfy({ rows.indices.contains($0) }) else { return }
    let fixed = rows.indices.filter { !listed.contains($0) }.map { rows[$0] }
    rows = fixed + displayOrder.map { rows[$0] }
}

// MARK: - Column math

nonisolated enum ArithmeticOperation: String, CaseIterable, Sendable {
    case add = "+", subtract = "−", multiply = "×", divide = "÷"

    /// nil for division by zero — the cell is left blank rather than holding
    /// "inf", which no other program would read as a number either.
    func apply(_ lhs: Double, _ rhs: Double) -> Double? {
        switch self {
        case .add:      return lhs + rhs
        case .subtract: return lhs - rhs
        case .multiply: return lhs * rhs
        case .divide:   return rhs == 0 ? nil : lhs / rhs
        }
    }
}

nonisolated enum CalculationOperand: Equatable, Sendable {
    case column(Int)
    case number(Double)
}

/// A value typed into the calculation dialog. Unlike a cell in a sum, a percent
/// here means a fraction: "× 8%" is the tax on a price, not eight times it.
nonisolated func operandNumber(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard let value = numericValue(trimmed) else { return nil }
    return trimmed.hasSuffix("%") ? value / 100 : value
}

nonisolated struct ColumnCalculation: Equatable, Sendable {
    var left: Int
    var operation: ArithmeticOperation
    var right: CalculationOperand
    /// nil lets the inputs decide: a price column keeps its two decimals when
    /// the result fits them, and anything that doesn't fit is written exactly.
    var decimalPlaces: Int?

    init(left: Int, operation: ArithmeticOperation, right: CalculationOperand,
         decimalPlaces: Int? = nil) {
        self.left = left
        self.operation = operation
        self.right = right
        self.decimalPlaces = decimalPlaces
    }

    /// The result for one row, or "" when either side isn't a number.
    func value(for cells: [String]) -> String {
        func cell(_ column: Int) -> String {
            column < cells.count ? cells[column].trimmingCharacters(in: .whitespaces) : ""
        }
        let leftText = cell(left)
        guard let lhs = operandNumber(leftText) else { return "" }

        let rightText: String?
        let rhs: Double
        switch right {
        case .number(let number):
            rightText = nil
            rhs = number
        case .column(let column):
            let text = cell(column)
            guard let number = operandNumber(text) else { return "" }
            rightText = text
            rhs = number
        }
        guard let result = operation.apply(lhs, rhs), result.isFinite else { return "" }

        let inputs = [leftText] + (rightText.map { [$0] } ?? [])
        // A percent input was divided through, so the result is a plain number.
        var style = NumberStyle(sampling: inputs.filter { !$0.hasSuffix("%") })
        style.percent = false
        style.currency = inputs.lazy.compactMap { NumberStyle.currencySymbol(in: $0) }.first

        if let places = decimalPlaces {
            style.fractionDigits = places
            return style.format(result)
        }
        // Automatic: keep the inputs' decimal places when the answer fits them
        // (19.99 × 3 = 59.97, 1.50 + 1.50 = 3.00), and write it exactly when it
        // doesn't (10 ÷ 4 = 2.5 from whole numbers, never a rounded "3").
        let scale = pow(10, Double(style.fractionDigits))
        let rounded = (result * scale).rounded() / scale
        if abs(rounded - result) <= 1e-9 * max(1, abs(result)) {
            return style.format(result)
        }
        let exact = plainNumberString(result)
        let sign = exact.hasPrefix("-") ? "-" : ""
        return sign + (style.currency.map(String.init) ?? "") + String(exact.drop(while: { $0 == "-" }))
    }
}

/// Inserts a new column at `index` holding `calculation` for every data row,
/// titled `title` when there is a header row. Column indices in the calculation
/// refer to the grid BEFORE the insert, which is what the user picked from.
nonisolated func insertCalculatedColumn(in rows: inout [CSVRow],
                                        at index: Int,
                                        title: String,
                                        calculation: ColumnCalculation,
                                        headerRows: Int) {
    guard !rows.isEmpty else { return }
    let values = rows.enumerated().map { offset, row in
        offset < headerRows ? title : calculation.value(for: row.cells)
    }
    insertColumn(in: &rows, at: index)
    let column = min(index, rows[0].cells.count - 1)
    for i in rows.indices { rows[i].cells[column] = values[i] }
}

// MARK: - Totals row

nonisolated let totalsLabel = "Total"

/// Whether a row is a totals row this app wrote: it says "Total" somewhere.
/// Running Add Totals Row again then REPLACES it instead of adding the old
/// total into the new one.
nonisolated func isTotalsRow(_ row: CSVRow) -> Bool {
    row.cells.contains { $0.trimmingCharacters(in: .whitespaces)
        .caseInsensitiveCompare(totalsLabel) == .orderedSame }
}

/// The totals for the data rows: the sum of every column whose filled cells
/// are ALL numbers, written the way that column writes numbers, and "Total" in
/// the first column that isn't summed. A column with any text in it is left
/// blank — adding up the numbers in a notes column is never what anyone meant.
nonisolated func totalsRow(for rows: [CSVRow], headerRows: Int) -> [String] {
    var data = Array(rows.dropFirst(headerRows))
    if let last = data.last, isTotalsRow(last) { data.removeLast() }
    let width = rows.map(\.cells.count).max() ?? 0
    guard width > 0 else { return [] }

    var result = Array(repeating: "", count: width)
    var summed = Array(repeating: false, count: width)
    for column in 0..<width {
        let filled = data.compactMap { row -> String? in
            guard column < row.cells.count else { return nil }
            let text = row.cells[column].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        let values = filled.compactMap(numericValue)
        guard !filled.isEmpty, values.count == filled.count else { continue }
        result[column] = NumberStyle(sampling: filled).format(values.reduce(0, +))
        summed[column] = true
    }
    if let labelColumn = summed.firstIndex(of: false) {
        result[labelColumn] = totalsLabel
    }
    return result
}

/// Adds a totals row at the end of the file, or refreshes the one already there.
nonisolated func appendTotalsRow(to rows: inout [CSVRow], headerRows: Int) {
    guard rows.count > headerRows else { return }
    let totals = totalsRow(for: rows, headerRows: headerRows)
    guard totals.contains(where: { !$0.isEmpty && $0 != totalsLabel }) else { return }
    if let last = rows.last, rows.count > headerRows + 1, isTotalsRow(last) {
        rows[rows.count - 1].cells = totals
    } else {
        rows.append(CSVRow(cells: totals))
    }
}

// MARK: - Fill series

nonisolated enum FillMode: Sendable {
    /// ⌘D: continue a pattern when the top TWO cells make one (1, 2 · Mon, Tue ·
    /// Item 1, Item 2), otherwise copy the top cell down as always.
    case continuePatternOrCopy
    /// Table ▸ Fill Series: always count. One seed steps by 1, an empty top
    /// cell starts at 1, and text with no number in it is copied.
    case series
}

/// A sequence the fill can continue.
nonisolated enum SeriesPattern: Equatable, Sendable {
    case number(start: Double, step: Double, style: NumberStyle)
    case name(list: [String], start: Int, step: Int, casing: NameCasing)
    case numbered(prefix: String, start: Int, step: Int, width: Int, suffix: String)

    nonisolated enum NameCasing: Sendable { case upper, lower, capitalized }

    func value(at k: Int) -> String {
        switch self {
        case let .number(start, step, style):
            return style.format(start + Double(k) * step)
        case let .name(list, start, step, casing):
            let n = list.count
            let name = list[(((start + k * step) % n) + n) % n]
            switch casing {
            case .upper:       return name.uppercased()
            case .lower:       return name.lowercased()
            case .capitalized: return name
            }
        case let .numbered(prefix, start, step, width, suffix):
            let number = start + k * step
            let digits = String(abs(number))
            let padded = String(repeating: "0", count: max(0, width - digits.count)) + digits
            return prefix + (number < 0 ? "-" : "") + padded + suffix
        }
    }

    // English names, matched case-insensitively. Each list is tried whole, so
    // "Mon" continues as "Tue" and "Monday" as "Tuesday".
    static let nameLists: [[String]] = [
        ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"],
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
        ["January", "February", "March", "April", "May", "June", "July",
         "August", "September", "October", "November", "December"],
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
    ]

    /// The pattern two seeds make, or — when `second` is nil — the pattern one
    /// seed makes counting by 1.
    static func detect(first: String, second: String?) -> SeriesPattern? {
        let a = first.trimmingCharacters(in: .whitespaces)
        let b = second?.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, b?.isEmpty != true else { return nil }

        if let x = numericValue(a) {
            if let b {
                guard let y = numericValue(b) else { return nil }
                return .number(start: x, step: y - x, style: NumberStyle(sampling: [a, b]))
            }
            return .number(start: x, step: 1, style: NumberStyle(sampling: [a]))
        }

        for list in nameLists {
            guard let i = index(of: a, in: list) else { continue }
            if let b {
                guard let j = index(of: b, in: list) else { continue }
                return .name(list: list, start: i, step: j - i, casing: casing(of: a))
            }
            return .name(list: list, start: i, step: 1, casing: casing(of: a))
        }

        guard let (prefix, digitsA, suffix) = splitLastNumber(a), let x = Int(digitsA) else { return nil }
        let padded = digitsA.count > 1 && digitsA.hasPrefix("0")
        if let b {
            guard let (prefixB, digitsB, suffixB) = splitLastNumber(b),
                  prefixB == prefix, suffixB == suffix, let y = Int(digitsB) else { return nil }
            let width = (padded || (digitsB.count > 1 && digitsB.hasPrefix("0")))
                ? max(digitsA.count, digitsB.count) : 0
            return .numbered(prefix: prefix, start: x, step: y - x, width: width, suffix: suffix)
        }
        return .numbered(prefix: prefix, start: x, step: 1,
                         width: padded ? digitsA.count : 0, suffix: suffix)
    }

    private static func index(of text: String, in list: [String]) -> Int? {
        list.firstIndex { $0.caseInsensitiveCompare(text) == .orderedSame }
    }

    private static func casing(of text: String) -> NameCasing {
        if text == text.uppercased(), text.count > 1 { return .upper }
        if text == text.lowercased() { return .lower }
        return .capitalized
    }

    /// "Room 101B" → ("Room ", "101", "B"): the LAST run of digits, so a label
    /// with a year in it still counts on its trailing number.
    private static func splitLastNumber(_ text: String) -> (String, String, String)? {
        guard let end = text.lastIndex(where: \.isASCIIDigit) else { return nil }
        var start = end
        while start > text.startIndex, text[text.index(before: start)].isASCIIDigit {
            start = text.index(before: start)
        }
        let afterEnd = text.index(after: end)
        return (String(text[..<start]), String(text[start..<afterEnd]), String(text[afterEnd...]))
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Fills each column of `range` from its top cells, per `mode`. Columns are
/// independent: in a two-column selection "1, 2" can count while "Mon, Tue"
/// cycles beside it. The seed cells themselves are never rewritten.
nonisolated func fillSeries(in rows: inout [CSVRow],
                            range: GridRange,
                            displayOrder: [Int],
                            mode: FillMode) {
    guard range.rowCount > 1, !range.isEmpty,
          range.bottomRow < displayOrder.count else { return }

    func text(_ displayRow: Int, _ column: Int) -> String {
        let row = rows[displayOrder[displayRow]]
        return column < row.cells.count ? row.cells[column] : ""
    }
    func write(_ value: String, _ displayRow: Int, _ column: Int) {
        let index = displayOrder[displayRow]
        if column >= rows[index].cells.count {
            rows[index].cells.append(contentsOf: Array(
                repeating: "", count: column - rows[index].cells.count + 1))
        }
        rows[index].cells[column] = value
    }

    for column in range.leftColumn...range.rightColumn {
        let top = text(range.topRow, column)
        let second = text(range.topRow + 1, column)

        var pattern: SeriesPattern?
        var seeds = 1
        // Two seeds only count when there is room past them: ⌘D on a two-row
        // selection has nothing to continue, so it copies the top cell as before.
        if range.rowCount > 2, let twoSeed = SeriesPattern.detect(first: top, second: second) {
            pattern = twoSeed
            seeds = 2
        } else if mode == .series {
            if top.trimmingCharacters(in: .whitespaces).isEmpty {
                pattern = .number(start: 1, step: 1, style: NumberStyle())
                seeds = 0
            } else {
                pattern = SeriesPattern.detect(first: top, second: nil)
            }
        }

        // No pattern: copy the top cell down, exactly as Fill Down always has.
        guard let pattern else {
            fillDown(in: &rows,
                     range: GridRange(topRow: range.topRow, bottomRow: range.bottomRow,
                                      leftColumn: column, rightColumn: column),
                     displayOrder: displayOrder)
            continue
        }
        guard range.topRow + seeds <= range.bottomRow else { continue }
        for displayRow in (range.topRow + seeds)...range.bottomRow {
            write(pattern.value(at: displayRow - range.topRow), displayRow, column)
        }
    }
}

// MARK: - Text cleanup

nonisolated enum TextTransform: CaseIterable, Sendable {
    case trimSpaces, uppercase, lowercase, titleCase

    /// How the change reads in Edit ▸ Undo.
    var title: String {
        switch self {
        case .trimSpaces: return "Trim Spaces"
        case .uppercase:  return "Uppercase"
        case .lowercase:  return "Lowercase"
        case .titleCase:  return "Title Case"
        }
    }

    func apply(_ text: String) -> String {
        switch self {
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .titleCase: return text.capitalized(with: Locale(identifier: "en_US"))
        case .trimSpaces:
            // Non-breaking spaces arrive with nearly everything pasted from a web
            // page and are invisible, so they are the ones worth normalizing.
            // Runs of spaces collapse to one; line breaks inside a cell survive.
            var result = ""
            var pendingSpace = false
            for character in text {
                if character == " " || character == "\t" || character == "\u{00A0}" {
                    pendingSpace = true
                    continue
                }
                if pendingSpace, !result.isEmpty, !character.isNewline, result.last?.isNewline == false {
                    result.append(" ")
                }
                pendingSpace = false
                result.append(character)
            }
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Applies `transform` to every cell in `range`. Cells past a short row's end
/// are left alone rather than created — there is nothing in them to change.
nonisolated func transformCells(in rows: inout [CSVRow],
                                range: GridRange,
                                displayOrder: [Int],
                                _ transform: TextTransform) {
    guard !range.isEmpty else { return }
    for displayRow in range.topRow...range.bottomRow {
        guard displayOrder.indices.contains(displayRow) else { continue }
        let index = displayOrder[displayRow]
        guard rows.indices.contains(index) else { continue }
        for column in range.leftColumn...range.rightColumn where column < rows[index].cells.count {
            rows[index].cells[column] = transform.apply(rows[index].cells[column])
        }
    }
}

/// Joins `columns` into one new column right of the last of them — "First"
/// and "Last" into "First Last" — leaving the originals where they were. The
/// columns need not be next to each other (⌘-click picks any), and are joined
/// left to right. Empty parts are skipped so a missing middle name doesn't
/// leave a double space. Returns the new column's index.
@discardableResult
nonisolated func joinColumns(in rows: inout [CSVRow],
                             columns unordered: [Int],
                             separator: String,
                             headerRows: Int) -> Int? {
    let columns = Set(unordered).sorted()
    guard !rows.isEmpty, columns.count > 1, let last = columns.last, columns[0] >= 0 else { return nil }
    let values = rows.enumerated().map { offset, row -> String in
        let parts = columns.compactMap { column -> String? in
            guard column < row.cells.count else { return nil }
            let text = row.cells[column].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        // The header is always joined with a space: "First Last", not "First,Last".
        return parts.joined(separator: offset < headerRows ? " " : separator)
    }
    let target = last + 1
    insertColumn(in: &rows, at: target)
    let column = min(target, rows[0].cells.count - 1)
    for i in rows.indices { rows[i].cells[column] = values[i] }
    return column
}

/// How a cell splits. A whitespace separator splits on RUNS of whitespace, so
/// "John  Smith" is two parts, not three; any other separator splits exactly,
/// keeping empty parts in place the way CSV does, and trims each part.
nonisolated func splitParts(_ text: String, on separator: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !separator.isEmpty else { return trimmed.isEmpty ? [] : [trimmed] }
    if separator.trimmingCharacters(in: .whitespaces).isEmpty {
        return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{00A0}" })
            .map(String.init)
    }
    return trimmed.components(separatedBy: separator)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

/// How many columns splitting `column` would produce — asked before doing it,
/// because splitting a notes column on spaces can mean hundreds.
nonisolated func splitColumnCount(in rows: [CSVRow], column: Int,
                                  separator: String, headerRows: Int) -> Int {
    rows.dropFirst(headerRows).reduce(0) { widest, row in
        guard column < row.cells.count else { return widest }
        return max(widest, splitParts(row.cells[column], on: separator).count)
    }
}

/// Splits `column` into new columns to its right — "Smith, John" into "Smith"
/// and "John" — keeping the original column intact. New columns are titled
/// "<header> 1", "<header> 2"… when there is a header row. Returns how many
/// columns were added (0 when no cell contains the separator).
@discardableResult
nonisolated func splitColumn(in rows: inout [CSVRow],
                             column: Int,
                             separator: String,
                             headerRows: Int) -> Int {
    let count = splitColumnCount(in: rows, column: column,
                                 separator: separator, headerRows: headerRows)
    guard count > 1 else { return 0 }

    let title: String = {
        guard headerRows > 0, column < rows[0].cells.count else { return "Part" }
        let text = rows[0].cells[column].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "Part" : text
    }()
    let pieces: [[String]] = rows.enumerated().map { offset, row in
        if offset < headerRows { return (1...count).map { "\(title) \($0)" } }
        let parts = column < row.cells.count ? splitParts(row.cells[column], on: separator) : []
        return parts + Array(repeating: "", count: count - parts.count)
    }
    for offset in 0..<count { insertColumn(in: &rows, at: column + 1 + offset) }
    for i in rows.indices {
        for offset in 0..<count { rows[i].cells[column + 1 + offset] = pieces[i][offset] }
    }
    return count
}
