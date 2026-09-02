import AppKit

// MARK: - Printing
//
// ⌘P did nothing at all before 3.4. Two printers live here: one for the text
// editor (AppKit paginates the text system for us) and one for the CSV grid.
// The grid gets its own NSView because handing NSTableView to NSPrintOperation
// prints only the rows that happen to be on screen, with no repeated headers
// and no handling for a table wider than the paper.

enum DocumentPrinter {

    /// Shared page settings, so Page Setup sticks for the rest of the session.
    private static let sharedInfo = NSPrintInfo.shared

    static func pageSetup(window: NSWindow?) {
        let layout = NSPageLayout()
        if let window {
            layout.beginSheet(with: sharedInfo, modalFor: window,
                              delegate: nil, didEnd: nil, contextInfo: nil)
        } else {
            layout.runModal(with: sharedInfo)
        }
    }

    private static func printInfo() -> NSPrintInfo {
        // Copy so a print job never mutates the user's Page Setup.
        let info = (sharedInfo.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin    = max(info.topMargin,    54)   // room for the header line
        info.bottomMargin = max(info.bottomMargin, 54)   // room for the page number
        info.leftMargin   = max(info.leftMargin,   36)
        info.rightMargin  = max(info.rightMargin,  36)
        info.isVerticallyCentered   = false
        info.isHorizontallyCentered = false
        return info
    }

    // MARK: Text

    static func printText(_ text: String, name: String, fontSize: CGFloat, window: NSWindow?) {
        run(textOperation(text: text, name: name, fontSize: fontSize, info: printInfo()),
            window: window)
    }

    /// Builds the print job for the text editor. Separate from `printText` so the
    /// pagination can be exercised against a PDF without a print panel.
    static func textOperation(text: String, name: String,
                              fontSize: CGFloat, info: NSPrintInfo) -> NSPrintOperation {
        info.horizontalPagination = .fit
        info.verticalPagination   = .automatic

        let contentWidth = info.paperSize.width - info.leftMargin - info.rightMargin

        let container = NSTextContainer(size: NSSize(width: contentWidth,
                                                     height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        let view = PaginatedTextView(
            frame: NSRect(x: 0, y: 0, width: contentWidth, height: 1),
            textContainer: container
        )
        view.documentName        = name
        view.isEditable          = false
        view.isVerticallyResizable   = true
        view.isHorizontallyResizable = false
        view.textContainerInset  = .zero

        // Printing is always black ink on white paper — the on-screen paper theme
        // (sepia, dark) is a reading preference, not something to burn into a page.
        let font = NSFont.monospacedSystemFont(ofSize: min(fontSize, 11), weight: .regular)
        view.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor.black
            ])
        )
        // Force a layout pass and size the view to the laid-out text. Without this
        // the frame keeps its placeholder height and AppKit prints a single page,
        // clipping everything after it.
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        view.frame = NSRect(x: 0, y: 0,
                            width: contentWidth,
                            height: max(1, ceil(used.height)))

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = name
        return operation
    }

    // MARK: Grid

    static func printGrid(rows: [CSVRow], showHeaders: Bool, name: String, window: NSWindow?) {
        guard !rows.isEmpty else { return }
        run(gridOperation(rows: rows, showHeaders: showHeaders,
                          name: name, info: printInfo()), window: window)
    }

    static func gridOperation(rows: [CSVRow], showHeaders: Bool,
                              name: String, info: NSPrintInfo) -> NSPrintOperation {
        info.horizontalPagination = .clip
        info.verticalPagination   = .clip

        let view = CSVPrintView(rows: rows, showHeaders: showHeaders,
                                documentName: name, printInfo: info)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = name
        return operation
    }

    private static func run(_ operation: NSPrintOperation, window: NSWindow?) {
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    // MARK: Page furniture

    static func headerString(name: String) -> NSAttributedString {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return NSAttributedString(string: "\(name)\t\(formatter.string(from: Date()))",
                                  attributes: pageFurnitureAttributes(alignment: .left,
                                                                      tabAt: nil))
    }

    static func pageFurnitureAttributes(alignment: NSTextAlignment,
                                        tabAt rightEdge: CGFloat?) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        if let rightEdge {
            style.tabStops = [NSTextTab(textAlignment: .right, location: rightEdge)]
        }
        return [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.darkGray,
            .paragraphStyle: style
        ]
    }
}

// MARK: - Text view that draws a header and footer on every page

private final class PaginatedTextView: NSTextView {
    var documentName: String = "Untitled"

    /// Called once per page with the full paper size (margins included), which is
    /// exactly the space the header and footer need to live in.
    override func drawPageBorder(with borderSize: NSSize) {
        guard let info = NSPrintOperation.current?.printInfo else { return }

        let left  = info.leftMargin
        let right = borderSize.width - info.rightMargin
        let width = right - left

        // Page-border drawing happens in an UNFLIPPED context even though the text
        // view itself is flipped: y counts up from the bottom of the sheet here.
        let header = DocumentPrinter.headerString(name: documentName)
        let headerStyle = NSMutableParagraphStyle()
        headerStyle.tabStops = [NSTextTab(textAlignment: .right, location: width)]
        let headerText = NSMutableAttributedString(attributedString: header)
        headerText.addAttribute(.paragraphStyle, value: headerStyle,
                                range: NSRange(location: 0, length: headerText.length))
        headerText.draw(in: NSRect(x: left, y: borderSize.height - 34,
                                   width: width, height: 14))

        let page = NSPrintOperation.current?.currentPage ?? 1
        let footer = NSAttributedString(
            string: "Page \(page)",
            attributes: DocumentPrinter.pageFurnitureAttributes(alignment: .center, tabAt: nil)
        )
        footer.draw(in: NSRect(x: left, y: 26, width: width, height: 14))

        NSColor.lightGray.setStroke()
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: left,  y: borderSize.height - 40))
        rule.line(to: NSPoint(x: right, y: borderSize.height - 40))
        rule.lineWidth = 0.5
        rule.stroke()
    }
}

// MARK: - CSV grid printer

/// Paginates a delimited grid across pages in both directions: the columns are
/// split into blocks that fit the paper width, and each block runs down through
/// all its rows before the next block starts (Excel's "down, then over"). The
/// column headers repeat on every page.
private final class CSVPrintView: NSView {
    private let rows: [CSVRow]
    private let showHeaders: Bool
    private let documentName: String

    private let dataFont   = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    private let headerFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)

    private let rowHeight: CGFloat  = 14
    private let cellPadding: CGFloat = 6

    private let pageRect: NSRect        // drawable area, origin at the margin corner
    private var columnWidths: [CGFloat] = []
    private var columnAlignments: [ColumnAlignment] = []
    private var columnBlocks: [Range<Int>] = []
    private var rowsPerPage  = 1
    private var rowPageCount = 1

    private var headerRow: [String] { showHeaders ? (rows.first?.cells ?? []) : [] }
    private var dataRows: ArraySlice<CSVRow> { showHeaders ? rows.dropFirst() : rows[...] }

    init(rows: [CSVRow], showHeaders: Bool, documentName: String, printInfo: NSPrintInfo) {
        self.rows         = rows
        self.showHeaders  = showHeaders
        self.documentName = documentName

        let width  = printInfo.paperSize.width  - printInfo.leftMargin - printInfo.rightMargin
        let height = printInfo.paperSize.height - printInfo.topMargin  - printInfo.bottomMargin
        self.pageRect = NSRect(x: 0, y: 0, width: width, height: height)

        super.init(frame: pageRect)
        computeLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    // MARK: Layout

    private func computeLayout() {
        let charWidth = ("0" as NSString).size(withAttributes: [.font: dataFont]).width
        let columnCount = rows.map(\.cells.count).max() ?? 0
        guard columnCount > 0 else { return }

        // Width per column from the longest value it holds, capped so one runaway
        // cell can't push every other column off the page. The same pass collects
        // each column's values so the printed sheet aligns the way the screen does.
        var widths: [CGFloat] = []
        var alignments: [ColumnAlignment] = []
        for column in 0..<columnCount {
            var longest = column < headerRow.count ? headerRow[column].count : 0
            var values: [String] = []
            for row in dataRows where column < row.cells.count {
                longest = max(longest, row.cells[column].count)
                values.append(row.cells[column])
            }
            let width = min(CGFloat(min(longest, 40)) * charWidth + cellPadding * 2,
                            pageRect.width)
            widths.append(max(width, charWidth * 3))
            alignments.append(inferColumnAlignment(values))
        }
        columnWidths     = widths
        columnAlignments = alignments

        // Split into blocks that each fit the page width.
        var blocks: [Range<Int>] = []
        var start = 0
        var running: CGFloat = 0
        for (index, width) in widths.enumerated() {
            if running + width > pageRect.width, index > start {
                blocks.append(start..<index)
                start = index
                running = 0
            }
            running += width
        }
        blocks.append(start..<columnCount)
        columnBlocks = blocks

        let bodyTop    = titleHeight + (showHeaders ? rowHeight + 4 : 0)
        let bodyHeight = pageRect.height - bodyTop - footerHeight
        rowsPerPage    = max(1, Int(bodyHeight / rowHeight))
        rowPageCount   = max(1, Int(ceil(Double(dataRows.count) / Double(rowsPerPage))))
    }

    private var titleHeight: CGFloat  { 22 }
    private var footerHeight: CGFloat { 18 }

    private var pageCount: Int { max(1, columnBlocks.count * rowPageCount) }

    // MARK: NSView printing

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pageCount)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect { pageRect }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()

        let page       = (NSPrintOperation.current?.currentPage ?? 1) - 1
        let blockIndex = min(page / max(1, rowPageCount), max(0, columnBlocks.count - 1))
        let rowPage    = page % max(1, rowPageCount)
        guard columnBlocks.indices.contains(blockIndex) else { return }
        let block = columnBlocks[blockIndex]

        drawTitle(block: block)
        var y = titleHeight
        if showHeaders {
            drawRow(cells: headerRow, block: block, y: y, font: headerFont,
                    banded: false, centered: true)
            y += rowHeight
            NSColor.darkGray.setStroke()
            let rule = NSBezierPath()
            rule.move(to: NSPoint(x: 0, y: y + 1))
            rule.line(to: NSPoint(x: blockWidth(block), y: y + 1))
            rule.lineWidth = 0.75
            rule.stroke()
            y += 4
        }

        let all   = Array(dataRows)
        let start = rowPage * rowsPerPage
        let end   = min(start + rowsPerPage, all.count)
        if start < end {
            for (offset, row) in all[start..<end].enumerated() {
                drawRow(cells: row.cells, block: block, y: y + CGFloat(offset) * rowHeight,
                        font: dataFont, banded: (start + offset) % 2 == 1)
            }
        }

        drawFooter(page: page, blockIndex: blockIndex, block: block)
    }

    private func blockWidth(_ block: Range<Int>) -> CGFloat {
        block.reduce(0) { $0 + columnWidths[$1] }
    }

    private func drawTitle(block: Range<Int>) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: pageRect.width)]
        let title = NSAttributedString(
            string: "\(documentName)\t\(formatter.string(from: Date()))",
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                         .foregroundColor: NSColor.black,
                         .paragraphStyle: style]
        )
        title.draw(in: NSRect(x: 0, y: 2, width: pageRect.width, height: 14))
    }

    /// `centered` overrides the per-column alignment for the header row, matching
    /// the on-screen table where headers are always centered.
    private func drawRow(cells: [String], block: Range<Int>, y: CGFloat,
                         font: NSFont, banded: Bool, centered: Bool = false) {
        if banded {
            NSColor(white: 0.94, alpha: 1).setFill()
            NSRect(x: 0, y: y, width: blockWidth(block), height: rowHeight).fill()
        }

        var x: CGFloat = 0
        for column in block {
            let width = columnWidths[column]
            let value = column < cells.count ? cells[column] : ""

            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.alignment = centered
                ? .center
                : (columnAlignments.indices.contains(column)
                    ? columnAlignments[column].textAlignment
                    : .left)

            (value as NSString).draw(
                in: NSRect(x: x + cellPadding, y: y + 1,
                           width: max(0, width - cellPadding * 2), height: rowHeight - 2),
                withAttributes: [.font: font,
                                 .foregroundColor: NSColor.black,
                                 .paragraphStyle: style]
            )
            x += width
        }
    }

    private func drawFooter(page: Int, blockIndex: Int, block: Range<Int>) {
        var label = "Page \(page + 1) of \(pageCount)"
        if columnBlocks.count > 1 {
            label += "  ·  columns \(block.lowerBound + 1)–\(block.upperBound)"
        }
        let footer = NSAttributedString(
            string: label,
            attributes: DocumentPrinter.pageFurnitureAttributes(alignment: .center, tabAt: nil)
        )
        footer.draw(in: NSRect(x: 0, y: pageRect.height - footerHeight,
                               width: pageRect.width, height: 14))
    }
}
