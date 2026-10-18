import Foundation
import Observation

@MainActor @Observable
final class ThemeTrial {
    private let store: BarStore
    let choices: [ThemeChoice]
    private(set) var selectedIndex: Int
    private(set) var isActive = true
    private(set) var error: String?

    init(store: BarStore) {
        self.store = store
        choices = ThemeCatalog(packages: store.configurationURL.deletingLastPathComponent().appending(path: "packages"),
                               themesDirectory: store.themesDirectory).choices
        let selection = try? store.effectiveDocument["theme"]?.decoded(WidgetPackageSelection.self)
        let key = selection.flatMap { $0.enabled ? $0.key : nil } ?? "built-in"
        selectedIndex = choices.firstIndex { $0.key == key } ?? 0
    }

    var choice: ThemeChoice? { choices.indices.contains(selectedIndex) ? choices[selectedIndex] : nil }
    var position: String { "\(choice == nil ? 0 : selectedIndex + 1) of \(choices.count)" }

    func previous() { move(by: -1) }
    func next() { move(by: 1) }

    private func move(by offset: Int) {
        guard isActive, !choices.isEmpty else { return }
        let index = (selectedIndex + offset + choices.count) % choices.count
        do {
            try store.tryTheme(choices[index])
            selectedIndex = index
            error = nil
        } catch { self.error = "This theme couldn’t be tried. Choose another theme." }
    }

    func keep() {
        guard isActive, let choice else { return }
        do {
            var edit = choice.edit
            if choice.isBuiltIn {
                let root = try store.editedDocument([edit], replaying: [])
                var loader = ConfigurationLoader()
                loader.themesDirectory = store.themesDirectory
                let document = try loader.compose(store.configurationURL, data: configurationData(root), context: store.context)
                if let inherited = try document["theme"]?.decoded(WidgetPackageSelection.self), inherited.enabled {
                    edit.properties = choice.selection
                }
            } else if let selection = try store.effectiveDocument["theme"]?.decoded(WidgetPackageSelection.self),
                      selection.key == choice.key, !selection.settings.isEmpty {
                edit.properties?["settings"] = .object(selection.settings)
            }
            try store.customizationHistory.change(edit)
            store.endThemeTrial()
            isActive = false
            error = nil
        } catch { self.error = "This theme couldn’t be saved. Try again or cancel." }
    }

    func cancel() {
        guard isActive else { return }
        store.endThemeTrial()
        isActive = false
    }

    @discardableResult
    func handleKey(_ keyCode: UInt16) -> Bool {
        guard isActive else { return false }
        switch keyCode {
        case 123: previous()
        case 124: next()
        case 36, 76: keep()
        case 53: cancel()
        default: return false
        }
        return true
    }
}
