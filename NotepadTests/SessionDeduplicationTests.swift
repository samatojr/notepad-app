import Foundation
import Testing
@testable import Notepad

// Regression tests for the window/session growth bug.
//
// Symptom: launch by double-clicking a file, quit, launch again — and the same
// file comes back in two windows, then three, then four. The session blob in
// UserDefaults grew a bookmark per duplicate, without bound.

@MainActor
struct SessionDeduplicationTests {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test("The same file opened many times collapses to one entry")
    func collapsesRepeatsOfOneFile() {
        // Exactly the shape a bloated session had: four windows, one file.
        let notes = url("/tmp/notes.csv")
        #expect(indicesKeepingFirstPerURL([notes, notes, notes, notes]) == [0])
    }

    @Test("Distinct files are all kept, in window order")
    func keepsDistinctFiles() {
        let kept = indicesKeepingFirstPerURL([url("/a.txt"), url("/b.txt"), url("/c.txt")])
        #expect(kept == [0, 1, 2])
    }

    @Test("The FIRST occurrence of each file wins")
    func keepsFirstOccurrence() {
        let a = url("/a.txt"), b = url("/b.txt")
        #expect(indicesKeepingFirstPerURL([a, b, a, b, a]) == [0, 1])
    }

    // Untitled documents share a nil URL but are genuinely different documents.
    // Treating them as duplicates would silently discard unsaved work on quit —
    // a far worse bug than the one being fixed.
    @Test("Untitled documents are never treated as duplicates of each other")
    func untitledAreAllDistinct() {
        #expect(indicesKeepingFirstPerURL([nil, nil, nil]) == [0, 1, 2])
    }

    @Test("Untitled documents survive alongside duplicate files")
    func untitledSurviveMixedIn() {
        let a = url("/a.txt")
        // window order: a, untitled, a again, untitled
        #expect(indicesKeepingFirstPerURL([a, nil, a, nil]) == [0, 1, 3])
    }

    @Test("An empty session stays empty")
    func emptyIsEmpty() {
        #expect(indicesKeepingFirstPerURL([]).isEmpty)
    }

    @Test("A session with nothing to collapse is returned unchanged")
    func alreadyCleanIsUnchanged() {
        let urls: [URL?] = [url("/a.txt"), nil, url("/b.txt")]
        #expect(indicesKeepingFirstPerURL(urls) == [0, 1, 2])
    }

    @Test("Paths differing only by name are not merged")
    func similarPathsAreDistinct() {
        let kept = indicesKeepingFirstPerURL([url("/dir/a.txt"), url("/dir/ab.txt")])
        #expect(kept == [0, 1])
    }
}
