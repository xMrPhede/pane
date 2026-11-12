import Foundation
import PaneKit

/// What a plain summon puts in the pane: a new note, unless the pane is already up or this is the
/// install's first summon.
func runSummonNoteTests() {
    Check.suite("Summon note") {
        Check.test("a parked pane comes up on a new note, whatever it held before") {
            for holds in [true, false] {
                Check.equal(
                    SummonNote.resolve(isUp: false, hasEverOpenedANote: true, holdsANote: holds),
                    .newNote
                )
            }
        }

        Check.test("a pane that is already up keeps its note") {
            for opened in [true, false] {
                for holds in [true, false] {
                    Check.equal(
                        SummonNote.resolve(isUp: true, hasEverOpenedANote: opened, holdsANote: holds),
                        .keep
                    )
                }
            }
        }

        Check.test("the first summon of an install shows the welcome note") {
            Check.equal(
                SummonNote.resolve(isUp: false, hasEverOpenedANote: false, holdsANote: false),
                .firstRun
            )
        }

        Check.test("a draft started before any note was opened is a new note, not the first run") {
            // A user whose first summon was a draft they never wrote in has seen the pane already;
            // the welcome note is not sprung on them at the second.
            Check.equal(
                SummonNote.resolve(isUp: false, hasEverOpenedANote: false, holdsANote: true),
                .newNote
            )
        }
    }
}
