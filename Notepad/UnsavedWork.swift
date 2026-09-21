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

/// What a discard is about to do to the work, which decides whether it is worth
/// stopping the user over.
enum DiscardKind {
    /// Closing a window, or quitting. Whatever is only in memory survives — in
    /// the session, or in the closed-tab buffer — so there is nothing to warn
    /// about except a file on disk going stale.
    case recoverable
    /// Clear Session. The session AND the recovery buffer are both wiped, so
    /// anything only in memory really is about to cease to exist.
    case permanent
}

/// True when a discard should stop and ask the user first.
///
/// The asymmetry is the whole point, and it is what makes this a scratch pad
/// rather than a document editor wearing one's clothes:
///
///   - An UNTITLED tab is the app's core use — somewhere to keep loose text
///     without ceremony. Its content is captured whole by the session, so
///     closing costs nothing and asking is pure noise. Four scratch tabs used
///     to mean four dialogs on the way out.
///   - A NAMED file is different: its buffer has diverged from what is on disk,
///     and the disk copy is what every other program on the machine will show.
///     That divergence is worth a question.
///
/// A `permanent` discard drops the distinction, because then the scratch tab's
/// safety net is going away too.
nonisolated func needsSavePrompt(fileURL: URL?, isModified: Bool, text: String,
                                 discard: DiscardKind = .recoverable) -> Bool {
    switch discard {
    case .recoverable:
        return fileURL != nil && isModified
    case .permanent:
        return holdsUnsavedWork(fileURL: fileURL, isModified: isModified, text: text)
    }
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
