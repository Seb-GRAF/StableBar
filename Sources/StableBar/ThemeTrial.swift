import Foundation
import Observation

@MainActor @Observable
final class ThemeTrial {
    private let store: BarStore
    let choices: [ThemeChoice]
    private(set) var selectedIndex: Int
    private(set) var isActive = true
    private(set) var error: String?
    private var previewFailed = false

    init(store: BarStore) {
        self.store = store
        store.barEditing.end()
        choices = ThemeCatalog(packages: store.configurationURL.deletingLastPathComponent().appending(path: "packages"),
                               themesDirectory: store.themesDirectory, selectedKey: store.selectedThemeKey).choices
        selectedIndex = choices.firstIndex { $0.key == store.selectedThemeKey } ?? 0
    }

    var choice: ThemeChoice? { choices.indices.contains(selectedIndex) ? choices[selectedIndex] : nil }
    var position: String { "\(choice == nil ? 0 : selectedIndex + 1) of \(choices.count)" }
    var canKeep: Bool { isActive && choice != nil && !previewFailed }

    func previous() { move(by: -1) }
    func next() { move(by: 1) }

    private func move(by offset: Int) {
        guard isActive, !choices.isEmpty else { return }
        selectedIndex = (selectedIndex + offset + choices.count) % choices.count
        do {
            try store.tryTheme(choices[selectedIndex])
            previewFailed = false
            error = nil
        } catch {
            previewFailed = true
            self.error = "This theme couldn’t be tried. Choose another theme."
        }
    }

    func keep() {
        guard canKeep, let choice else { return }
        do {
            try store.customizationHistory.change(store.themeEdit(for: choice))
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
