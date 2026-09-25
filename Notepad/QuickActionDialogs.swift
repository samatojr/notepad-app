import AppKit

// MARK: - Quick action dialogs
//
// The small forms behind the grid's quick actions. Each is an NSAlert with an
// accessory view, like Rename Column and Go to Line, so they behave like every
// other prompt in the app: Return confirms, Escape cancels.

enum QuickActionDialogs {

    /// Separators offered by name. Anything else typed into the box is used
    /// literally, so "|" or " and " work without a menu entry of their own.
    static let joinSeparators: [(name: String, value: String)] = [
        ("Space", " "), ("Comma and space", ", "), ("Comma", ","),
        ("Hyphen", " - "), ("Slash", "/"), ("Nothing", ""),
    ]
    static let splitSeparators: [(name: String, value: String)] = [
        ("Space", " "), ("Comma", ","), ("Semicolon", ";"),
        ("Hyphen", "-"), ("Slash", "/"), ("Vertical bar", "|"),
    ]

    static func separator(from text: String, choices: [(name: String, value: String)]) -> String {
        choices.first { $0.name.caseInsensitiveCompare(text) == .orderedSame }?.value ?? text
    }

    /// Asks which separator to join or split on. Returns nil on Cancel.
    static func askSeparator(title: String, message: String, button: String,
                             choices: [(name: String, value: String)]) -> String? {
        let alert = NSAlert.make()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")

        let box = NSComboBox(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
        box.addItems(withObjectValues: choices.map(\.name))
        box.stringValue = choices[0].name
        box.completes = true
        box.toolTip = "Pick one, or type any character to use it"
        alert.accessoryView = box
        alert.window.initialFirstResponder = box

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return separator(from: box.stringValue, choices: choices)
    }

    /// Asks how to build a calculated column. Returns nil on Cancel.
    static func askCalculation(columns: [ColumnCalculationForm.Column],
                               sampleRows: [(displayRow: Int, cells: [String])],
                               preferredLeft: Int,
                               preferredRight: Int? = nil) -> ColumnCalculationForm.Result? {
        let alert = NSAlert.make()
        alert.messageText = "New Column from Calculation"
        alert.informativeText = "Adds a column of results next to the columns you pick. "
            + "The values are fixed — if the numbers change later, run it again."
        alert.addButton(withTitle: "Add Column")
        alert.addButton(withTitle: "Cancel")

        let form = ColumnCalculationForm(columns: columns, sampleRows: sampleRows,
                                         preferredLeft: preferredLeft, preferredRight: preferredRight)
        form.onValidityChange = { [weak alert] valid in alert?.buttons.first?.isEnabled = valid }
        alert.accessoryView = form
        alert.layout()
        form.refresh()

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return form.result
    }
}

// MARK: - Calculation form

/// Column ▾  operation ▾  column-or-number ▾, a name for the new column, how
/// many decimal places, and a live preview computed from the first row that has
/// numbers — so the user sees "$1.50 × 10 = $15.00" before anything is written.
final class ColumnCalculationForm: NSView, NSTextFieldDelegate {

    struct Column {
        let title: String
        let isNumeric: Bool
    }

    struct Result {
        let calculation: ColumnCalculation
        let title: String
        /// Right of the rightmost column the calculation reads.
        let insertAt: Int
    }

    var onValidityChange: ((Bool) -> Void)?

    private let columns: [Column]
    private let sampleRows: [(displayRow: Int, cells: [String])]

    private let leftPopup      = NSPopUpButton(frame: .zero, pullsDown: false)
    private let operationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let rightPopup     = NSPopUpButton(frame: .zero, pullsDown: false)
    private let numberField    = NSTextField(string: "")
    private let nameField      = NSTextField(string: "")
    private let decimalsPopup  = NSPopUpButton(frame: .zero, pullsDown: false)
    private let preview        = NSTextField(wrappingLabelWithString: "")

    /// Once the user types a name, stop replacing it as the popups change.
    private var nameWasEdited = false

    /// Tag on the right-hand popup's "A number" item; column items use their index.
    private static let numberTag = -1

    init(columns: [Column], sampleRows: [(displayRow: Int, cells: [String])],
         preferredLeft: Int, preferredRight: Int? = nil) {
        self.columns = columns
        self.sampleRows = sampleRows
        super.init(frame: .zero)

        for (index, column) in columns.enumerated() {
            leftPopup.addItem(withTitle: column.title)
            leftPopup.lastItem?.tag = index
            rightPopup.addItem(withTitle: column.title)
            rightPopup.lastItem?.tag = index
        }
        rightPopup.menu?.addItem(.separator())
        rightPopup.addItem(withTitle: "A number…")
        rightPopup.lastItem?.tag = Self.numberTag

        for operation in ArithmeticOperation.allCases {
            operationPopup.addItem(withTitle: "\(operation.rawValue)  \(Self.word(for: operation))")
        }
        operationPopup.selectItem(at: ArithmeticOperation.allCases.firstIndex(of: .multiply) ?? 0)

        decimalsPopup.addItem(withTitle: "Automatic")
        decimalsPopup.lastItem?.tag = -1
        for places in 0...4 {
            decimalsPopup.addItem(withTitle: "\(places)")
            decimalsPopup.lastItem?.tag = places
        }

        // Defaults: the column the user pointed at if it holds numbers, else the
        // first that does; then the second column they picked, or the next
        // number column along, falling back to typing a number when there is
        // only one.
        let numeric = columns.indices.filter { columns[$0].isNumeric }
        let left = columns.indices.contains(preferredLeft) && columns[preferredLeft].isNumeric
            ? preferredLeft : (numeric.first ?? max(0, min(preferredLeft, columns.count - 1)))
        leftPopup.selectItem(withTag: left)
        let picked = preferredRight.flatMap { columns.indices.contains($0) && $0 != left ? $0 : nil }
        if let right = picked
            ?? numeric.first(where: { $0 > left }) ?? numeric.first(where: { $0 != left }) {
            rightPopup.selectItem(withTag: right)
        } else {
            rightPopup.selectItem(withTag: Self.numberTag)
        }

        numberField.placeholderString = "e.g. 1.08 or 8%"
        numberField.delegate = self
        nameField.delegate = self
        preview.textColor = .secondaryLabelColor
        preview.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        for popup in [leftPopup, operationPopup, rightPopup, decimalsPopup] {
            popup.target = self
            popup.action = #selector(controlsChanged(_:))
        }
        for popup in [leftPopup, rightPopup] {
            popup.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        }

        buildLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildLayout() {
        func label(_ text: String) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.alignment = .right
            return field
        }
        let expression = NSStackView(views: [leftPopup, operationPopup, rightPopup])
        expression.spacing = 6

        let grid = NSGridView(views: [
            [label("Calculate:"), expression],
            [label("Number:"), numberField],
            [label("Column name:"), nameField],
            [label("Decimal places:"), decimalsPopup],
            [NSGridCell.emptyContentView, preview],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        numberField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        preview.preferredMaxLayoutWidth = 320

        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // NSAlert sizes its accessory from the frame, not from constraints.
        // The preview text changes, so leave it room for two lines.
        preview.stringValue = "Row 1: placeholder\nsecond line"
        setFrameSize(grid.fittingSize)
        preview.stringValue = ""
    }

    private static func word(for operation: ArithmeticOperation) -> String {
        switch operation {
        case .add:      return "plus"
        case .subtract: return "minus"
        case .multiply: return "times"
        case .divide:   return "divided by"
        }
    }

    // MARK: State

    private var operation: ArithmeticOperation {
        ArithmeticOperation.allCases[max(0, operationPopup.indexOfSelectedItem)]
    }

    private var usesNumber: Bool { rightPopup.selectedTag() == Self.numberTag }

    private var rightOperand: CalculationOperand? {
        if usesNumber { return operandNumber(numberField.stringValue).map(CalculationOperand.number) }
        return .column(rightPopup.selectedTag())
    }

    private var rightDescription: String {
        usesNumber ? numberField.stringValue.trimmingCharacters(in: .whitespaces)
                   : (rightPopup.titleOfSelectedItem ?? "")
    }

    var result: Result? {
        guard let right = rightOperand else { return nil }
        let left = leftPopup.selectedTag()
        let places = decimalsPopup.selectedTag()
        let calculation = ColumnCalculation(left: left, operation: operation, right: right,
                                            decimalPlaces: places >= 0 ? places : nil)
        var rightmost = left
        if case .column(let column) = right { rightmost = max(rightmost, column) }
        let title = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        return Result(calculation: calculation,
                      title: title.isEmpty ? defaultName : title,
                      insertAt: rightmost + 1)
    }

    private var defaultName: String {
        "\(leftPopup.titleOfSelectedItem ?? "") \(operation.rawValue) \(rightDescription)"
    }

    // MARK: Updates

    @objc private func controlsChanged(_ sender: Any?) { refresh() }

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSTextField) === nameField { nameWasEdited = true }
        refresh()
    }

    /// Re-derives everything that depends on the controls: whether a number is
    /// needed, the suggested name, the preview line and whether Add is allowed.
    func refresh() {
        numberField.isEnabled = usesNumber
        if !nameWasEdited { nameField.stringValue = defaultName }

        guard let result else {
            preview.stringValue = usesNumber && !numberField.stringValue.isEmpty
                ? "That isn't a number." : "Type the number to use."
            onValidityChange?(false)
            return
        }
        onValidityChange?(true)

        let calculation = result.calculation
        let example = sampleRows.lazy.compactMap { row -> String? in
            let value = calculation.value(for: row.cells)
            guard !value.isEmpty else { return nil }
            let left = calculation.left < row.cells.count ? row.cells[calculation.left] : ""
            let right: String
            switch calculation.right {
            case .column(let column): right = column < row.cells.count ? row.cells[column] : ""
            case .number:             right = self.rightDescription
            }
            return "Row \(row.displayRow + 1): \(left) \(calculation.operation.rawValue) \(right) = \(value)"
        }.first
        preview.stringValue = example ?? "No row has a number on both sides yet — those rows will be left blank."
    }
}
