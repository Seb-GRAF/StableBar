import AppKit

/// Editing shortcuts apply only when the bar itself owns keyboard input.
@MainActor
final class BarEditingKeyboard {
    private var monitor: Any?

    @discardableResult
    func start(store: BarStore) -> Bool {
        guard monitor == nil, store.barEditing.isActive else { return false }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store] event in
            let handled = MainActor.assumeIsolated {
                guard let store else { return false }
                return Self.handle(event, store: store)
            }
            return handled ? nil : event
        }
        return true
    }

    static func handle(_ event: NSEvent, store: BarStore, keyWindow: NSWindow? = NSApp?.keyWindow) -> Bool {
        guard event.type == .keyDown, let panel = keyWindow as? BarPanel, panel.isEditingBar,
              panel.attachedSheet == nil, !(panel.firstResponder is NSTextView), !(panel.firstResponder is NSTextField) else { return false }
        return store.barEditing.handleKey(event.keyCode, characters: event.characters, charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags.intersection([.shift, .command, .control, .option]))
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
