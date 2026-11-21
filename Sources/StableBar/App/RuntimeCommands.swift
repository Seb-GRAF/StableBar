import AppKit

extension BarStore {
    func handle(_ request: RuntimeRequest) throws -> ConfigurationValue {
        switch request.action {
        case .report:
            return try JSONDecoder().decode(ConfigurationValue.self, from: JSONEncoder().encode(liveReport()))
        case .status:
            return .object(AppVersion().fields.merging(["running": .bool(true), "pid": .number(Double(getpid())),
                                                        "configuration": .string(configurationStore.sharedConfigurationURL.path)]) { $1 })
        case .quit:
            // Terminating right away would exit before the command gets its reply.
            Task { NSApp.terminate(nil) }
        case .customize:
            if let id = request.id { onWindowRequest?(.customizeItem(.widget(id))) }
            else { onWindowRequest?(.customize) }
        case .reload:
            barEditing.end()
            try configurationStore.applyEdits([], persist: false)
        case .batch: try configurationStore.applyEdits(request.edits ?? [], persist: request.persist)
        case .uninstallPackage:
            guard let id = request.id, let version = request.version else {
                throw CommandFailure(message: "Uninstall requires a package id and version.")
            }
            try configurationStore.uninstallPackage(id: id, version: version)
        case .reset: try configurationStore.setSessionEdits([])
        case .refresh:
            guard let id = request.id, let script = widgetScripts.scripts[id] else { throw CommandFailure(message: "Refresh requires a running widget id.") }
            guard !script.diagnostics.suspended else {
                throw CommandFailure(message: "Widget is suspended. Choose Resume for testing in Status or make a consumer visible before refreshing.")
            }
            widgetScripts.refresh(configuration!.widgets.first { $0.id == id }!, event: ScriptEvent(sender: "manual"))
        case .closePopup where request.id == nil:
            popup.closeAll()
        case .popup, .openPopup, .closePopup:
            guard let id = request.id, configuration?.widgets.contains(where: { $0.id == id }) == true else {
                throw CommandFailure(message: "Unknown widget: \(request.id ?? "").")
            }
            // Duration traps on more seconds than it can hold, which would crash the bar.
            if let duration = request.duration, duration <= 0 || duration > 86_400 {
                throw CommandFailure(message: "--duration must be greater than zero and at most one day (86400 seconds).")
            }
            if widgetScripts.popupWidgetID == id || popup.pins.ids.contains(id) {
                if request.action == .openPopup { break }
                if widgetScripts.popupWidgetID == id { popup.close() } else { popup.closePinned(id) }
                break
            }
            if request.action == .closePopup { break }
            func find(_ name: String, in view: NSView) -> NSView? {
                view.identifier?.rawValue == name ? view : view.subviews.lazy.compactMap { find(name, in: $0) }.first
            }
            let activeID = workspaceStore.workspaces.first(where: \.isFocused)?.monitor ?? appWatcher.activeDisplayID
            guard let bar = barPanel(activeID),
                  let widget = barEditing.widgets(on: BarDisplay(screen: bar.screen!)).first(where: { $0.id == id }),
                  let anchor = find(id, in: bar.contentView!)
                    ?? find(BarView.moreWidgetsID(widget.position, notched: configuration!.bar(on: ScreenKind(BarDisplay(screen: bar.screen!)))
                        .notch(on: BarDisplay(screen: bar.screen!)) != nil), in: bar.contentView!) else {
                throw CommandFailure(message: "Widget \(id) is not on the bar of the active display.")
            }
            guard let content = widgetPopup(widget, store: self) else {
                throw CommandFailure(message: "Widget \(id) has no popup or menu.")
            }
            let config = configuration!.onScreen(ScreenKind(BarDisplay(screen: bar.screen!)))
            popup.open(content, widget: widget, defaults: config.popupDefaults.popupStyle(over: config.defaults),
                       store: self, anchor: anchor, onHover: false)
            if let duration = request.duration { popup.close(after: .seconds(duration)) }
        case .focus:
            let activeID = workspaceStore.workspaces.first(where: \.isFocused)?.monitor ?? appWatcher.activeDisplayID
            guard let bar = barPanel(activeID) else { throw CommandFailure(message: "No bar on the active display.") }
            bar.focusWidgets()
        case .trigger:
            guard let event = request.id else { throw CommandFailure(message: "Trigger requires an event name.") }
            widgetScripts.refreshScripts(for: event, environment: withoutShellVariables(request.environment ?? [:]))
        case .query: break
        // AppDelegate, which owns the bar's windows, hides or shows them before passing these on.
        case .hide, .show, .toggle: break
        }
        return try snapshot(id: request.action == .query ? request.id : nil)
    }

    func snapshot(id: String? = nil) throws -> ConfigurationValue {
        if let id {
            let definitions = try effectiveDocument["widgets"]?.decoded([[String: ConfigurationValue]].self) ?? []
            guard let definition = definitions.first(where: { $0["id"] == .string(id) }) else {
                throw CommandFailure(message: "Unknown widget: \(id).")
            }
            var result: [String: ConfigurationValue] = ["configuration": .object(definition),
                "defaults": effectiveDocument["defaults"] ?? .object([:]),
                "origins": .object(origins.filter { $0.key.hasPrefix("widgets.\(id).") }.mapValues { .string($0.description) })]
            result["mode"] = workspaceStore.mode.map(ConfigurationValue.string) ?? .null
            result["modeStates"] = .array(StyleStates(mode: barPresentation.modePresentation).names.map(ConfigurationValue.string))
            result["modeConnectionError"] = workspaceStore.connectionError.map(ConfigurationValue.string) ?? .null
            if let widget = configuration?.widgets.first(where: { $0.id == id }) {
                let prefixes = ["widgets.\(id)", "defaults", "popupDefaults", "workspaceDefaults", "modeAliases", "roles"]
                    + (widget.popupName.map { ["popups.\($0)"] } ?? [])
                result["origins"] = .object(origins.filter { entry in
                    prefixes.contains { entry.key == $0 || entry.key.hasPrefix($0 + ".") }
                }.mapValues { .string($0.description) })
                result["role"] = widget.role.map { .string($0.rawValue) } ?? .null
                result["resolvedStyle"] = barPresentation.presentations[id]?.style.style(hovered: false).configurationValue ?? .object([:])
                result["presentationLayers"] = .array(presentationLayers(for: widget))
                if widget.content == .workspaces {
                    result["workspacePresentation"] = .object(try configuration!.workspaceDefaults.mergedProperties(definition["workspace"]))
                }
                let shown = label(for: widget)
                result["text"] = .string(shown.text)
                result["icon"] = shown.icon.map(ConfigurationValue.string) ?? .null
                result["fields"] = .object(shown.fields.mapValues(ConfigurationValue.string))
            }
            if let script = widgetScripts.scripts[id] {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                result["diagnostics"] = try JSONDecoder().decode(ConfigurationValue.self, from: encoder.encode(script.diagnostics))
                result["samples"] = .array(script.samples.map(ConfigurationValue.number))
                result["latestOutput"] = (try? JSONDecoder().decode(ConfigurationValue.self, from: Data(script.diagnostics.lastStdout.utf8)))
                    ?? .string(script.diagnostics.lastStdout)
                result["error"] = script.error.map(ConfigurationValue.string) ?? .null
                result["values"] = .object((script.output.values ?? [:]).mapValues(ConfigurationValue.number))
                result["state"] = barPresentation.presentations[id]?.style.state.map(ConfigurationValue.string) ?? .null
                result["temporaryFields"] = barPresentation.presentations[id]?.temporaryFields
                    .map { ConfigurationValue.object($0.mapValues(ConfigurationValue.string)) } ?? .null
                if let name = configuration?.widgets.first(where: { $0.id == id })?.providerName,
                   let provider = configuration?.providers[name], let type = registry[provider.type] {
                    result["source"] = .object(["provider": .string(name), "type": .string(type.name), "push": .bool(type.continuous),
                                                "events": .array(type.events.map { .string($0.rawValue) })])
                }
            }
            return .object(result)
        }
        let barLayers: [ConfigurationValue] = [.object(["source": .string("bar.style"),
            "style": configuration?.bar.style.configurationValue ?? .object([:])])]
            + (configuration?.widgets ?? []).compactMap { widget in
                widgetScripts.scripts[widget.id]?.output.barStyle.map { .object(["source": .string("output.\(widget.id).barStyle"),
                                                                 "style": $0.configurationValue]) }
            }
        return .object(["configuration": .object(effectiveDocument),
                        "mode": workspaceStore.mode.map(ConfigurationValue.string) ?? .null,
                        "modeStates": .array(StyleStates(mode: barPresentation.modePresentation).names.map(ConfigurationValue.string)),
                        "modeConnectionError": workspaceStore.connectionError.map(ConfigurationValue.string) ?? .null,
                        "resolvedBarStyle": barPresentation.barStyle.configurationValue,
                        "barPresentationLayers": .array(barLayers),
                        "origins": .object(origins.mapValues { .string($0.description) }),
                        "profiles": .array(activeProfiles.map(ConfigurationValue.string)),
                        "sessionEdits": .number(Double(configurationStore.sessionEdits.count)),
                        "popup": widgetScripts.popupWidgetID.map(ConfigurationValue.string) ?? .null,
                        "error": configurationError.map(ConfigurationValue.string) ?? .null,
                        "warning": configurationWarning.map(ConfigurationValue.string) ?? .null].merging(AppVersion().fields) { $1 })
    }

    private func presentationLayers(for widget: WidgetConfiguration) -> [ConfigurationValue] {
        guard let configuration else { return [] }
        func layer(_ source: String, _ style: WidgetStyle) -> ConfigurationValue {
            .object(["source": .string(source), "style": style.configurationValue])
        }
        var layers = [layer("defaults", configuration.defaults)]
        if let role = widget.role { layers.append(layer("roles.\(role.rawValue)", configuration.roleStyle(role))) }
        if let group = widget.group { layers.append(layer("groups.\(group).style.foreground", configuration.groupStyle(of: widget))) }
        layers.append(layer("widgets.\(widget.id).style", widget.style))
        if let background = widget.background {
            layers.append(layer("widgets.\(widget.id).background", WidgetStyle(background: background)))
        }
        for source in configuration.widgets {
            if let style = widgetScripts.scripts[source.id]?.output.widgetStyles?[widget.id] {
                layers.append(layer("output.\(source.id).widgetStyles.\(widget.id)", style))
            }
        }
        if let own = widgetScripts.scripts[widget.id]?.output {
            if let style = own.style { layers.append(layer("output.\(widget.id).style", style)) }
            if let color = own.color { layers.append(layer("output.\(widget.id).color", WidgetStyle(foreground: color))) }
        }
        return layers
    }
}
