import AppKit

// MARK: - The close path
//
// Everything here exists because closing a window was the one way out of the app
// that neither asked nor recorded anything. See UnsavedWork.swift for the full
// account of the data-loss report this answers.
//
// Two layers, deliberately independent:
//
//   PREVENT — ClosePromptDelegate answers windowShouldClose: so ⌘W and the red
//             button confirm before discarding edits, the same way quitting has
//             always done and the same way the toolbar's Close Tab button does.
//   RECOVER — noteWindowWillClose(_:) snapshots whatever was only in memory into
//             the closed-tab buffer and re-persists the session, so even a close
//             that goes through leaves the work retrievable with ⇧⌘T.
//
// The recover layer does not depend on the prevent layer working. If the delegate
// proxy ever stops being installed, closing still costs nothing permanent.

enum SaveOnCloseChoice {
    case save, discard, cancel
}

/// The standard "Save changes to X?" alert, in one place.
///
/// Quit and Clear Session each had their own copy of this, with subtly different
/// wording and no third user — the close path, which needed it most, had none.
@MainActor
func promptToSave(_ document: NotepadDocument, consequence: String) -> SaveOnCloseChoice {
    let alert = NSAlert.make()
    alert.messageText = "Save changes to \"\(document.displayName)\"?"
    alert.informativeText = consequence
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Don't Save")
    alert.addButton(withTitle: "Cancel")
    alert.alertStyle = .warning
    switch alert.runModal() {
    case .alertFirstButtonReturn:  return .save
    case .alertThirdButtonReturn:  return .cancel
    default:                       return .discard
    }
}

/// Runs the prompt and carries out the answer. Returns false when the close
/// should be abandoned — either the user cancelled, or they chose Save and the
/// save did not happen (an untitled document whose save panel they dismissed).
@MainActor
func resolveUnsavedWork(in document: NotepadDocument, consequence: String) -> Bool {
    guard needsSavePrompt(fileURL: document.fileURL,
                          isModified: document.isModified,
                          text: document.text) else { return true }

    switch promptToSave(document, consequence: consequence) {
    case .cancel:
        return false
    case .discard:
        return true
    case .save:
        document.saveDocument()
        // saveDocument clears isModified on a successful write. Still modified
        // means the write failed or the save panel was dismissed, and closing
        // now would throw away the work the user just asked to keep.
        return !document.isModified
    }
}

/// Called as a document's window closes, whatever route it took there.
///
/// SwiftUI's `.onDisappear` used to be the only teardown hook, and it is the
/// wrong signal twice over: it reports that a VIEW left the hierarchy, which is
/// not the same event as a document going away, and it arrives with no
/// opportunity to keep anything.
@MainActor
func noteWindowWillClose(_ document: NotepadDocument) {
    // Quitting persists every open document wholesale; snapshotting each window
    // as it goes would push the whole session into the recovery buffer.
    guard !AppState.shared.isTerminating else { return }

    // Clear Session is a deliberate discard that has already asked about every
    // modified document. Unregister — the windows really are going — but keep
    // nothing: a recovery buffer full of what the user just cleared, retrievable
    // with one ⇧⌘T, would defeat the point of clearing it.
    guard !AppState.shared.isClearingSession else {
        DocumentRegistry.shared.unregister(document)
        return
    }

    if holdsUnsavedWork(fileURL: document.fileURL,
                        isModified: document.isModified,
                        text: document.text) {
        SessionManager.shared.pushClosed(document.sessionState(index: 0))
    }
    DocumentRegistry.shared.unregister(document)
    // The session is now short one document. Write it out rather than waiting
    // for quit — that wait is what made a close unrecoverable.
    SessionManager.shared.persistOpenDocuments()
}

// MARK: - Close prompt delegate

/// Adds a save prompt to the close paths AppKit owns — ⌘W, the red button,
/// Close All Tabs — without taking SwiftUI's window delegate away from it.
///
/// SwiftUI owns `window.delegate` and needs it; the scene tears itself down
/// through that object. So this stands in front as a proxy: it answers the one
/// message it cares about and forwards every other selector, including
/// `respondsToSelector:`, to the delegate it displaced.
final class ClosePromptDelegate: NSObject, NSWindowDelegate {
    // Strong on purpose. NSWindow.delegate is a weak reference, so nothing else
    // is guaranteed to be holding SwiftUI's delegate once we replace it.
    // nonisolated(unsafe) because the forwarding overrides below are nonisolated:
    // it is a `let`, set before the proxy is installed and never touched again.
    nonisolated(unsafe) private let wrapped: NSWindowDelegate?

    init(wrapping wrapped: NSWindowDelegate?) {
        self.wrapped = wrapped
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Quit and Clear Session have already asked about every modified
        // document by the time they start closing windows. Asking again here
        // would make one confirmation into one per window.
        if AppState.shared.isTerminating || AppState.shared.isClearingSession {
            return wrapped?.windowShouldClose?(sender) ?? true
        }
        if let document = DocumentRegistry.shared.document(for: sender),
           !resolveUnsavedWork(in: document,
                               consequence: "If you don't save, your changes will be lost.") {
            return false
        }
        return wrapped?.windowShouldClose?(sender) ?? true
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return wrapped?.responds(to: aSelector) ?? false
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        wrapped
    }
}

/// Installs the close prompt on a document window, once.
@MainActor
func installClosePrompt(on window: NSWindow) {
    guard !(window.delegate is ClosePromptDelegate) else { return }
    let proxy = ClosePromptDelegate(wrapping: window.delegate)
    closePromptDelegates.setObject(proxy, forKey: window)
    window.delegate = proxy
}

/// Keeps each proxy alive for as long as its window, and no longer. AppKit only
/// holds `delegate` weakly, so without this the proxy would deallocate the
/// moment it was installed and the prompt would silently never appear.
@MainActor
private let closePromptDelegates = NSMapTable<NSWindow, ClosePromptDelegate>.weakToStrongObjects()
