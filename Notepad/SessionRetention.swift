import Foundation

// MARK: - Ageing scratch tabs out of the session
//
// A session is a snapshot of what was open at quit, so it does not grow on its
// own — but nothing ever takes a tab OUT of it either. Leave thirty scratch
// tabs open once and every launch from then on reopens thirty windows, most of
// which you stopped caring about weeks ago. Restoring 130 took 63 seconds.
//
// The rule, in the user's words: everything from the current session and the
// previous one stays. Two things make that safe to implement:
//
//   AGE ON USE, NOT EXISTENCE. A tab that is merely open gets "seen" on every
//   launch and would never expire, so the stamp has to be when it was last
//   EDITED. An untouched scratch tab ages; one you typed in yesterday does not.
//
//   AGED OUT MEANS ARCHIVED, NOT ERASED. An expired tab drops out of the set
//   that reopens as windows and into the closed-tab buffer, one ⇧⌘T away.
//   Nothing anyone typed is ever destroyed by a timer — which, given that this
//   whole line of work started with losing an unsaved tab, is not a detail.
//
// Named files never age. They cost a bookmark, and the text is on disk anyway.

/// Which launch this is, counting from the first run that recorded one.
/// Persisted, and bumped once per launch.
enum LaunchCounter {
    private static let key = "NotepadLaunchCount"

    /// Reads and increments. Call exactly once per launch, at startup.
    static func advance() -> Int {
        let next = UserDefaults.standard.integer(forKey: key) + 1
        UserDefaults.standard.set(next, forKey: key)
        return next
    }

    static var current: Int {
        max(1, UserDefaults.standard.integer(forKey: key))
    }
}

/// How the session is split at launch: entries that reopen as windows, and
/// entries that go to the recovery buffer instead.
struct SessionPartition: Equatable {
    var restore: [Int] = []
    var archive: [Int] = []
}

/// Splits session entries into the ones worth reopening and the ones that have
/// gone stale, by the launch each was last edited in.
///
/// - `lastEdited`: the launch number each entry was last edited in, or nil for
///   an entry written before 4.0.2 recorded one.
/// - `isNamedFile`: named files are never aged out.
/// - `keepLaunches`: how many launches count as recent. 2 means this run and
///   the one before it.
///
/// An entry with no stamp is RESTORED. A session written by an older build
/// carries no launch numbers at all, and reading "no stamp" as "ancient" would
/// archive the user's entire session the first time they ran the new version.
nonisolated func partitionSessionByAge(lastEdited: [Int?],
                                       isNamedFile: [Bool],
                                       currentLaunch: Int,
                                       keepLaunches: Int = 2) -> SessionPartition {
    var result = SessionPartition()
    let oldest = currentLaunch - max(1, keepLaunches) + 1

    for index in lastEdited.indices {
        let named = index < isNamedFile.count && isNamedFile[index]
        guard !named else { result.restore.append(index); continue }
        guard let stamp = lastEdited[index] else { result.restore.append(index); continue }
        if stamp >= oldest {
            result.restore.append(index)
        } else {
            result.archive.append(index)
        }
    }
    return result
}
