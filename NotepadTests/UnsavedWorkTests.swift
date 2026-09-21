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

    // MARK: - needsSavePrompt: should closing stop and ask?

    @Test("Unsaved edits get a prompt")
    func promptsForEdits() {
        #expect(needsSavePrompt(fileURL: nil, isModified: true, text: "draft"))
        #expect(needsSavePrompt(fileURL: file, isModified: true, text: "edited"))
    }

    @Test("Nothing to lose, nothing to ask")
    func silentWhenClean() {
        #expect(!needsSavePrompt(fileURL: file, isModified: false, text: "on disk"))
        #expect(!needsSavePrompt(fileURL: nil, isModified: false, text: ""))
        #expect(!needsSavePrompt(fileURL: nil, isModified: true, text: ""))
    }

    // Narrower than holdsUnsavedWork on purpose: this document goes back into
    // the session untouched, so interrupting the user over it would be a nag
    // about something that was never at risk. It is still snapshotted.
    @Test("A restored, unedited tab is recorded without a prompt")
    func restoredUntitledIsNotNagged() {
        #expect(!needsSavePrompt(fileURL: nil, isModified: false, text: "restored draft"))
        #expect(holdsUnsavedWork(fileURL: nil, isModified: false, text: "restored draft"))
    }

    // The invariant that keeps the two predicates honest. If anything ever
    // prompts without also being snapshotted, "Don't Save" becomes unrecoverable
    // again — which is exactly the hole this release closes.
    @Test("Anything worth a prompt is also worth keeping",
          arguments: [nil, URL(fileURLWithPath: "/tmp/notes.txt")] as [URL?],
          [true, false])
    func promptImpliesSnapshot(url: URL?, modified: Bool) {
        for text in ["", "content"] {
            if needsSavePrompt(fileURL: url, isModified: modified, text: text) {
                #expect(holdsUnsavedWork(fileURL: url, isModified: modified, text: text))
            }
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
