import Foundation
import Testing
@testable import Notepad

// Regression tests for the duplicate-tab bug found while measuring how many tabs
// a session can restore.
//
// Restoring 65 tabs produced 66 windows; 130 produced 132. The cause was the
// eviction: once more than 64 tokens had been claimed, the whole set was
// cleared — including the token being delivered right then. Every window still
// waiting for that same broadcast saw an empty set and claimed it again.

struct OneShotTokensTests {

    // The shape of a real broadcast: ONE token offered to every open window in
    // turn. Exactly one must be allowed through, however many windows there are
    // and however many broadcasts came before.
    private func deliver(_ token: UUID, toWindows windows: Int,
                         _ tokens: inout OneShotTokens) -> Int {
        var accepted = 0
        for _ in 0..<windows where tokens.claim(token) { accepted += 1 }
        return accepted
    }

    @Test("One broadcast is claimed exactly once, however many windows hear it")
    func singleBroadcast() {
        var tokens = OneShotTokens()
        let accepted = deliver(UUID(), toWindows: 20, &tokens)
        #expect(accepted == 1)
    }

    // The regression itself. Each restored tab adds a window, so by the time the
    // cap is passed there are dozens of windows listening — which is precisely
    // when the old code forgot the token mid-delivery.
    @Test("Every broadcast past the cap is still claimed exactly once")
    func pastTheCap() {
        var tokens = OneShotTokens()
        var windows = 1
        var duplicates = 0
        for _ in 1...200 {
            let accepted = deliver(UUID(), toWindows: windows, &tokens)
            duplicates += max(0, accepted - 1)
            windows += accepted
        }
        #expect(duplicates == 0)
        // 200 broadcasts, one window each, plus the one we started with.
        #expect(windows == 201)
    }

    // A small cap makes the eviction boundary easy to walk over deliberately.
    @Test("A token is never forgotten while it is still being delivered")
    func neverForgetsInFlight() {
        var tokens = OneShotTokens(limit: 4)
        for _ in 1...50 {
            let accepted = deliver(UUID(), toWindows: 10, &tokens)
            #expect(accepted == 1)
        }
    }

    @Test("The set stays bounded rather than growing for the life of the process")
    func staysBounded() {
        var tokens = OneShotTokens(limit: 8)
        for _ in 1...500 { _ = tokens.claim(UUID()) }
        #expect(tokens.count == 8)
    }

    // Eviction is oldest-first, so a token only stops being recognised long
    // after its broadcast is over.
    @Test("The oldest token is the one evicted")
    func evictsOldest() {
        var tokens = OneShotTokens(limit: 3)
        let first = UUID()
        _ = tokens.claim(first)
        for _ in 1...2 { _ = tokens.claim(UUID()) }
        let stillRemembered = tokens.claim(first)
        #expect(!stillRemembered)           // still known at the cap
        _ = tokens.claim(UUID())            // pushes `first` out
        let forgotten = tokens.claim(first)
        #expect(forgotten)                  // evicted, as designed
    }

    @Test("A repeat of the same token is refused")
    func repeatsRefused() {
        var tokens = OneShotTokens()
        let token = UUID()
        let first  = tokens.claim(token)
        let second = tokens.claim(token)
        let third  = tokens.claim(token)
        #expect(first)
        #expect(!second)
        #expect(!third)
    }
}
