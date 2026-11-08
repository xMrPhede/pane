import AppKit
import PaneKit

/// The browse window: "Summon Browse Notes".
///
/// A second way into the vault, for the moment you want to *find* a note rather than continue one.
/// The pane's ⌘P switcher answers "which note next" from inside a note you are already in; this
/// answers "what have I got" from anywhere, with each note rendered beside the list before you
/// commit to opening it. Opening one hands it to the pane and gets out of the way.
///
/// It owns no notes. Rows come from the vault's index (`VaultService.browseRows`), and anything that
/// changes a note (open, pin, delete, create) goes through the pane, which already knows how to
/// do each of them safely (the write gate, Recently Deleted, the unsettled name).
@MainActor
final class BrowseController: NSObject {

    private let window = BrowseWindow()
    private let page = BrowseWebView(frame: CGRect(origin: .zero, size: BrowseGeometry.standard))

    private let vault: VaultService
    private let state: StateStore
    private let settings: SettingsStore
    private let pane: PaneController

    /// Called when a pin changes here, so the menu bar's pinned section follows.
    var onPinsChanged: (() -> Void)?

    init(vault: VaultService, state: StateStore, settings: SettingsStore, pane: PaneController) {
        self.vault = vault
        self.state = state
        self.settings = settings
        self.pane = pane
        super.init()

        window.delegate = self
        window.contentView = page
        window.onClose = { [weak self] in self?.dismiss() }
        page.onMessage = { [weak self] in self?.handle($0) }
        // Loaded at launch, not at the first press: a web view still parsing 500 kB of script when
        // the hotkey lands is a window that opens empty.
        page.load()
    }

    var isVisible: Bool { window.isVisible }

    /// Whether the browse window is the one taking keys. For the File menu, whose ⌘W must close
    /// this window rather than the pane behind it while it is in front.
    var isKey: Bool { window.isVisible && window.isKeyWindow }

    /// The hotkey. A press while the window is in front puts it away; any other press brings it
    /// forward: opened fresh if it was closed, or simply raised if it was open behind something.
    func toggle() {
        if window.isVisible && window.isKeyWindow && NSApp.isActive {
            dismiss()
        } else if window.isVisible {
            raise()
        } else {
            show()
        }
    }

    func show() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.main ?? NSScreen.screens.first
        else { return }

        applySettings()
        // A fresh sitting: an empty search and the top of the list, asked for before the window is
        // on screen so the first frame drawn is the right one rather than the last sitting's.
        page.call("reset")
        window.setFrame(BrowseWindow.frame(on: screen, remembered: state.value.browseSize), display: false)
        raise()
    }

    /// Brings the window forward as the app's key window. Activating is the point: a normal window
    /// belongs to the frontmost app, and this is the second thing in Pane allowed to make Pane
    /// that app (Settings is the first).
    private func raise() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        page.focusPage()
    }

    /// Closes the window and hands the front back to whatever had it, unless the pane is up, in
    /// which case it is what you return to.
    func dismiss() {
        guard window.isVisible else { return }
        window.orderOut(nil)
        PanePanel.resumeFloating()
        if NSApp.isActive, !pane.isVisible { NSApp.deactivate() }
    }

    /// Re-reads the list while the window is up, because the vault changed underneath it.
    func vaultChanged() {
        guard window.isVisible else { return }
        page.call("refresh")
    }

    func applySettings() {
        let value = settings.value
        page.isTranslucent = value.translucentPanes
        window.appearance = switch value.appearance {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
        window.sharingType = value.hideFromScreenCapture ? .none : .readOnly
        page.call(
            "applySettings",
            [[
                "appearance": value.appearance.rawValue,
                "accent": value.accent,
                "translucent": value.translucentPanes,
                "shortcuts": value.shortcuts,
            ] as [String: Any]]
        )
    }

    // MARK: - Messages

    private func handle(_ message: BrowseMessage) {
        switch message {
        case .ready:
            page.markReady()
            applySettings()

        case .requestNotes(let query):
            vault.browseRows(query: query, state: state.value, order: settings.value.noteOrder) {
                [weak self] rows in
                self?.page.callJSON("showNotes", [EditorWebView.encode(rows), EditorWebView.encode(query)])
            }

        case .requestPreview(let filename):
            vault.previewText(filename) { [weak self] text in
                self?.page.call("showPreview", [filename, text ?? NSNull()])
            }

        case .open(let filename):
            handOver { $0.open(filename) }

        case .create(let title):
            handOver { $0.createNote(title: title) }

        case .close:
            dismiss()

        case .copy(let filename):
            vault.previewText(filename) { [weak self] text in
                guard let self, let text else { return }
                // The markdown is the note (decision 5): nothing to convert, as for the pane's ⇧⌘C.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.page.call("showToast", ["Copied to clipboard"])
            }

        case .reveal(let filename):
            NSWorkspace.shared.activateFileViewerSelecting(
                [settings.value.vaultURL.appendingPathComponent(filename)]
            )

        case .togglePin(let filename):
            pane.togglePin(filename)
            onPinsChanged?()
            let pinned = state.value.note(filename).isPinned
            page.call("showToast", [pinned ? "Pinned" : "Unpinned"])
            page.call("refresh")

        case .delete(let filename):
            pane.delete(filename) { [weak self] ok in
                guard let self else { return }
                self.page.call("showToast", [ok ? "Moved to Recently Deleted" : "Couldn’t delete the note"])
                self.page.call("refresh")
            }

        case .openLink(let target):
            guard let url = LinkTarget.resolve(target) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// Closes this window and gives the note to the pane, which is where notes are written.
    ///
    /// Not through `dismiss`: that hands the front back to the previous app first, and the pane is
    /// a non-activating panel that wants to take the keyboard *over* that app, and deactivating and
    /// summoning in the same turn races the two. Ordered out here, the pane summons into the app
    /// that is still active, and its own dismiss hands the front back later, as it always does.
    private func handOver(_ body: (PaneController) -> Void) {
        window.orderOut(nil)
        PanePanel.resumeFloating()
        pane.summon()
        body(pane)
    }
}

extension BrowseController: NSWindowDelegate {

    /// The pane floats at `.floating`, above every normal window, this one included. While the
    /// browse window is the one you are using, the pane steps down to an ordinary window (Settings
    /// does the same); when you move to anything else, it floats again.
    func windowDidBecomeKey(_ notification: Notification) {
        PanePanel.stepAside()
    }

    func windowDidResignKey(_ notification: Notification) {
        PanePanel.resumeFloating()
    }

    /// Remembers the size for the next summon. On every resize rather than at the end of a live
    /// one: a window manager sets the size through Accessibility, which is no live resize at all.
    /// The state store coalesces the writes. Only while visible, so `show`'s own `setFrame` (which
    /// is reading the remembered size, not choosing one) never writes back a size cut down to fit a
    /// smaller display.
    func windowDidResize(_ notification: Notification) {
        guard window.isVisible else { return }
        let size = window.frame.size
        guard state.value.browseSize?.size != size else { return }
        state.update { $0.browseSize = StoredSize(size) }
    }
}
