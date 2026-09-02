import Foundation
import AppKit
import Combine

// MARK: - CSV sort key

struct CSVSortKey: Codable, Equatable {
    var column: Int
    var ascending: Bool
}

// MARK: - Persisted state for one document

struct DocumentSessionState: Codable {
    var sessionID: UUID
    var unsavedText: String?          // non-nil only when file has no URL
    var bookmarkData: Data?           // security-scoped bookmark for saved files
    var wordWrap: Bool
    var showStatusBar: Bool
    var windowIndex: Int              // ordering for restore
    var fontSize: CGFloat?            // nil → default 13; optional for old-session compat
    // CSV/TSV view state — all optional for backward compat with pre-2.2 sessions
    var csvDelimiter: String?         // "," or "\t"; nil = not a tabular file
    var csvIsTableView: Bool?         // nil = not applicable
    var csvSortKeys: [CSVSortKey]?    // nil / empty = unsorted

    /// An untitled document with no text has nothing to restore — it comes back as a
    /// blank "Untitled" window. Recording those means a quit persists whatever blank
    /// windows happened to be open, and the next launch faithfully reopens them all.
    var isWorthRestoring: Bool {
        bookmarkData != nil || !(unsavedText ?? "").isEmpty
    }
}

// MARK: - Session Manager

final class SessionManager {
    static let shared = SessionManager()
    private init() {}

    private let key = "NotepadSession"
    private var pending: [DocumentSessionState] = []

    func loadAndEnqueue() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let states = try? JSONDecoder().decode([DocumentSessionState].self, from: data)
        else { return }
        // Filter on the way in as well as on the way out: sessions written by builds
        // before this filter existed still hold blank entries, and each one would
        // reopen as an empty window.
        pending = states.filter(\.isWorthRestoring)
                        .sorted { $0.windowIndex < $1.windowIndex }
    }

    func popPending() -> DocumentSessionState? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    func hasPending() -> Bool { !pending.isEmpty }
    func pendingCount() -> Int { pending.count }

    func clearSession() {
        pending = []
        save(states: [])
        clearClosedTabs()
    }

    /// Persists the session, dropping documents that aren't worth restoring. Every
    /// entry saved here reopens as a window on the next launch, so blank untitled
    /// documents must not be recorded — see `isWorthRestoring`.
    func save(states: [DocumentSessionState]) {
        let worthKeeping = states.filter(\.isWorthRestoring)
        guard let data = try? JSONEncoder().encode(worthKeeping) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}

// MARK: - Closed Tabs Buffer (LIFO — most recently closed restored first)

extension SessionManager {
    private var closedTabsKey: String { "NotepadClosedTabs" }

    func pushClosed(_ state: DocumentSessionState) {
        var states = loadClosedTabs()
        states.append(state)
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: closedTabsKey)
        }
    }

    func popClosed() -> DocumentSessionState? {
        var states = loadClosedTabs()
        guard !states.isEmpty else { return nil }
        let state = states.removeLast()
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: closedTabsKey)
        }
        return state
    }

    func hasClosedTab() -> Bool { !loadClosedTabs().isEmpty }

    func clearClosedTabs() {
        UserDefaults.standard.removeObject(forKey: closedTabsKey)
    }

    private func loadClosedTabs() -> [DocumentSessionState] {
        guard let data = UserDefaults.standard.data(forKey: closedTabsKey),
              let states = try? JSONDecoder().decode([DocumentSessionState].self, from: data)
        else { return [] }
        return states
    }
}

// MARK: - App State

final class AppState {
    static let shared = AppState()
    private init() {}
    var isTerminating = false
    var isClearingSession = false
}

// MARK: - Pending Open URL (for opening a file in a new tab)

final class PendingURLManager {
    static let shared = PendingURLManager()
    private init() {}
    var pendingURL: URL?

    /// Open-file broadcasts already taken by a window. ContentView cannot reliably
    /// identify "the active window" by comparing NSApp.keyWindow to its own window
    /// (they often differ, and a window may never capture its own reference), so
    /// each broadcast carries a token and the first view to claim it handles the
    /// file. Guarantees exactly one open, and that it is never silently dropped.
    private var claimedTokens: Set<UUID> = []

    func claim(_ token: UUID) -> Bool {
        guard !claimedTokens.contains(token) else { return false }
        claimedTokens.insert(token)
        if claimedTokens.count > 64 { claimedTokens.removeAll() }
        return true
    }
}

// MARK: - Session Tab Claims

/// One-shot tokens for the session-restore broadcast, so exactly one window acts on
/// each one. ContentView cannot pick "the active window" by comparing NSApp.keyWindow
/// to its own window — at launch the key window is routinely some other window, and
/// the guard silently dropped every restore notification, leaving the session short by
/// however many tabs it missed. Same approach PendingURLManager uses for file opens.
final class SessionTabClaims {
    static let shared = SessionTabClaims()
    private init() {}

    private var claimedTokens: Set<UUID> = []

    func claim(_ token: UUID) -> Bool {
        guard !claimedTokens.contains(token) else { return false }
        claimedTokens.insert(token)
        if claimedTokens.count > 64 { claimedTokens.removeAll() }
        return true
    }
}

// MARK: - Recent Files Manager

final class RecentFilesManager: ObservableObject {
    static let shared = RecentFilesManager()
    private init() { load() }

    private let key = "NotepadRecentFiles"
    @Published var recentURLs: [URL] = []

    func add(_ url: URL) {
        recentURLs.removeAll { $0 == url }
        recentURLs.insert(url, at: 0)
        if recentURLs.count > 20 { recentURLs = Array(recentURLs.prefix(20)) }
        save()
    }

    func remove(_ url: URL) {
        recentURLs.removeAll { $0 == url }
        save()
    }

    func clearAll() {
        recentURLs = []
        save()
    }

    private func save() {
        let paths = recentURLs.map { $0.path }
        UserDefaults.standard.set(paths, forKey: key)
    }

    private func load() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        recentURLs = paths.compactMap { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
