import Carbon
import Foundation

/// The selected keyboard input source and the enabled ones, from the Text Input Sources API. macOS
/// posts a distributed notification when the selection or the enabled sources change.
final class InputSourceMonitor: ChangeMonitor, @unchecked Sendable {
    // `start` and `stop` run on the main actor, and the observers are called on the main queue.
    private var observers: [NSObjectProtocol] = []

    deinit { stop() }

    /// `text` is the source's first language in capitals, such as `FR`, or its name when it has none.
    func read() throws -> ScriptOutput {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let name = Self.name(of: current)
        let language = (Self.property(current, kTISPropertyInputSourceLanguages) as [String]?)?.first ?? ""
        let text = language.isEmpty ? name : String(language.prefix { $0 != "-" }).uppercased()
        return ScriptOutput(text: text, icon: "keyboard", fields: ["name": name, "id": Self.id(of: current), "language": language],
                            lists: ["sources": Self.sources().map { ["id": Self.id(of: $0), "name": Self.name(of: $0)] }])
    }

    func start(changed: @escaping @Sendable () -> Void) throws {
        stop()
        let center = DistributedNotificationCenter.default()
        observers = [kTISNotifySelectedKeyboardInputSourceChanged, kTISNotifyEnabledKeyboardInputSourcesChanged].map { name in
            center.addObserver(forName: Notification.Name(name as String), object: nil, queue: .main) { _ in changed() }
        }
    }

    func stop() {
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers = []
    }

    /// Selects the enabled source with `id`, or without one, the source after the selected one,
    /// going back to the first after the last.
    static func select(_ id: String?) throws {
        let sources = sources()
        let target = if let id {
            sources.first { Self.id(of: $0) == id }
        } else {
            sources.isEmpty ? nil : sources[((sources.firstIndex { Self.id(of: $0) == currentID() } ?? -1) + 1) % sources.count]
        }
        guard let target else { throw CommandFailure(message: "That keyboard input source isn't enabled.") }
        let status = TISSelectInputSource(target)
        guard status == noErr else { throw CommandFailure(message: "Could not select the input source (\(status)).") }
    }

    /// The enabled keyboard input sources that can be selected, as the Input menu lists them.
    private static func sources() -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        return TISCreateInputSourceList(filter, false).takeRetainedValue() as? [TISInputSource] ?? []
    }

    private static func currentID() -> String {
        id(of: TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    }

    private static func id(of source: TISInputSource) -> String {
        property(source, kTISPropertyInputSourceID) ?? ""
    }

    private static func name(of source: TISInputSource) -> String {
        property(source, kTISPropertyLocalizedName) ?? ""
    }

    private static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        TISGetInputSourceProperty(source, key).flatMap { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as? T }
    }
}
