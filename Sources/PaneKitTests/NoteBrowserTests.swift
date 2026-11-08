import CoreGraphics
import Foundation
import PaneKit

private func browseVault(_ files: [String: String]) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("pane-browse-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, text) in files {
        try? Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }
    return dir
}

private func setModified(_ vault: URL, _ name: String, _ date: Date) {
    try? FileManager.default.setAttributes(
        [.modificationDate: date], ofItemAtPath: vault.appendingPathComponent(name).path
    )
}

func runNoteBrowserTests() {
    let utc = TimeZone(identifier: "UTC")!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let english = Locale(identifier: "en_US")
    // 2026-11-06 18:31:46 UTC.
    let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 18, minute: 31, second: 46))!

    Check.suite("Browse window: dates") {

        Check.test("today reads as the reference reads it") {
            Check.equal(
                NoteBrowser.formatDate(now, now: now, locale: english, timeZone: utc),
                "Today at 6:31:46\u{202F}PM"
            )
        }

        Check.test("an older date carries its full medium date") {
            let july = calendar.date(from: DateComponents(year: 2026, month: 7, day: 26, hour: 16, minute: 13, second: 20))!
            Check.equal(
                NoteBrowser.formatDate(july, now: now, locale: english, timeZone: utc),
                "Jul 26, 2026 at 4:13:20\u{202F}PM"
            )
        }

        Check.test("yesterday has its word, and the day before has a date") {
            Check.equal(
                NoteBrowser.formatDate(now.addingTimeInterval(-86_400), now: now, locale: english, timeZone: utc),
                "Yesterday at 6:31:46\u{202F}PM"
            )
            Check.equal(
                NoteBrowser.formatDate(now.addingTimeInterval(-2 * 86_400), now: now, locale: english, timeZone: utc),
                "Nov 4, 2026 at 6:31:46\u{202F}PM"
            )
        }

        Check.test("a date that is the real today but not today relative to now is not called Today") {
            let later = calendar.date(byAdding: .day, value: 30, to: Date())!
            Check.expect(!NoteBrowser.formatDate(Date(), now: later, locale: english, timeZone: utc).hasPrefix("Today"))
        }
    }

    Check.suite("Browse window: sections") {

        Check.test("today, older and pinned") {
            let earlier = now.addingTimeInterval(-3600)
            let lastWeek = now.addingTimeInterval(-7 * 86_400)
            Check.equal(NoteBrowser.section(activity: earlier, pinned: false, now: now, calendar: calendar), "Today")
            Check.equal(NoteBrowser.section(activity: lastWeek, pinned: false, now: now, calendar: calendar), "Older")
            // A pin outranks the clock: a pinned note edited today is still listed with the pins.
            Check.equal(NoteBrowser.section(activity: earlier, pinned: true, now: now, calendar: calendar), "Pinned")
        }

        Check.test("yesterday is older, not today") {
            let yesterday = now.addingTimeInterval(-20 * 3600)
            Check.equal(NoteBrowser.section(activity: yesterday, pinned: false, now: now, calendar: calendar), "Older")
        }
    }

    Check.suite("Browse window: rows") {

        let fresh = "2026-11-06-1800-fresh.md"
        let stale = "2026-07-01-0900-stale.md"
        let pinned = "2026-05-25-1749-todo-business.md"
        let blank = "2026-11-06-1700-untitled.md"
        let handNamed = "shopping.md"

        func makeIndex() -> NoteIndex {
            let vault = browseVault([
                fresh: "Fresh note\n\nwritten today\n",
                stale: "Stale note\n\nmentions a pelican\n",
                pinned: "TODO BUSINESS\n\n- [ ] Store\n",
                blank: "",
                handNamed: "Shopping\n\nmilk\n",
            ])
            setModified(vault, fresh, now.addingTimeInterval(-60))
            setModified(vault, blank, now.addingTimeInterval(-120))
            setModified(vault, stale, now.addingTimeInterval(-30 * 86_400))
            setModified(vault, pinned, now.addingTimeInterval(-40 * 86_400))
            setModified(vault, handNamed, now.addingTimeInterval(-50 * 86_400))
            let index = NoteIndex()
            _ = try? index.refresh(vault: vault)
            return index
        }

        var state = AppState()
        state.notes[pinned] = NoteState(isPinned: true)

        Check.test("pins first, then today, then older, each by recency") {
            let rows = makeIndex().browseRows(
                query: "", state: state, now: now, calendar: calendar, locale: english
            )
            Check.equal(rows.map(\.filename), [pinned, fresh, blank, stale, handNamed])
            Check.equal(rows.map(\.section), ["Pinned", "Today", "Today", "Older", "Older"])
            Check.equal(rows.first?.pinned, true)
            Check.equal(rows[1].pinned, nil, "an unpinned row says nothing, rather than false")
        }

        Check.test("a note with no first line is called Untitled") {
            let rows = makeIndex().browseRows(
                query: "", state: state, now: now, calendar: calendar, locale: english
            )
            Check.equal(rows.first { $0.filename == blank }?.title, "Untitled")
        }

        Check.test("created comes from the filename; a hand-named file has none") {
            let rows = makeIndex().browseRows(
                query: "", state: state, now: now, calendar: calendar, locale: english
            )
            Check.equal(rows.first { $0.filename == pinned }?.created, "May 25, 2026 at 5:49:00\u{202F}PM")
            Check.equal(rows.first { $0.filename == fresh }?.modified, "Today at 6:30:46\u{202F}PM")
            Check.expect(rows.first { $0.filename == handNamed }?.created == nil)
        }

        Check.test("searching lists one Results section, found in the body too") {
            let rows = makeIndex().browseRows(
                query: "pelican", state: state, now: now, calendar: calendar, locale: english
            )
            Check.equal(rows.map(\.filename), [stale])
            Check.equal(rows.map(\.section), ["Results"])
        }

        Check.test("the same order as the switcher") {
            let index = makeIndex()
            let browse = index.browseRows(query: "", state: state, now: now, calendar: calendar, locale: english)
            let switcher = index.rows(query: "", state: state, current: nil, now: now, calendar: calendar, locale: english)
            Check.equal(browse.map(\.filename), switcher.map(\.filename))
        }

        Check.test("the preview text comes from the index") {
            let index = makeIndex()
            Check.equal(index.text(of: stale), "Stale note\n\nmentions a pelican\n")
            Check.expect(index.text(of: "missing.md") == nil)
        }
    }

    Check.suite("Browse hotkey setting") {

        func decode(_ json: String) -> Settings? {
            try? JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        }

        Check.test("unbound by default") {
            Check.expect(Settings().browseHotkey == nil)
            Check.expect(decode("{}")?.browseHotkey == nil)
        }

        Check.test("a written combination is read back") {
            let settings = decode(#"{"browseHotkey": "control+option+command+n"}"#)
            Check.equal(settings?.browseHotkey?.displayString, "⌃⌥⌘N")
        }

        Check.test("an unreadable value is unbound, never the summon key") {
            Check.expect(decode(#"{"browseHotkey": "hyper+banana"}"#)?.browseHotkey == nil)
            Check.expect(decode(#"{"browseHotkey": ""}"#)?.browseHotkey == nil)
            Check.expect(decode(#"{"browseHotkey": null}"#)?.browseHotkey == nil)
            Check.expect(decode(#"{"browseHotkey": 7}"#) != nil, "a wrong type costs the key, not the file")
        }

        Check.test("the summon key cannot also be the browse key") {
            let settings = decode(#"{"summonHotkey": "control+option+space", "browseHotkey": "control+option+space"}"#)
            Check.expect(settings?.browseHotkey == nil)
        }

        Check.test("round trips through the file") {
            var settings = Settings()
            settings.browseHotkey = try? Hotkey.parse("control+option+command+n")
            let data = try? JSONEncoder().encode(settings)
            let back = data.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
            Check.equal(back?.browseHotkey, settings.browseHotkey)

            settings.browseHotkey = nil
            let cleared = try? JSONEncoder().encode(settings)
            let text = cleared.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Check.expect(!text.contains("browseHotkey"), "unbound writes nothing")
        }
    }

    Check.suite("Browse window: size") {
        let display = CGSize(width: 1512, height: 944)

        Check.test("opens at the reference size until it is resized") {
            Check.equal(BrowseGeometry.size(remembered: nil, fitting: display), CGSize(width: 750, height: 474))
        }

        Check.test("then at the size it was left at, with no maximum") {
            let full = StoredSize(width: 1512, height: 944)
            Check.equal(BrowseGeometry.size(remembered: full, fitting: display), display)
        }

        Check.test("never smaller than the layout holds") {
            let tiny = StoredSize(width: 200, height: 100)
            Check.equal(BrowseGeometry.size(remembered: tiny, fitting: display), BrowseGeometry.minimum)
        }

        Check.test("a size kept from a bigger display fits the one it opens on") {
            let big = StoredSize(width: 2400, height: 1300)
            Check.equal(BrowseGeometry.size(remembered: big, fitting: display), display)
        }

        Check.test("is kept in state.json, and an older file without it still decodes") {
            var state = AppState()
            state.browseSize = StoredSize(width: 900, height: 600)
            let data = try? JSONEncoder().encode(state)
            let back = data.flatMap { try? JSONDecoder().decode(AppState.self, from: $0) }
            Check.equal(back?.browseSize, StoredSize(width: 900, height: 600))

            let old = try? JSONDecoder().decode(AppState.self, from: Data(#"{"schemaVersion": 1}"#.utf8))
            Check.expect(old != nil && old?.browseSize == nil)
        }
    }
}
