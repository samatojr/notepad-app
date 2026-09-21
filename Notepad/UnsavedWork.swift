import Foundation

// MARK: - Work that exists only in memory
//
// Data-loss report against 4.0: an untitled tab with typing in it, a second tab
// opened beside it, and closing lost both — no prompt, nothing left in the
// session, no way back. Three gaps lined up to make that possible:
//
//   1. Closing a window asked nothing. Quit prompts for every modified document,
//      but ⌘W and the red close button went straight through AppKit: there was
//      no windowShouldClose: anywhere in the app. Only the toolbar's own Close
//      Tab button ever confirmed, so the two paths people actually use were the
//      two that didn't.
//   2. The session was written ONLY from applicationShouldTerminate. Until the
//      moment of quit, an untitled tab's text lived in memory and nowhere else.
//   3. Closing a tab unregistered its document. So even that quit-time save had
//      nothing left to record — by then the work was already unreachable, and
//      the empty result was written over the previous good session.
//
// Any one of the three alone is survivable. Together they turn a stray ⌘W into
// permanent loss, which is exactly what was reported.
//
// These two predicates are the shared answer to "would closing this destroy
// something?". They were previously inline, duplicated between the quit handler
// and Clear Session, and neither copy was reachable from the close path at all.

/// True when this document's content exists only in memory, so closing its
/// window without first recording it destroys the work.
///
/// An untitled document is judged on whether it holds any text at all, NOT on
/// `isModified`. A document restored from the session comes back with its text
/// and `isModified == false`; treating that as disposable would throw restored
/// work away a second time, which is the same bug wearing a different hat.
nonisolated func holdsUnsavedWork(fileURL: URL?, isModified: Bool, text: String) -> Bool {
    fileURL == nil ? !text.isEmpty : isModified
}

/// True when closing should stop and ask the user before going through with it.
///
/// Deliberately narrower than `holdsUnsavedWork`: an untitled document carrying
/// text it has not been edited since restore came out of the session and goes
/// straight back into it, so a prompt would nag about work that was never at
/// risk. Such a document is still snapshotted — recorded without interrupting.
nonisolated func needsSavePrompt(fileURL: URL?, isModified: Bool, text: String) -> Bool {
    isModified && !(fileURL == nil && text.isEmpty)
}

/// How many closed tabs the recovery buffer keeps.
///
/// The buffer holds the full text of every entry, so it cannot be unbounded —
/// the previous `pushClosed` appended forever, which would have grown the
/// preferences blob by the size of a document on every close had anything been
/// calling it.
nonisolated let closedTabBufferLimit = 10

/// The buffer trimmed to `limit`, keeping the most recently closed entries.
/// Newest is last, matching the LIFO pop.
nonisolated func trimmedClosedTabs<Entry>(_ entries: [Entry], limit: Int = closedTabBufferLimit) -> [Entry] {
    guard limit > 0 else { return [] }
    guard entries.count > limit else { return entries }
    return Array(entries.suffix(limit))
}
