import AppKit
import SwiftUI
import UniformTypeIdentifiers

private extension WidgetTransition {
    var title: String {
        switch self {
        case .none: "None"
        case .fade: "Fade"
        case .roll: "Roll"
        case .numeric: "Numeric"
        }
    }
}

extension WidgetConfiguration {
    /// Whether `transition` changes anything: workspaces and spacers draw their own views, which
    /// have no text or symbols to transition, unless they have a `layout` or `overlay`.
    var drawsTransitions: Bool {
        switch content {
        case .workspaces, .spacer: layout != nil || overlay != nil
        default: true
        }
    }
}

extension WidgetContent {
    var symbol: String {
        switch self {
        case .spacer: "arrow.left.and.right"
        case let .provider(name): DataSourceRegistry.builtIn[name]?.symbol ?? "gauge.with.dots.needle.33percent"
        case .workspaces: "rectangle.3.group"
        case .activeApp: "macwindow"
        case .clock: "clock"
        case .text: "textformat"
        case .script: "terminal"
        }
    }
}

struct WidgetsView: View {
    @Bindable var editor: ConfigurationEditor
    @State private var advanced = "{}"
    @State private var setup: WidgetSetup
    @State private var adding = false
    @State private var dragSession = WidgetDragSession()
    @State private var expanded = false
    @State private var customClockFormat = false
    @State private var editingWebPage = false
    @State private var webPage = ""
    @State private var clickError: String?
    @State private var fontFamilies = NSFontManager.shared.availableFontFamilies

    init(editor: ConfigurationEditor) {
        self.editor = editor
        _setup = State(initialValue: WidgetSetup(store: editor.store))
    }

    private var positions: [WidgetPosition] {
        WidgetPlacement.positions(widgets: widgets, hasNotchedDisplay: NSScreen.screens.contains { $0.auxiliaryTopLeftArea != nil })
    }

    private var store: BarStore { editor.store }
    private var widgets: [WidgetConfiguration] { store.configuration?.widgets ?? [] }
    private var displayNames: [String: String] {
        WidgetDisplayName.names(for: widgets, packageNames: store.widgetPackageNames, providers: store.configuration?.providers ?? [:])
    }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 210, maxWidth: 280)
            Group {
                if let widget = widgets.first(where: { $0.id == editor.selectedID }) {
                    inspector(widget)
                        .id(widget.id)
                } else {
                    ContentUnavailableView("Select a widget", systemImage: "sidebar.left",
                                           description: Text("Choose a widget to change how it looks and where it sits."))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: editor.selected, initial: true) {
            var properties = editor.selected
            properties["id"] = nil
            advanced = (try? String(decoding: configurationData(properties), as: UTF8.self)) ?? "{}"
        }
        .onChange(of: editor.selectedID) {
            customClockFormat = false
            clickError = nil
            expanded = false
        }
        .sheet(isPresented: $adding) {
            WidgetAddView(setup: setup, store: store,
                          position: WidgetPlacement.destination(selectedID: editor.selectedID, widgets: widgets)) { id in
                editor.selectedID = id
                adding = false
            }
        }
    }

    private var sidebar: some View {
        let names = displayNames
        return VStack(spacing: 0) {
            HStack {
                Button(store.barEditing.menuTitle, action: store.barEditing.toggle)
                    .accessibilityLabel(store.barEditing.menuTitle)
                    .disabled(!store.barEditing.isAvailable)
                Spacer()
            }
            .padding(8)
            Divider()
            List(selection: $editor.selectedID) {
                ForEach(positions, id: \.self) { position in
                    let section = widgets.filter { $0.position == position }
                    Section(position.title) {
                        ForEach(section) { widget in
                            let name = names[widget.id] ?? typeName(widget)
                            WidgetDragRow(session: dragSession, widgetID: widget.id, name: name,
                                          insertionKey: dropKey(position, before: widget.id),
                                          select: { editor.selectedID = widget.id },
                                          move: { move($0, to: position, before: widget.id) }) {
                                Label {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(name).lineLimit(1)
                                        Text(typeName(widget)).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: widget.content.symbol)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .opacity(widget.enabled ? 1 : 0.45)
                                .padding(.vertical, 2)
                            }
                            .tag(widget.id)
                            .overlay(alignment: .top) {
                                if dragSession.insertion == position.rawValue + "/" + widget.id {
                                    Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(name)
                            .accessibilityAction(named: Text("Move up")) { moveBy(-1, id: widget.id) }
                            .accessibilityAction(named: Text("Move down")) { moveBy(1, id: widget.id) }
                            .contextMenu {
                                Button("Move Up") { moveBy(-1, id: widget.id) }
                                Button("Move Down") { moveBy(1, id: widget.id) }
                                Menu("Move To") {
                                    ForEach(WidgetPlacement.destinations, id: \.self) { target in
                                        Button(target.menuTitle) { move(widget.id, to: target) }
                                    }
                                }
                            }
                        }
                        WidgetDragRow(session: dragSession, widgetID: nil, name: "", insertionKey: dropKey(position),
                                      select: {}, move: { move($0, to: position) }) {
                            Text(section.isEmpty ? "Drop a widget here" : " ")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                        }
                        .selectionDisabled()
                        .accessibilityHidden(!section.isEmpty)
                        .overlay(alignment: .top) {
                            if dragSession.insertion == dropKey(position) {
                                Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 0) {
                Button { adding = true } label: {
                    Label("Add widget", systemImage: "plus").frame(height: 24)
                }
                .help("Add a widget")
                .accessibilityLabel("Add widget")
                Divider().frame(height: 16)
                Button {
                    editor.change(ConfigurationEdit(action: .remove, id: editor.selectedID!))
                } label: {
                    Image(systemName: "minus").frame(width: 28, height: 24)
                }
                .help("Remove the selected widget")
                .accessibilityLabel("Remove the selected widget")
                .disabled(editor.selectedID == nil)
                Spacer()
                Button {
                    if let id = editor.selectedID { moveBy(-1, id: id) }
                } label: { Image(systemName: "arrow.up").frame(width: 24, height: 24) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                .help("Move the selected widget up")
                .accessibilityLabel("Move up")
                .disabled(editor.selectedID == nil)
                Button {
                    if let id = editor.selectedID { moveBy(1, id: id) }
                } label: { Image(systemName: "arrow.down").frame(width: 24, height: 24) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                .help("Move the selected widget down")
                .accessibilityLabel("Move down")
                .disabled(editor.selectedID == nil)
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
    }

    private func inspector(_ widget: WidgetConfiguration) -> some View {
        let style = StyleFields(store: store, path: "widgets.\(widget.id).style", defaultsPath: "defaults", widgetID: widget.id,
                                values: editor.style(for: widget.id), set: { editor.set(["style": .object($0)], for: widget.id) },
                                unset: { editor.change(ConfigurationEdit(action: .unset, id: widget.id, properties: ["style": .object($0)])) })
        return Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: widget.content.symbol)
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayNames[widget.id] ?? typeName(widget)).font(.title3.weight(.semibold))
                        Text(WidgetDisplayName.subtitle(for: widget.content, providers: store.configuration?.providers ?? [:]))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: Binding(get: {
                        widget.enabled
                    }, set: { editor.set(["enabled": .bool($0)], for: widget.id) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Show this widget in the bar")
                    .accessibilityLabel("Show this widget in the bar")
                }
            }
            Section("Content") {
                if widget.content != .spacer && widget.content != .workspaces { iconField(widget) }
                if case .text = widget.content { TextField("Text", text: string("text", for: widget)) }
                if case let .clock(format) = widget.content {
                    Picker("Date format", selection: Binding(get: {
                        !customClockFormat && WidgetClockFormat.common.contains { $0.value == format } ? format : "custom"
                    }, set: { value in
                        customClockFormat = value == "custom"
                        if !customClockFormat { editor.set(["format": .string(value)], for: widget.id) }
                    })) {
                        ForEach(WidgetClockFormat.common, id: \.value) { Text($0.title).tag($0.value) }
                        Text("Custom format").tag("custom")
                    }
                    if customClockFormat || !WidgetClockFormat.common.contains(where: { $0.value == format }) {
                        TextField("Custom format", text: string("format", for: widget, fallback: format))
                    }
                }
            }
            Section {
                clickFields(widget)
                Picker("Screens", selection: Binding(get: { WidgetScreenChoice(widget.display) }, set: {
                    if $0 != WidgetScreenChoice(widget.display), let properties = $0.properties { editor.set(properties, for: widget.id) }
                })) {
                    ForEach(WidgetScreenChoice.allCases.filter { $0 != .specific || WidgetScreenChoice(widget.display) == .specific }, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                if case let .ids(ids) = widget.display {
                    Text("Specific screens: \(ids.map(String.init).joined(separator: ", ")). Edit the list under Advanced.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Picker("Position", selection: Binding(get: { widget.position }, set: { if $0 != widget.position { move(widget.id, to: $0) } })) {
                    ForEach(WidgetPlacement.destinations, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $expanded) {
                    LabeledContent("ID", value: widget.id).textSelection(.enabled)
                    let origin = store.origins["widgets.\(widget.id).role"]
                    OverrideRow(title: "Presentation role", source: origin.map { "From \(store.sourceText($0))" },
                                reset: origin.map(store.setsInMainFile) == true ? {
                        editor.change(ConfigurationEdit(action: .unset, id: widget.id, properties: ["role": .null]))
                    } : nil) {
                        Picker("Presentation role", selection: Binding(get: { widget.role?.rawValue ?? "" }, set: {
                            if $0 != (widget.role?.rawValue ?? "") {
                                editor.set(["role": $0.isEmpty ? .null : .string($0)], for: widget.id)
                            }
                        })) {
                            Text("None").tag("")
                            ForEach(PresentationRole.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                        }
                        .labelsHidden()
                    }
                    if widget.content == .spacer || widget.content == .workspaces { iconField(widget) }
                    if widget.drawsTransitions {
                        Picker("Transition", selection: string("transition", for: widget, fallback: WidgetTransition.none.rawValue)) {
                            ForEach(WidgetTransition.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                        }
                        .help("How the widget's text and symbols change")
                    }
                    Divider()
                    Text("Colors").font(.headline)

                    style.color("Text", "foreground")
                    style.color("Background", "background")
                    style.hoverBackground("Hover background")
                    style.color("Border", "borderColor")
                    style.color("Accent", "accent")
                    Divider()
                    Text("Text and shape").font(.headline)

                    style.font(fontFamilies)
                    style.weight()
                    style.number("Font size", "fontSize", default: 12)
                    style.number("Horizontal padding", "paddingHorizontal", default: 10)
                    style.number("Vertical padding", "paddingVertical", default: 6)
                    style.number("Corner radius", "cornerRadius", default: 14)
                    style.number("Border width", "borderWidth", default: 1)
                    if widget.content == .workspaces {
                        Divider()
                        Text("Workspace presentation").font(.headline)
                        WorkspacePresentationFields(store: store, path: "widgets.\(widget.id).workspace", defaultsPath: "workspaceDefaults",
                            values: (try? store.configuration?.workspaceDefaults.mergedProperties(editor.properties(for: widget.id)["workspace"])) ?? [:],
                            set: { editor.set(["workspace": .object($0)], for: widget.id) },
                            unset: { editor.change(ConfigurationEdit(action: .unset, id: widget.id, properties: ["workspace": .object($0)])) })
                    }
                    DisclosureGroup("JSON editor") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Edit this widget's properties as JSON. Removing a property clears it. Templates and included files stay intact.")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $advanced)
                                .font(.system(.body, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .frame(height: 160)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                            HStack {
                                Spacer()
                                Button("Apply properties") {
                                    do {
                                        editor.replaceProperties(try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(advanced.utf8)))
                                    } catch { editor.error = errorMessage(error) }
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $editingWebPage) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Open a web page").font(.headline)
                TextField("Web address", text: $webPage).frame(width: 360)
                if let clickError { Text(clickError).foregroundStyle(.red) }
                HStack {
                    Spacer()
                    Button("Cancel") { editingWebPage = false }.keyboardShortcut(.cancelAction)
                    Button("Done") {
                        setClick(.webPage, widget: widget, value: webPage)
                        if clickError == nil { editingWebPage = false }
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24)
        }
    }

    private func iconField(_ widget: WidgetConfiguration) -> some View {
        LabeledContent("Icon") {
            HStack {
                TextField("Icon", text: string("icon", for: widget), prompt: Text("SF Symbol name")).labelsHidden()
                Image(systemName: string("icon", for: widget).wrappedValue).foregroundStyle(.secondary).frame(width: 20)
            }
        }
    }

    @ViewBuilder private func clickFields(_ widget: WidgetConfiguration) -> some View {
        switch WidgetClickChoice.control(for: widget, output: store.scripts[widget.id]?.output) {
        case .hidden: EmptyView()
        case .explanation(let explanation):
            LabeledContent("When clicked") { Text(explanation).foregroundStyle(.secondary) }
        case .choices:
            Picker("When clicked", selection: Binding(get: { WidgetClickChoice.current(for: widget, output: store.scripts[widget.id]?.output) }, set: { choice in
                guard choice != WidgetClickChoice.current(for: widget, output: store.scripts[widget.id]?.output) else { return }
                switch choice {
                case .nothing: setClick(.nothing, widget: widget)
                case .application: chooseApplication(widget)
                case .webPage:
                    webPage = WidgetClickChoice.current(for: widget, output: store.scripts[widget.id]?.output) == .webPage ? widget.open ?? "" : "https://"
                    editingWebPage = true
                case .advanced: break
                }
            })) {
                ForEach(WidgetClickChoice.allCases.filter { $0 != .advanced }, id: \.self) { Text($0.title).tag($0) }
            }
            if let open = widget.open {
                Text(open).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Button(WidgetClickChoice.current(for: widget, output: store.scripts[widget.id]?.output) == .application ? "Choose another app…" : "Edit web page…") {
                    if WidgetClickChoice.current(for: widget, output: store.scripts[widget.id]?.output) == .application { chooseApplication(widget) }
                    else { webPage = open; editingWebPage = true }
                }
            }
            if let clickError { Text(clickError).foregroundStyle(.red) }
        }
    }

    private func setClick(_ choice: WidgetClickChoice, widget: WidgetConfiguration, value: String? = nil) {
        do {
            editor.set(try choice.properties(for: widget, value: value, output: store.scripts[widget.id]?.output), for: widget.id)
            clickError = nil
        } catch { clickError = errorMessage(error) }
    }

    private func chooseApplication(_ widget: WidgetConfiguration) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose app"
        if panel.runModal() == .OK, let url = panel.url {
            setClick(.application, widget: widget, value: Bundle(url: url)?.bundleIdentifier)
        }
    }

    private func move(_ id: String, to position: WidgetPosition, before anchor: String? = nil) {
        do { try setup.move(id, to: position, before: anchor) }
        catch { editor.error = errorMessage(error) }
    }

    private func moveBy(_ offset: Int, id: String) {
        do { try setup.move(id, by: offset) }
        catch { editor.error = errorMessage(error) }
    }

    private func dropKey(_ position: WidgetPosition, before anchor: String? = nil) -> String {
        let target = widgets.first { $0.id == anchor }
        let first = target.flatMap { target in
            widgets.first { $0.id == target.id || (target.group != nil && $0.group == target.group) }?.id
        }
        return position.rawValue + "/" + (first ?? "")
    }

    private func typeName(_ widget: WidgetConfiguration) -> String {
        WidgetDisplayName.title(for: widget.content, providers: store.configuration?.providers ?? [:])
    }

    private func string(_ key: String, for widget: WidgetConfiguration, fallback: String = "") -> Binding<String> {
        let value = if case let .string(value) = editor.properties(for: widget.id)[key] { value } else { fallback }
        return Binding(get: { value }, set: { if $0 != value { editor.set([key: .string($0)], for: widget.id) } })
    }
}
