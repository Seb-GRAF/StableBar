import Foundation

enum WidgetDisplayName {
    static func title(for content: WidgetContent, providers: [String: ProviderConfiguration] = [:]) -> String {
        let type: String
        switch content {
        case .clock: type = "clock"
        case .activeApp: type = "activeApp"
        case .provider(let name): type = providers[name]?.type ?? name
        case .workspaces: type = "workspaces"
        case .text: type = "text"
        case .spacer: type = "spacer"
        case .script: type = "script"
        }
        return WidgetAddCatalog.builtIns.first { $0.id == type }?.name ?? "Custom widget"
    }

    static func name(for widget: WidgetConfiguration, packageName: String? = nil,
                     providers: [String: ProviderConfiguration] = [:]) -> String {
        if !hasGeneratedID(widget) { return widget.id }
        if let packageName, !packageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return packageName }
        if case let .text(text) = widget.content {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text.count <= 60, !text.contains(where: \.isNewline) { return text }
        }
        return title(for: widget.content, providers: providers)
    }

    static func names(for widgets: [WidgetConfiguration], packageNames: [String: String] = [:],
                      providers: [String: ProviderConfiguration] = [:]) -> [String: String] {
        let bases = Dictionary(uniqueKeysWithValues: widgets.map {
            ($0.id, name(for: $0, packageName: packageNames[$0.id], providers: providers))
        })
        let counts = Dictionary(grouping: bases.values, by: { $0 }).mapValues(\.count)
        let reserved = Set(bases.values)
        var used = Set(widgets.filter { !hasGeneratedID($0) }.map(\.id))
        var names = bases
        for widget in widgets where hasGeneratedID(widget) {
            let base = bases[widget.id]!
            var name = base
            if counts[base, default: 0] > 1 || used.contains(name) {
                var number = 1
                repeat {
                    name = "\(base) \(number)"
                    number += 1
                } while reserved.contains(name) || used.contains(name)
            }
            names[widget.id] = name
            used.insert(name)
        }
        return names
    }

    static func subtitle(for content: WidgetContent, providers: [String: ProviderConfiguration] = [:]) -> String {
        let title = title(for: content, providers: providers)
        return title == "Custom widget" ? title : title + " widget"
    }

    private static func hasGeneratedID(_ widget: WidgetConfiguration) -> Bool {
        widget.id.range(of: #"\Awidget-[0-9a-fA-F]{8}\z"#, options: .regularExpression) != nil
    }
}
