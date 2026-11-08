import CoreGraphics
import Foundation

/// One row of the browse window, in the exact shape `Editor/src/browse/main.ts` expects as `BrowseRow`.
///
/// The browse window is the summonable, two-column view of the vault: the list on the left, the
/// selected note rendered on the right with an Information block under it. Like the ⌘P switcher it
/// draws what it is given (decision 4): ordering, sectioning and every date string are decided
/// here, where they are tested, and the page only lays them out.
public struct BrowseRow: Codable, Equatable, Sendable {
    public var filename: String
    /// The note's title, already "Untitled" when the first line is empty.
    public var title: String
    /// The section heading this row sits under: "Pinned", "Today", "Older", or "Results" while
    /// searching. Repeated on every row rather than nested, so the page can group by a change in it.
    public var section: String
    public var pinned: Bool?
    /// The Information block's two dates, fully formatted: "Today at 6:31:46 PM".
    public var modified: String
    /// Nil for a file named by hand, whose name carries no creation time Pane can trust.
    public var created: String?
    /// False while the note is an iCloud placeholder: it has a row, but no text to preview yet.
    public var available: Bool

    public init(
        filename: String,
        title: String,
        section: String,
        pinned: Bool? = nil,
        modified: String,
        created: String?,
        available: Bool = true
    ) {
        self.filename = filename
        self.title = title
        self.section = section
        self.pinned = pinned
        self.modified = modified
        self.created = created
        self.available = available
    }
}

/// The browse window's vocabulary: which section a note belongs to, and how a date reads.
public enum NoteBrowser {

    public static let pinnedSection = "Pinned"
    public static let todaySection = "Today"
    public static let olderSection = "Older"
    public static let resultsSection = "Results"

    /// What a note with an empty first line is called, in every list Pane draws.
    public static let untitled = "Untitled"

    /// The section for a note when the list is not being searched.
    ///
    /// Three, deliberately coarser than the switcher's recency bands. The browse window is a list
    /// you scan beside a preview, not a recency ladder you jump down, and "today" and "everything
    /// else" is the split its reference draws. Pins sit above both, because a pin means "keep this
    /// one within reach" wherever it is listed.
    public static func section(
        activity: Date,
        pinned: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if pinned { return pinnedSection }
        return calendar.isDate(activity, inSameDayAs: now) ? todaySection : olderSection
    }

    /// "Today at 6:31:46 PM", "Yesterday at 9:02:11 AM", "Jul 26, 2026 at 4:13:20 PM".
    ///
    /// The system's own relative medium date and medium time, so it reads the way the rest of the
    /// Mac reads in the user's locale, rather than a format string that is only right in English.
    ///
    /// **Relative to `now`, not to the clock.** `DateFormatter`'s relative words compare against the
    /// real current date, which made "Today" disagree with the Today section (decided from `now`)
    /// whenever the two differ, and made the tests pass only on the day they were written. So a date
    /// next to `now` is moved by whole days to sit the same distance from the real today before the
    /// formatter sees it (the time of day is untouched), and any other date is formatted absolutely.
    public static func formatDate(
        _ date: Date,
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = timeZone
        func days(from a: Date, to b: Date) -> Int {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? 0
        }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium

        // Today, yesterday and tomorrow are the only days with a word of their own.
        guard abs(days(from: now, to: date)) <= 1,
              let shifted = calendar.date(byAdding: .day, value: days(from: now, to: Date()), to: date)
        else { return formatter.string(from: date) }
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: shifted)
    }
}

extension NoteIndex {

    /// The rows the browse window lists for `query`, in the switcher's order.
    ///
    /// The order is `ranked`'s (the same one ⌘P uses), so the two lists of the same vault never
    /// disagree about which note comes first. Only the grouping and the dates differ.
    public func browseRows(
        query: String,
        state: AppState,
        order: Settings.NoteOrder = .modified,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [BrowseRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let timeZone = calendar.timeZone

        return ranked(query: trimmed, state: state, order: order).map { item in
            let record = item.record
            let section = trimmed.isEmpty
                ? NoteBrowser.section(
                    activity: item.activity, pinned: item.pinned, now: now, calendar: calendar
                )
                : NoteBrowser.resultsSection
            let created = NoteFilename.creationDate(from: record.filename, timeZone: timeZone)

            return BrowseRow(
                filename: record.filename,
                title: record.title.isEmpty ? NoteBrowser.untitled : record.title,
                section: section,
                pinned: item.pinned ? true : nil,
                modified: NoteBrowser.formatDate(record.modified, now: now, locale: locale, timeZone: timeZone),
                created: created.map { NoteBrowser.formatDate($0, now: now, locale: locale, timeZone: timeZone) },
                available: record.text != nil
            )
        }
    }

    /// The full text of one note as last indexed, for the browse window's preview.
    ///
    /// From the index, never from disk: the index already holds the text for full-text search, and
    /// reading it here costs nothing and cannot block on an evicted iCloud file. Nil for a note the
    /// index has never been able to read.
    public func text(of filename: String) -> String? {
        record(filename)?.text
    }
}

/// The browse window's size: the reference's 750×474 until it is resized, then whatever it was left
/// at, within what the display can hold.
public enum BrowseGeometry {

    /// The reference the window was built to match.
    public static let standard = CGSize(width: 750, height: 474)

    /// The smallest size whose layout still holds: the 283pt list beside a preview wide enough for
    /// the Information block, and under the search bar a few lines of preview above that block.
    /// No maximum: a window manager asked to fill the display gets the whole display.
    public static let minimum = CGSize(width: 560, height: 360)

    /// The size to summon the window at on a display whose visible area is `visible`. A size kept
    /// from a larger display is cut down to this one rather than opened half off it.
    public static func size(remembered: StoredSize?, fitting visible: CGSize) -> CGSize {
        let wanted = remembered?.size ?? standard
        func axis(_ wanted: CGFloat, _ minimum: CGFloat, _ available: CGFloat) -> CGFloat {
            min(max(wanted, minimum), available).rounded()
        }
        return CGSize(
            width: axis(wanted.width, minimum.width, visible.width),
            height: axis(wanted.height, minimum.height, visible.height)
        )
    }
}
