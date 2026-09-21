import Foundation
import Testing
@testable import Notepad

// Tests for ageing scratch tabs out of the session: everything from this run
// and the previous one keeps reopening as a window, older untouched scratch
// goes to the recovery buffer instead.

struct SessionRetentionTests {

    private func partition(_ lastEdited: [Int?], named: [Bool]? = nil,
                           at launch: Int, keep: Int = 2) -> SessionPartition {
        partitionSessionByAge(lastEdited: lastEdited,
                              isNamedFile: named ?? Array(repeating: false, count: lastEdited.count),
                              currentLaunch: launch, keepLaunches: keep)
    }

    @Test("This run and the previous one both stay")
    func keepsCurrentAndPrevious() {
        let result = partition([10, 9], at: 10)
        #expect(result.restore == [0, 1])
        #expect(result.archive.isEmpty)
    }

    @Test("Anything older is archived")
    func archivesOlder() {
        let result = partition([10, 9, 8, 1], at: 10)
        #expect(result.restore == [0, 1])
        #expect(result.archive == [2, 3])
    }

    // The distinction the whole design rests on. A tab that is merely open is
    // re-saved every quit but not re-stamped, so it ages; ageing on presence
    // instead would mean nothing ever expired.
    @Test("Being open is not the same as being used")
    func ageOnUseNotPresence() {
        // Open across five launches, last typed in during launch 6 of 10.
        let result = partition([6], at: 10)
        #expect(result.archive == [0])
    }

    @Test("Editing it again resets the clock")
    func editingKeepsItAlive() {
        let result = partition([10], at: 10)
        #expect(result.restore == [0])
    }

    // Named files cost a bookmark and their text is on disk regardless, so
    // there is nothing to gain by dropping them and a reopened window to lose.
    @Test("Named files never age out, however stale")
    func namedFilesNeverAge() {
        let result = partition([1, 1], named: [true, false], at: 99)
        #expect(result.restore == [0])
        #expect(result.archive == [1])
    }

    // The upgrade case, and the one that would have been a disaster to get
    // wrong: a session written by 4.0.1 carries no launch stamps at all.
    // Reading "no stamp" as "ancient" would archive the user's whole session
    // the first time they ran the new build.
    @Test("An unstamped entry from an older build is always restored")
    func unstampedAlwaysRestored() {
        let result = partition([nil, nil, nil], at: 500)
        #expect(result.restore == [0, 1, 2])
        #expect(result.archive.isEmpty)
    }

    @Test("A mixed session ages only the entries it can judge")
    func mixedSession() {
        let result = partition([nil, 12, 3], at: 12)
        #expect(result.restore == [0, 1])
        #expect(result.archive == [2])
    }

    @Test("Every entry ends up in exactly one side of the split",
          arguments: [1, 2, 5, 20])
    func partitionIsTotal(keep: Int) {
        let stamps: [Int?] = [nil, 1, 5, 9, 10, 11]
        let result = partition(stamps, at: 11, keep: keep)
        #expect(result.restore.count + result.archive.count == stamps.count)
        #expect(Set(result.restore).isDisjoint(with: Set(result.archive)))
        #expect(Set(result.restore + result.archive) == Set(0..<stamps.count))
    }

    // A first run has currentLaunch == 1 and nothing should be stale yet.
    @Test("Nothing is aged out on an early launch")
    func earlyLaunchKeepsEverything() {
        let result = partition([1, 1, 1], at: 1)
        #expect(result.archive.isEmpty)
    }

    @Test("A keep window of one means only this run survives")
    func keepOne() {
        let result = partition([10, 9], at: 10, keep: 1)
        #expect(result.restore == [0])
        #expect(result.archive == [1])
    }
}
