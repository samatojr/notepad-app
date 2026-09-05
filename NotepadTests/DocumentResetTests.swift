import Foundation
import Testing
@testable import Notepad

// Closing the last tab resets the document rather than closing the window, so
// the window is supposed to go back to reading "Untitled". Reported from the
// beta: the old file name stays in the title bar instead.
//
// These pin down the MODEL half of that. If they pass, reset() is doing its job
// and the stale name is the window title not being re-applied — a view-layer
// problem, not a document one.

@MainActor
struct DocumentResetTests {

    @Test("An untitled document is named Untitled")
    func untitledByDefault() {
        #expect(NotepadDocument().displayName == "Untitled")
    }

    @Test("A document with a file takes the file's name")
    func namedAfterItsFile() {
        let doc = NotepadDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/example.csv")
        #expect(doc.displayName == "example.csv")
    }

    @Test("reset() puts the name back to Untitled")
    func resetClearsTheName() {
        let doc = NotepadDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/example.csv")
        doc.text = "a,b\n1,2\n"
        doc.isModified = true

        doc.reset()

        #expect(doc.displayName == "Untitled")
        #expect(doc.fileURL == nil)
        #expect(doc.text.isEmpty)
        #expect(!doc.isModified)
    }

    @Test("reset() clears the grid state too, so the next file starts clean")
    func resetClearsGridState() {
        let doc = NotepadDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/example.csv")
        doc.csvRows = [CSVRow(cells: ["a", "b"])]
        doc.csvDelimiter = ","
        doc.csvIsTableView = true
        doc.csvSortKeys = [CSVSortKey(column: 1, ascending: true)]

        doc.reset()

        #expect(doc.csvRows.isEmpty)
        #expect(doc.csvDelimiter == nil)
        #expect(!doc.csvIsTableView)
        #expect(doc.csvSortKeys.isEmpty)
    }
}
