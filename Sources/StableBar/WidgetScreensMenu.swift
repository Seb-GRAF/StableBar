import AppKit
import SwiftUI

struct WidgetScreensMenu: View {
    let store: BarStore
    let widget: WidgetConfiguration
    let screen: ScreenKind
    let set: ([String: ConfigurationValue]) -> Void

    var body: some View {
        let displays = NSScreen.screens.map(BarDisplay.init)
        let shown = ScreenKind.allCases.filter { widget.enabled && $0.shows(widget.display, among: displays, activeID: store.activeDisplayID) }
        let choice = widget.enabled ? WidgetScreenChoice(widget.display) : nil
        item("All screens", isOn: choice == .all || choice == .several && shown == ScreenKind.allCases) { show(WidgetScreenChoice.all.properties!) }
        item("Only on \(screen.phrase)", isOn: choice == .several && shown == [screen]) { show(["display": .array([.string(screen.selection)])]) }
        Section("Kinds of screen") {
            ForEach(ScreenKind.allCases, id: \.self) { kind in
                item(kind.name, isOn: shown.contains(kind)) {
                    let kinds = ScreenKind.allCases.filter { $0 == kind ? !shown.contains(kind) : shown.contains($0) }
                    show(["display": .array(kinds.map { .string($0.selection) })])
                }
            }
        }
        Menu("Other rules") {
            ForEach([WidgetScreenChoice.active, .main, .external, .notched, .unnotched], id: \.self) { rule in
                item(rule.title, isOn: choice == rule) { show(rule.properties!) }
            }
        }
        Divider()
        item("Hidden everywhere", isOn: !widget.enabled || choice == .several && shown.isEmpty) { set(["enabled": .bool(false)]) }
    }

    private func item(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { _ in action() }))
    }

    private func show(_ properties: [String: ConfigurationValue]) {
        set(widget.enabled ? properties : properties.merging(["enabled": .bool(true)]) { $1 })
    }
}

extension BarStore {
    func screensTitle(for widget: WidgetConfiguration) -> String {
        guard widget.enabled else { return "Hidden everywhere" }
        guard case .any = widget.display else { return WidgetScreenChoice(widget.display).title }
        let displays = NSScreen.screens.map(BarDisplay.init)
        let kinds = ScreenKind.allCases.filter { $0.shows(widget.display, among: displays, activeID: activeDisplayID) }
        if kinds.isEmpty { return "Hidden everywhere" }
        return kinds == ScreenKind.allCases ? "All screens" : kinds.map(\.name).joined(separator: " and ") + " only"
    }
}
