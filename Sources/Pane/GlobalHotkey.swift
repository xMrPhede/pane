import Carbon.HIToolbox
import Foundation
import PaneKit

/// The global summon hotkey, registered through Carbon.
///
/// Carbon rather than `CGEvent` taps or `NSEvent.addGlobalMonitorForEvents`, and that choice is
/// decision 9 in one API call: `RegisterEventHotKey` needs **no Accessibility permission**, while
/// both alternatives do. Measured on this machine — both this and `InstallEventHandler` return
/// `noErr` with `AXIsProcessTrusted()` false — so "Pane requests no privacy permissions at all" is a
/// property of the implementation, not a hope.
@MainActor
final class GlobalHotkey {

    /// Four-character signature Carbon uses to namespace hot key IDs across the system.
    private static let signature: OSType = {
        let chars = Array("pane".utf8)
        return chars.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()

    private let onFire: @MainActor () -> Void

    // `nonisolated(unsafe)` so `deinit` — which is not main-actor-isolated — can release them. They
    // are opaque Carbon handles written only from the main actor, and the teardown functions are
    // safe from any thread, so the unsafety here is a compiler concession rather than a real race.
    private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) var handlerRef: EventHandlerRef?

    /// Every instance draws its IDs from one counter, so two instances never hand Carbon the same
    /// one. The handler below matches on the ID as well as the signature, and that is only a test of
    /// *which* hotkey fired if the IDs are unique across the process.
    private static var nextID: UInt32 = 1

    /// The ID Carbon fires with for the combination this instance holds, which is what the handler checks.
    private var registeredID: UInt32 = 0

    private(set) var registered: Hotkey?

    init(onFire: @escaping @MainActor () -> Void) {
        self.onFire = onFire
    }

    deinit {
        // Carbon's teardown functions are safe to call from any thread, and both handles are plain
        // opaque pointers — nothing here touches main-actor state.
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Registers `hotkey`, replacing any previous one.
    ///
    /// - Returns: false when the combination is already taken by another application. That is a
    ///   normal outcome, not an error — the user is told and Pane keeps running, because an app that
    ///   refuses to launch over a hotkey conflict is worse than one you have to click to open.
    @discardableResult
    func register(_ hotkey: Hotkey) -> Bool {
        unregister()
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.nextID)
        Self.nextID += 1

        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers.rawValue,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        registeredID = id.id
        registered = hotkey
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registeredID = 0
        registered = nil
    }

    // MARK: - Carbon plumbing

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // The instance is passed unretained: `self` outlives the handler by construction (the app
        // delegate owns it for the process lifetime) and retaining it here would make the cycle
        // permanent rather than merely long.
        let context = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }

                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard status == noErr, id.signature == GlobalHotkey.signature else {
                    return OSStatus(eventNotHandledErr)
                }

                // Carbon application event handlers are dispatched on the main run loop, so this is
                // an assertion about a fact rather than a hop that could deadlock.
                //
                // Every instance installs a handler on the same target, so each one sees every
                // press of every Pane hotkey. Matching the signature alone made the summon key also
                // fire the browse window the moment there were two. A press that is not this
                // instance's is passed on to the next handler rather than claimed.
                return MainActor.assumeIsolated {
                    let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                    guard id.id == hotkey.registeredID else { return OSStatus(eventNotHandledErr) }
                    hotkey.onFire()
                    return noErr
                }
            },
            1,
            &spec,
            context,
            &handlerRef
        )
    }
}
