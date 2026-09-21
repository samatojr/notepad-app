import Foundation

// MARK: - One-shot broadcast tokens
//
// Several things in the app are announced by posting ONE notification that every
// open window receives, where exactly one window should act on it: restoring a
// session tab, opening a file, reopening a closed tab. Each broadcast carries a
// token, the first window to claim it does the work, and every later window is
// turned away.
//
// Both managers that did this had the same eviction bug, written the same way:
//
//     claimedTokens.insert(token)
//     if claimedTokens.count > 64 { claimedTokens.removeAll() }
//
// The cap is sensible — the set would otherwise grow for the life of the
// process. Clearing the WHOLE set is not, because the token being cleared
// includes the one currently being delivered. A broadcast is handed to each
// window in turn, so when the insert that tips the count past the cap happens
// partway through delivery, every window still waiting sees an empty set and
// claims the same token again. Restoring 65 tabs produced a duplicate window;
// 130 produced two. Measured, not theorised.
//
// Evicting the OLDEST entry instead keeps the cap and cannot forget a token
// that is still in flight.

/// Remembers which one-shot broadcasts have already been claimed, keeping only
/// the most recent `limit` so the set cannot grow without bound.
struct OneShotTokens {
    private var claimed: Set<UUID> = []
    private var order: [UUID] = []
    private let limit: Int

    init(limit: Int = 64) {
        self.limit = max(1, limit)
    }

    /// True for the first caller to present `token`, false for every later one.
    mutating func claim(_ token: UUID) -> Bool {
        guard !claimed.contains(token) else { return false }
        claimed.insert(token)
        order.append(token)
        // Oldest first, never the token just claimed — that one may still be
        // mid-delivery to other windows.
        while order.count > limit {
            claimed.remove(order.removeFirst())
        }
        return true
    }

    /// How many tokens are currently remembered. For tests.
    var count: Int { claimed.count }
}
