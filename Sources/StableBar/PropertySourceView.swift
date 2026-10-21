import SwiftUI

struct PropertyValueSource {
    let path: [String]
    let value: ConfigurationValue
    let resolvedValue: ConfigurationValue?
    let origin: ConfigurationOrigin?
    let title: String
}

struct PropertySources {
    let saved: PropertyValueSource?
    let effectiveValue: ConfigurationValue?
    let sources: [PropertyValueSource]
    let tokenSources: [PropertyValueSource]
    let scope: String
    let inheritedValue: ConfigurationValue?

    var editingValue: ConfigurationValue? { saved?.resolvedValue ?? saved?.value ?? inheritedValue }
    var editingFill: ConfigurationValue? {
        saved?.value ?? sources.last { $0.value.isGradient && $0.resolvedValue == editingValue }?.value ?? editingValue
    }
    var isMasked: Bool {
        guard let saved else { return false }
        let value = saved.resolvedValue ?? saved.value
        if value == .null { return effectiveValue != nil }
        if let color = try? value.decoded(HexColor.self),
           let effective = try? effectiveValue?.decoded(HexColor.self) {
            return color != effective
        }
        return value != effectiveValue
    }
}

private func selectedProperty(_ value: ConfigurationValue, at keys: [String]) -> (value: ConfigurationValue, keys: [String])? {
    var current = value
    var path: [String] = []
    for key in keys {
        if current == .null { return (current, path) }
        guard case let .object(object) = current, let next = object[key] else { return nil }
        current = next
        path.append(key)
    }
    return (current, path)
}

private func propertyValue(_ value: ConfigurationValue, at keys: [String]) -> ConfigurationValue? {
    selectedProperty(value, at: keys)?.value
}

extension ConfigurationValue {
    var sourceDescription: String {
        switch self {
        case .string(let text): text
        case .number(let number): number.formatted()
        case .bool(let value): value ? "On" : "Off"
        case .null: "null (clears this level)"
        case .object, .array:
            String(decoding: try! JSONEncoder().encode(self), as: UTF8.self)
        }
    }
}

extension BarStore {
    func propertySourceText(_ property: PropertySources) -> String? {
        if property.isMasked {
            return "Saved: \(property.saved!.value.sourceDescription) · Effective: \(property.effectiveValue?.sourceDescription ?? "App default")"
        }
        guard let source = property.sources.last else { return nil }
        return source.origin.map { "From \(sourceText($0))" } ?? source.title
    }

    func propertySources(path: String, key: String, defaultsPath: String? = nil, widgetID: String? = nil,
                         values: [String: ConfigurationValue], hover: Bool = false) -> PropertySources {
        var sources: [PropertyValueSource] = []
        let widget = widgetID.flatMap { id in configuration?.widgets.first { $0.id == id } }
        var paths = defaultsPath.map { [$0] } ?? []
        if let widget, path == "widgets.\(widget.id).style", let role = widget.role { paths.append("roles.\(role.rawValue)") }
        paths.append(path)
        let tokens = (try? effectiveDocument["tokens"]?.decoded([String: ConfigurationValue].self)) ?? [:]
        let displayedKey = hover && key == "hoverBackground" ? "background" : key

        func configurationSources(_ root: String, keys: [String]) -> [PropertyValueSource] {
            (contributions[root] ?? []).compactMap { contribution in
                let substituted = contribution.settingValue ?? contribution.value
                let raw = selectedProperty(contribution.value, at: keys)
                let value: ConfigurationValue?
                if let selected = propertyValue(substituted, at: keys) {
                    value = try? substituteConfigurationReferences(selected, prefix: "@token.", values: tokens)
                } else if let resolved = try? substituteConfigurationReferences(substituted, prefix: "@token.", values: tokens) {
                    value = propertyValue(resolved, at: keys)
                } else { value = nil }
                let reference: ConfigurationValue? = if case .string = contribution.value { contribution.value } else { nil }
                guard let rawValue = raw?.value ?? reference ?? value else { return nil }
                var origin = contribution.origin
                if case let .string(reference) = rawValue, reference.hasPrefix("@setting.") {
                    origin = origin.appending("(setting \(reference.dropFirst(9)))")
                }
                if case let .string(reference) = propertyValue(substituted, at: keys) ?? reference {
                    if reference.hasPrefix("@token.") {
                        origin.token = String(reference.dropFirst(7))
                        origin.tokenSource = origins["tokens.\(origin.token!)"]?.description ?? "not defined"
                    }
                }
                let components: [String]
                if let id = widgetID, root.hasPrefix("widgets.\(id).") {
                    components = ["widgets", id] + root.dropFirst("widgets.\(id).".count).components(separatedBy: ".")
                } else {
                    components = root.components(separatedBy: ".")
                }
                return PropertyValueSource(path: components + (raw?.keys ?? []), value: rawValue, resolvedValue: value,
                                           origin: origin, title: root + "." + keys.joined(separator: "."))
            }
        }

        for root in paths {
            if hover { sources += configurationSources(root, keys: ["background"]) }
            sources += configurationSources(root, keys: [key])
        }
        var own = configurationSources(path, keys: [key])
        if hover {
            own += configurationSources(path, keys: ["states", "hover", "background"]).filter { $0.value != .null }
        }
        let definition = widgetID.flatMap { origins["widgets.\($0).id"] }
        let mainDefinition = definition?.file == configurationURL.standardizedFileURL.path
        let saved = own.last { source in
            guard let origin = source.origin, origin.file == configurationURL.standardizedFileURL.path else { return false }
            if let profile = customizationHistory.editingProfile {
                return origin.profile == profile && !origin.detail.contains("(template ")
            }
            if widgetID != nil, mainDefinition {
                return origin.profile == definition?.profile && !origin.detail.contains("(template ") && !origin.detail.contains("(widget override)")
            }
            return setsInMainFile(origin)
        }
        var effective = values[key]
        var scope = "Value after themes, imported files and active profiles are applied."
        var runtime: [(String, WidgetStyle)] = []
        var layers: [WidgetStyle] = []
        var states = StyleStates()
        if let configuration, let widget, path == "widgets.\(widget.id).style" {
            layers = [configuration.defaults, configuration.roleStyle(widget.role), widget.style]
            for source in configuration.widgets {
                if let style = scripts[source.id]?.output.widgetStyles?[widget.id] {
                    runtime.append(("Output from \(source.id): widgetStyles", style))
                }
            }
            if let output = scripts[widget.id]?.output {
                if let style = output.style { runtime.append(("Widget output style", style)) }
                if let color = output.color { runtime.append(("Widget output color", WidgetStyle(foreground: color))) }
            }
            states = StyleStates(data: dataState(scripts[widget.id]?.output, rules: widget.rules), mode: modePresentation, hover: hover)
            scope = hover ? "Widget while hovered, with current data and mode states. Popup-open and workspace-cell states are separate."
                : "Widget at rest, with current data and mode states. Hover, popup-open and workspace-cell states are separate."
        } else if let configuration, path == "bar.style" {
            layers = [configuration.bar.style]
            for source in configuration.widgets {
                if let style = scripts[source.id]?.output.barStyle { runtime.append(("Output from \(source.id): barStyle", style)) }
            }
            states = StyleStates(mode: modePresentation)
            scope = "Bar with the current mode state and widget output overrides."
        } else if hover {
            layers = [(try? ConfigurationValue.object(values).decoded(WidgetStyle.self)) ?? WidgetStyle()]
            states = StyleStates(hover: true)
            scope = "Shared style while hovered. Individual widgets can override it."
        }
        if !layers.isEmpty {
            for (title, style) in runtime {
                if let value = propertyValue(style.configurationValue, at: [displayedKey]), value != .null {
                    sources.append(PropertyValueSource(path: [], value: value, resolvedValue: value, origin: nil, title: title))
                }
                layers.append(style)
            }
            var style = resolveStyle(layers)
            for state in states.names {
                for root in paths { sources += configurationSources(root, keys: ["states", state, displayedKey]) }
                for (title, output) in runtime {
                    if let value = propertyValue(output.configurationValue, at: ["states", state, displayedKey]), value != .null {
                        sources.append(PropertyValueSource(path: [], value: value, resolvedValue: value, origin: nil,
                                                           title: "\(title) / \(state)"))
                    }
                }
                if let active = style.states?[state] {
                    if let value = propertyValue(active.configurationValue, at: [displayedKey]), value != .null {
                        sources.append(PropertyValueSource(path: [], value: value, resolvedValue: value, origin: nil,
                                                           title: "Resolved active state: \(state)"))
                    }
                    style = resolveStyle([style, active])
                }
            }
            effective = propertyValue(resolveStyle(layers, states: states).configurationValue, at: [displayedKey])
        }
        var tokenSources: [PropertyValueSource] = []
        var tokenNames = Set<String>()
        func appendToken(_ name: String) {
            guard tokenNames.insert(name).inserted else { return }
            let entries = contributions["tokens.\(name)"] ?? []
            for entry in entries {
                let value = entry.settingValue ?? entry.value
                tokenSources.append(PropertyValueSource(path: ["tokens", name], value: entry.value,
                    resolvedValue: try? substituteConfigurationReferences(value, prefix: "@token.", values: tokens),
                    origin: entry.origin, title: "Token \(name)"))
            }
            if case let .string(reference)? = entries.last.map({ $0.settingValue ?? $0.value }), reference.hasPrefix("@token.") {
                appendToken(String(reference.dropFirst(7)))
            }
        }
        for source in sources {
            if let token = source.origin?.token { appendToken(token) }
            for (_, value) in configurationValues(source.value, path: "value").sorted(by: { $0.key < $1.key }) {
                if case let .string(reference) = value, reference.hasPrefix("@token.") {
                    appendToken(String(reference.dropFirst(7)))
                }
            }
        }
        return PropertySources(saved: saved, effectiveValue: effective == .null ? nil : effective,
                               sources: sources, tokenSources: tokenSources, scope: scope, inheritedValue: values[key])
    }

    func removePropertySource(_ source: PropertyValueSource, everyBar: Bool = false) throws {
        let origin = source.origin!
        var path = source.path
        if origin.detail.contains("(widget override)") { path[0] = "widgetOverrides" }
        if let profile = origin.profile, profile != customizationHistory.editingProfile {
            path = ["profiles", profile, "configuration"] + path
        }
        let mask = path.dropFirst().reversed().reduce(ConfigurationValue.null) { .object([$1: $0]) }
        try customizationHistory.change(ConfigurationEdit(action: .unset, properties: [path[0]: mask]), everyBar: everyBar)
    }
}

struct PropertySourceView: View {
    let store: BarStore
    let title: String
    let property: PropertySources
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(property.scope).font(.callout).foregroundStyle(.secondary)
            if let saved = property.saved {
                HStack {
                    Text("Saved value")
                    Spacer()
                    Text(saved.value.sourceDescription).textSelection(.enabled)
                }
                if property.isMasked { Text("Your saved value is currently overridden. Editing it changes the saved value; the source below still controls the result.").foregroundStyle(.orange) }
            } else {
                Text("This setting is inherited. Editing it creates a value in your configuration.").foregroundStyle(.secondary)
            }
            HStack {
                Text("Effective value")
                Spacer()
                Text(property.effectiveValue?.sourceDescription ?? "App default").textSelection(.enabled)
            }
            Divider()
            Text("Sources, lowest priority first").font(.subheadline.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(property.sources.enumerated()), id: \.offset) { _, source in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.origin.map(store.sourceText) ?? source.title).font(.callout.bold())
                            Text(source.title).font(.caption).foregroundStyle(.secondary)
                            Text(source.value.sourceDescription).textSelection(.enabled)
                            if let value = source.resolvedValue, value != source.value {
                                Text("Resolves to \(value.sourceDescription)").font(.caption).foregroundStyle(.secondary)
                            }
                            if let origin = source.origin {
                                HStack {
                                    if let profile = origin.profile, let open = store.onCustomizeProfile {
                                        Button("Open profile \(profile)") { open(profile) }
                                    }
                                    Button("Open source file") { NSWorkspace.shared.open(URL(filePath: origin.file)) }
                                    if store.setsInMainFile(origin), origin.detail == "(widget override)",
                                       source.path.first == "widgets" {
                                        Button("Remove this override") { removeOverride(source) }
                                    }
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    if !property.tokenSources.isEmpty {
                        Divider()
                        Text("Referenced token definitions").font(.subheadline.bold())
                        ForEach(Array(property.tokenSources.enumerated()), id: \.offset) { _, source in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.title).font(.callout.bold())
                                Text(source.value.sourceDescription).textSelection(.enabled)
                                if let origin = source.origin {
                                    Text(store.sourceText(origin)).font(.caption).foregroundStyle(.secondary)
                                    Button("Open token source") { NSWorkspace.shared.open(URL(filePath: origin.file)) }.buttonStyle(.link)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            Text("Reset removes your saved property so the inherited value can apply. A saved null clears that level; it is not the same as removing the property.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func removeOverride(_ source: PropertyValueSource) {
        do {
            try store.removePropertySource(source)
            error = nil
        } catch { self.error = errorMessage(error) }
    }
}
