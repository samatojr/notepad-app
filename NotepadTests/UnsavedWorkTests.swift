import Foundation
import Testing
@testable import Notepad

// Regression tests for the 4.0 data-loss report: an untitled tab with typing in
// it, a second tab opened beside it, and closing lost both — silently, with
// nothing to recover from.
//
// The close path itself is AppKit window lifecycle and cannot be exercised
// headlessly. What CAN be pinned down are the two decisions it hangs on: which
// documents hold work that closing would destroy, and which of those are worth
// stopping the user for. Both used to be inline expressions duplicated between
// the quit handler and Clear Session, reachable from neither of the two closing
// gestures people actually use.

struct UnsavedWorkTests {

    private let file = URL(fileURLWithPath: "/tmp/notes.txt")

    // MARK: - holdsUnsavedWork: would closing destroy something?

    @Test("Typing in an untitled tab is work")
    func untitledWithTextIsWork() {
        #expect(holdsUnsavedWork(fileURL: nil, isModified: true, text: "hello"))
    }

    @Test("An empty untitled tab is not")
    func untitledEmptyIsNotWork() {
        #expect(!holdsUnsavedWork(fileURL: nil, isModified: false, text: ""))
        // Even flagged as modified: a blank document has nothing in it to lose.
        #expect(!holdsUnsavedWork(fileURL: nil, isModified: true, text: ""))
    }

    // The case that makes this a separate predicate from needsSavePrompt.
    // A tab restored from the session comes back holding its text with
    // isModified false. Judging it on the modified flag would let a close throw
    // away work that had already survived one quit — the reported bug, but
    // hitting text the user had every reason to think was safe.
    @Test("A restored untitled tab still holds work, edited this run or not")
    func restoredUntitledIsStillWork() {
        #expect(holdsUnsavedWork(fileURL: nil, isModified: false, text: "restored draft"))
    }

    @Test("A saved file is work only while it has unsaved edits")
    func fileBackedFollowsModifiedFlag() {
        #expect(holdsUnsavedWork(fileURL: file, isModified: true, text: "edited"))
        #expect(!holdsUnsavedWork(fileURL: file, isModified: false, text: "on disk"))
    }

    // A file-backed document whose buffer is empty is NOT harmless: emptying a
    // file is an edit like any other, and closing without recording it loses it.
    @Test("Emptying a saved file counts as work")
    func emptiedFileIsWork() {
        #expect(holdsUnsavedWork(fileURL: file, isModified: true, text: ""))
    }

    // MARK: - needsSavePrompt: should the discard stop and ask?

    // The scratch pad's whole point. Closing or quitting keeps untitled text —
    // in the session, or in the closed-tab buffer — so there is nothing to warn
    // about. Four scratch tabs used to mean four dialogs on the way out, which
    // is what made "just close it, it comes back" untrue in practice.
    @Test("Scratch tabs are never nagged about on a recoverable discard")
    func scratchIsSilent() {
        #expect(!needsSavePrompt(fileURL: nil, isModified: true,  text: "draft"))
        #expect(!needsSavePrompt(fileURL: nil, isModified: false, text: "restored draft"))
        #expect(!needsSavePrompt(fileURL: nil, isModified: true,  text: ""))
    }

    // A named file is the opposite case: the buffer has diverged from disk, and
    // the disk copy is what every other program on the machine will show.
    @Test("A named file with unsaved edits still asks")
    func namedFileAsks() {
        #expect(needsSavePrompt(fileURL: file, isModified: true, text: "edited"))
        #expect(needsSavePrompt(fileURL: file, isModified: true, text: ""))
    }

    @Test("A clean file asks nothing")
    func cleanFileSilent() {
        #expect(!needsSavePrompt(fileURL: file, isModified: false, text: "on disk"))
    }

    // Clear Session wipes the session AND the recovery buffer, so the safety net
    // that justifies staying quiet about scratch text is itself being removed.
    @Test("A permanent discard asks about scratch text too")
    func permanentDiscardAsksAboutScratch() {
        #expect(needsSavePrompt(fileURL: nil, isModified: true, text: "draft",
                                discard: .permanent))
        #expect(needsSavePrompt(fileURL: nil, isModified: false, text: "restored draft",
                                discard: .permanent))
        // Still nothing to lose in an empty tab.
        #expect(!needsSavePrompt(fileURL: nil, isModified: true, text: "",
                                 discard: .permanent))
    }

    // The invariant that keeps the policy honest: a permanent discard must never
    // destroy something silently. Anything holding work has to be offered first.
    @Test("Nothing with work in it is permanently discarded without asking",
          arguments: [nil, URL(fileURLWithPath: "/tmp/notes.txt")] as [URL?],
          [true, false])
    func permanentNeverSilentlyDestroys(url: URL?, modified: Bool) {
        for text in ["", "content"] {
            if holdsUnsavedWork(fileURL: url, isModified: modified, text: text) {
                #expect(needsSavePrompt(fileURL: url, isModified: modified, text: text,
                                        discard: .permanent))
            }
        }
    }

    // The counterpart, and the one that matters most: staying quiet must never
    // mean losing something. Whatever the app declines to ask about has to be
    // safe by some other route.
    //
    // There are exactly three ways silence is safe, and a document that is none
    // of them would be discarded without a word:
    //   - it is snapshotted into the session or the recovery buffer;
    //   - it is empty, so there is nothing to lose;
    //   - it is a CLEAN file-backed document, whose text is on disk already.
    // That last one is why this is not simply "silence implies snapshot" —
    // asserting that was wrong, and this test caught it.
    @Test("Staying quiet never means losing something",
          arguments: [nil, URL(fileURLWithPath: "/tmp/notes.txt")] as [URL?],
          [true, false])
    func silenceIsAlwaysSafe(url: URL?, modified: Bool) {
        for text in ["", "content"] {
            let asked = needsSavePrompt(fileURL: url, isModified: modified, text: text)
            let kept  = holdsUnsavedWork(fileURL: url, isModified: modified, text: text)
            guard !asked, !kept else { continue }
            let alreadyOnDisk = url != nil && !modified
            #expect(text.isEmpty || alreadyOnDisk)
        }
    }

    // MARK: - The recovery buffer's cap

    @Test("A short buffer is left alone")
    func keepsShortBuffer() {
        #expect(trimmedClosedTabs([1, 2, 3], limit: 10) == [1, 2, 3])
    }

    // Newest last, because popClosed() takes from the end.
    @Test("An overfull buffer drops the oldest entries")
    func dropsOldest() {
        #expect(trimmedClosedTabs(Array(1...15), limit: 10) == Array(6...15))
    }

    @Test("Exactly at the limit is not trimmed")
    func exactlyAtLimit() {
        #expect(trimmedClosedTabs(Array(1...10), limit: 10) == Array(1...10))
    }

    @Test("A zero limit keeps nothing, rather than crashing on suffix")
    func zeroLimit() {
        #expect(trimmedClosedTabs([1, 2, 3], limit: 0).isEmpty)
    }

    // Each entry carries a whole document's text, so the default cap is what
    // stops the preferences blob growing by a document on every close.
    @Test("The default cap is applied when none is given")
    func defaultLimitApplies() {
        #expect(trimmedClosedTabs(Array(1...50)).count == closedTabBufferLimit)
    }
}
