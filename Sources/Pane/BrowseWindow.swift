import AppKit
import PaneKit
import WebKit

/// Everything the browse page can tell Swift. Mirrors `OutboundMessage` in
/// `Editor/src/browse/main.ts`, decoded at the boundary for `PaneMessage`'s reason: a message the page
/// stops sending becomes a compile error here rather than a silent no-op.
enum BrowseMessage: Equatable {
    case ready
    case requestNotes(query: String)
    case requestPreview(filename: String)
    case open(filename: String)
    case create(title: String)
    case close
    case copy(filename: String)
    case reveal(filename: String)
    case togglePin(filename: String)
    case delete(filename: String)
    case openLink(target: String)

    init?(body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return nil }
        func string(_ key: String) -> String { dict[key] as? String ?? "" }

        switch type {
        case "ready": self = .ready
        case "requestNotes": self = .requestNotes(query: string("query"))
        case "requestPreview": self = .requestPreview(filename: string("filename"))
        case "open": self = .open(filename: string("filename"))
        case "create": self = .create(title: string("title"))
        case "close": self = .close
        case "copy": self = .copy(filename: string("filename"))
        case "reveal": self = .reveal(filename: string("filename"))
        case "togglePin": self = .togglePin(filename: string("filename"))
        case "delete": self = .delete(filename: string("filename"))
        case "openLink": self = .openLink(target: string("target"))
        default: return nil
        }
    }
}

/// The browse window: a **standard macOS window** that happens to draw no title bar.
///
/// Deliberately not a panel like the pane. The pane is a HUD over your work and is built never to
/// be a window anyone else manages; the browse window is a place you go to look something up, and
/// it should behave like every other window on the Mac while you are there: it activates Pane, it
/// is a standard window to the Accessibility API (so window managers, switchers and Mission Control
/// see it as one), it lists in the Window menu, it can be dragged and resized (by its edges or by a
/// window manager, with no maximum), and it stays put when you click somewhere else until you close
/// it.
///
/// `.titled` is what makes it standard (a borderless window reports no standard subrole), and the
/// title bar it brings is made invisible: full-size content, transparent bar, hidden title and
/// buttons. So it looks exactly like the page it carries and is a normal window underneath.
///
/// Closed means **ordered out**, not parked offscreen the way the pane is. A parked window is still
/// in the window list, and a "normal" window that sits invisibly at -30,000 is precisely the phantom
/// that switchers and Mission Control would then show. The web view pays for that with a short wake
/// on the next open, which the page covers by rendering before the window is shown (see `show`).
@MainActor
final class BrowseWindow: NSWindow {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: BrowseGeometry.standard),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Browse Notes"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }

        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .normal
        // A managed window, so it belongs to a Space like any other, but summoned onto the one you
        // are on rather than dragging you to the one it was last on, and allowed beside a full-screen
        // app rather than forcing a Space switch out of it.
        collectionBehavior = [.managed, .participatesInCycle, .moveToActiveSpace, .fullScreenAuxiliary]
        isExcludedFromWindowsMenu = false
        tabbingMode = .disallowed
        animationBehavior = .documentWindow
        // A floor, and no ceiling: a window manager asked to fill the display must be able to.
        contentMinSize = BrowseGeometry.minimum
    }

    /// Centred on the display under the pointer, a little above the middle, where a launcher sits,
    /// so the eye finds it where it already expects one. At the size it was last left at, cut down
    /// to what this display can hold.
    static func frame(on screen: NSScreen, remembered: StoredSize?) -> CGRect {
        let visible = screen.visibleFrame
        let size = BrowseGeometry.size(remembered: remembered, fitting: visible.size)
        let x = visible.midX - size.width / 2
        // A third of the free height above it, two thirds below.
        let free = max(0, visible.height - size.height)
        let y = visible.maxY - free / 3 - size.height
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// ⌘W and the Window menu's Close come through here; closing is the controller's to do, so the
    /// app can hand the front back the way every other close path does.
    var onClose: (() -> Void)?

    override func performClose(_ sender: Any?) {
        onClose?()
    }
}

/// The browse page, in a WKWebView over the system material: `EditorWebView`'s construction, without
/// the pane's drag regions and editor bridge, which this window has no use for.
@MainActor
final class BrowseWebView: NSView {

    var onMessage: ((BrowseMessage) -> Void)?

    let webView: WKWebView
    private let material = NSVisualEffectView()
    private let bridge = BrowseMessageBridge()
    private let dragStrip = BrowseDragStrip()
    private var pendingCalls: [String] = []
    private var isReady = false

    /// Matches `--browse-radius` in `browse.css`.
    static let cornerRadius: CGFloat = 16

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = BrowseClickThroughWebView(frame: frameRect, configuration: configuration)
        super.init(frame: frameRect)

        configuration.userContentController.add(bridge, name: "browse")
        bridge.onMessage = { [weak self] message in self?.onMessage?(message) }

        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        #if DEBUG
        webView.isInspectable = true
        #endif

        // The real blur, as for the pane: only an NSVisualEffectView can sample what is behind the
        // window, and `.active` keeps it from greying out when the window is left open behind
        // another app.
        material.blendingMode = .behindWindow
        material.state = .active
        material.material = .hudWindow
        material.wantsLayer = true
        material.layer?.cornerRadius = Self.cornerRadius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        addSubview(material)
        addSubview(webView)
        addSubview(dragStrip)
        dragStrip.webView = webView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        material.frame = bounds
        webView.frame = bounds
        // The search bar is the window's grab handle, as a title bar would be. Not the back button
        // at its left edge, which is a button.
        let strip = BrowseDragStrip.height
        dragStrip.frame = CGRect(
            x: BrowseDragStrip.leadingExclusion, y: bounds.height - strip,
            width: bounds.width - BrowseDragStrip.leadingExclusion, height: strip
        )
    }

    var isTranslucent: Bool {
        get { !material.isHidden }
        set { material.isHidden = !newValue }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func load() {
        guard let url = EditorWebView.bundleURL(page: "browse.html") else {
            NSLog("Pane: browse bundle not found; run Scripts/build-app.sh")
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func markReady() {
        isReady = true
        let queued = pendingCalls
        pendingCalls.removeAll()
        for script in queued { webView.evaluateJavaScript(script, completionHandler: nil) }
    }

    /// Calls `window.browseHost.<method>(...)` with arguments that are already JSON.
    func callJSON(_ method: String, _ jsonArguments: [String] = []) {
        let script = "window.browseHost && window.browseHost.\(method)(\(jsonArguments.joined(separator: ", ")));"
        guard isReady else {
            pendingCalls.append(script)
            return
        }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Calls `window.browseHost.<method>(...)`, JSON-encoding each argument.
    func call(_ method: String, _ arguments: [Any] = []) {
        callJSON(method, arguments.map(Self.json))
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8), text.count >= 2
        else { return "null" }
        return String(text.dropFirst().dropLast())
    }

    func focusPage() {
        window?.makeFirstResponder(webView)
    }
}

/// Makes the search bar drag the window, without taking the search field away from the mouse.
///
/// A WKWebView consumes every mouse event, so neither `isMovableByWindowBackground` nor the CSS
/// `app-region` reaches the window. This strip sits over the search bar and decides per gesture: a
/// press that moves is a drag of the window; a press that does not is replayed to the page, so a
/// click still places the caret and a double-click still selects a word.
@MainActor
private final class BrowseDragStrip: NSView {

    /// `--browse-search-height` in browse.css.
    static let height: CGFloat = 55
    /// The back button's column, which stays a button.
    static let leadingExclusion: CGFloat = 44

    weak var webView: WKWebView?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = NSEvent.mouseLocation
        // Wait for the gesture to declare itself: past three points it is a drag, and a release
        // first is a click.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                webView?.mouseDown(with: event)
                webView?.mouseUp(with: next)
                return
            }
            let now = NSEvent.mouseLocation
            if hypot(now.x - start.x, now.y - start.y) > 3 {
                window.performDrag(with: event)
                return
            }
        }
    }
}

/// The pane's first-click rule: when the window is open behind another app, a click on a row should
/// select the row, not merely bring the window forward.
private final class BrowseClickThroughWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Holds the script message handler so the configuration does not retain the view (see
/// `EditorWebView`'s `MessageBridge`).
private final class BrowseMessageBridge: NSObject, WKScriptMessageHandler {
    @MainActor var onMessage: ((BrowseMessage) -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let decoded = BrowseMessage(body: message.body) else { return }
            onMessage?(decoded)
        }
    }
}
