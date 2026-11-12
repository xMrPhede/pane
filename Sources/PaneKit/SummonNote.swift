import Foundation

/// Which note a plain summon (the hotkey, the menu bar icon, the Dock icon) puts in the pane.
///
/// **A pane that comes up, comes up on a new note.** Where you left off is one ⌘[ away, and in the
/// switcher and the browse window; what the hotkey is for is the thought you are about to write
/// down, and that should never have to start with clearing somebody else's note out of the way.
public enum SummonNote: Equatable, Sendable {
    /// The pane is already up: it keeps its note and is only brought back to you. That press means
    /// "give me the pane", not "start again", and replacing a note mid-sentence would be a keypress
    /// that hides your writing.
    case keep
    /// An empty draft, which becomes a file at its first write and leaves nothing if it gets none.
    case newNote
    /// The very first summon of an install, while no note has ever been opened: the welcome note's
    /// only chance to be read (decision 129). The pane opens whatever the vault holds.
    case firstRun

    /// - Parameters:
    ///   - isUp: the pane is on screen.
    ///   - hasEverOpenedANote: any note in the state file has an open recorded.
    ///   - holdsANote: the pane has a note or a draft loaded already.
    public static func resolve(isUp: Bool, hasEverOpenedANote: Bool, holdsANote: Bool) -> SummonNote {
        if isUp { return .keep }
        if !hasEverOpenedANote, !holdsANote { return .firstRun }
        return .newNote
    }
}
