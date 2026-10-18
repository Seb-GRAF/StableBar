import AppKit

/// The edit bar can take keyboard focus without activating the app. Also handle Escape
/// after a widget opens Customize, where the bar is no longer the key window.
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

    static func handle(_ event: NSEvent, store: BarStore) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        return store.barEditing.handleKey(event.keyCode)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
