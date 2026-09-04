import Foundation

// MARK: - Session de-duplication
//
// Opening a file that the session had already restored produced a SECOND window
// for the same file: session restore reopens it, and the Finder / `open` request
// opens it again, with nothing checking whether that URL was already on screen.
// Quitting then persisted both, so the next launch restored two and added a
// third. The window count — and the session blob in UserDefaults, which carries
// a security-scoped bookmark per entry — grew on every single launch.
//
// Two halves fix it: refuse to open a duplicate window in the first place (see
// DocumentRegistry.openDocument(for:)), and collapse any duplicates that a
// previously-bloated session still holds, which is what this does. Existing
// oversized sessions heal themselves on the next quit.

/// Indices of the entries to keep, given each entry's file URL in window order.
///
/// Keeps the FIRST entry for each file URL. Entries with no URL are untitled
/// documents — every one of those is a distinct unsaved document, so they are
/// all kept.
nonisolated func indicesKeepingFirstPerURL(_ urls: [URL?]) -> [Int] {
    var seen = Set<URL>()
    var kept: [Int] = []
    kept.reserveCapacity(urls.count)

    for (index, url) in urls.enumerated() {
        guard let url else {
            kept.append(index)      // untitled: never a duplicate of anything
            continue
        }
        if seen.insert(url).inserted { kept.append(index) }
    }
    return kept
}
