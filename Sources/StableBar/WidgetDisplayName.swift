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
        if let packageName, !packageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return packageName }
        if case let .text(text) = widget.content {
            let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text.count <= 60, !text.contains(where: \.isNewline) { return text }
        }
        return title(for: widget.content, providers: providers)
    }
}
