import SwiftUI

struct ProfileWidgetsView: View {
    let editor: ConfigurationEditor
    let profile: ConfigurationProfile
    @State private var preview: Result<(Configuration, ConfigurationLoader), Error>?
    @State private var screens = NSScreen.screens

    private var store: BarStore { editor.store }

    var body: some View {
        Section {
            if let preview {
                switch preview {
                case let .success((configuration, loader)):
                    let names = WidgetDisplayName.names(for: configuration.widgets, packageNames: loader.widgetPackageNames,
                                                        providers: configuration.providers)
                    if configuration.widgets.isEmpty {
                        Text("No widgets in this profile. Add widgets in Your bar.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(configuration.widgets) { widget in
                        screenChoice(widget, name: names[widget.id]!, loader: loader)
                    }
                    DisclosureGroup("Widgets by screen") {
                        ForEach(screens, id: \.self) { screen in
                            let display = BarDisplay(screen: screen)
                            let shown = configuration.widgets.filter {
                                $0.enabled && $0.display.includes(display, activeID: store.activeDisplayID)
                            }
                            LabeledContent(screen.localizedName) {
                                Text(shown.isEmpty ? "None" : shown.map { names[$0.id]! }.joined(separator: ", "))
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                case let .failure(error):
                    Text(errorMessage(error)).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Widget screens")
        } footer: {
            Text("These choices apply to this profile. Choose All screens for widgets you also want on your MacBook, and The main screen for the rest. The preview shows this profile alone; other active profiles and widget output can change what appears.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: profile, initial: true) { loadPreview() }
        .onChange(of: store.effectiveDocument) { loadPreview() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }

    private func screenChoice(_ widget: WidgetConfiguration, name: String, loader: ConfigurationLoader) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(name, selection: Binding(get: { WidgetScreenChoice(widget.display) }, set: { choice in
                if choice != WidgetScreenChoice(widget.display) {
                    let value = choice == .specific
                        ? ConfigurationValue.array(screens.map { BarDisplay(screen: $0) }
                            .filter { widget.display.includes($0, activeID: store.activeDisplayID) }
                            .map { .number(Double($0.id)) })
                        : .string(choice.rawValue)
                    editor.setProfileWidgetDisplay(value, for: widget.id, profile: profile)
                }
            })) {
                ForEach(WidgetScreenChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if case let .ids(ids) = widget.display {
                let connected = screens.map { BarDisplay(screen: $0).id }
                ForEach(connected + ids.filter { !connected.contains($0) }, id: \.self) { id in
                    let screen = screens.first { BarDisplay(screen: $0).id == id }
                    Toggle(screen.map { "\($0.localizedName) (screen \(id))" } ?? "Screen \(id) (not connected)",
                           isOn: Binding(get: { ids.contains(id) }, set: { shown in
                        let selected = shown ? ids + [id] : ids.filter { $0 != id }
                        editor.setProfileWidgetDisplay(.array(selected.map { .number(Double($0)) }), for: widget.id, profile: profile)
                    }))
                }
                Text("Screen numbers can change when displays are rearranged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let origin = loader.origins["widgets.\(widget.id).display"] {
                    Text("From \(store.sourceText(origin))")
                } else {
                    Text("Default: All screens")
                }
                Spacer()
                if let origin = loader.origins["profiles.\(profile.name).configuration.widgetOverrides.\(widget.id).display"],
                   origin.file == store.configurationURL.standardizedFileURL.path {
                    Button("Reset to inherited") {
                        editor.setProfileWidgetDisplay(nil, for: widget.id, profile: profile)
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if !widget.enabled {
                Text("This widget is turned off. Changing its screens does not turn it on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func loadPreview() {
        preview = Result { try store.configurationForProfile(profile.name) }
    }
}
