import AppKit
import SwiftUI

@MainActor
final class CustomizationWindow: NSObject, NSWindowDelegate {
    private weak var store: BarStore?
    private var window: NSWindow?

    func show(store: BarStore) {
        self.store = store
        store.setInspectorOpen(true)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Customize StableBar"
            window.delegate = self
            window.minSize = NSSize(width: 900, height: 600)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: CustomizationView(store: store))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window!.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { store?.setInspectorOpen(false) }
}

private enum CustomizationSection: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", widgets = "Widgets", profiles = "Profiles", packages = "Packages", diagnostics = "Diagnostics"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .widgets: "square.grid.2x2"
        case .profiles: "person.crop.square"
        case .packages: "shippingbox"
        case .diagnostics: "stethoscope"
        }
    }
}

private struct CustomizationView: View {
    let store: BarStore
    @State private var editor: ConfigurationEditor
    @State private var section: CustomizationSection? = .appearance

    init(store: BarStore) {
        self.store = store
        _editor = State(initialValue: ConfigurationEditor(store: store))
    }

    var body: some View {
        HStack(spacing: 0) {
            List(CustomizationSection.allCases, selection: $section) { section in
                Label(section.rawValue, systemImage: section.symbol)
            }
            .listStyle(.sidebar)
            .frame(width: 180)
            Divider()
            VStack(spacing: 0) {
                switch section ?? .appearance {
                case .general: GeneralView(store: store)
                case .appearance: AppearanceView(editor: editor)
                case .widgets: WidgetsView(editor: editor)
                case .profiles: ProfilesView(editor: editor)
                case .packages: PackagesView(store: store)
                case .diagnostics: DiagnosticsView(store: store)
                }
                if [.appearance, .widgets, .profiles].contains(section ?? .appearance) {
                    if let error = editor.error ?? store.configurationError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.red.opacity(0.1))
                    }
                    Divider()
                    footer
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            ControlGroup {
                Button("Undo", systemImage: "arrow.uturn.backward", action: editor.undo)
                    .keyboardShortcut("z").disabled(editor.undoSteps.isEmpty).help("Undo")
                Button("Redo", systemImage: "arrow.uturn.forward", action: editor.redo)
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(editor.redoSteps.isEmpty).help("Redo")
            }
            .labelStyle(.iconOnly)
            .fixedSize()
            Group {
                if store.sessionEdits.isEmpty {
                    Text("All changes saved")
                } else {
                    Text("^[\(store.sessionEdits.count) unsaved change](inflect: true)")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Discard", action: editor.discard).disabled(store.sessionEdits.isEmpty)
            Button("Save", action: editor.save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s")
                .disabled(store.sessionEdits.isEmpty)
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct GeneralView: View {
    let store: BarStore

    var body: some View {
        Form {
            Section {
                LabeledContent("File") {
                    Text(store.configurationURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Open File", action: store.openConfiguration)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.configurationURL]) }
                    Spacer()
                    Button("Reload", action: store.reloadConfiguration)
                }
            } header: {
                Text("Configuration")
            } footer: {
                Text("StableBar applies saved changes on its own. Reload reads the files again.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    Button("Set Up StableBar…") { NSApp.sendAction(#selector(AppDelegate.showSetup), to: NSApp.delegate, from: nil) }
                } label: {
                    Text("Setup")
                    Text("Theme, appearance, placement, clock format and opening at login.")
                }
            }
            Section("Workspaces") {
                LabeledContent(store.workspaceStore.source.title) {
                    Button("Reconnect", action: store.workspaceStore.reconnect)
                }
                if let error = store.workspaceStore.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension WidgetPosition {
    var title: String {
        switch self {
        case .left: "Left"
        case .notchLeft: "Left of notch"
        case .center: "Center"
        case .notchRight: "Right of notch"
        case .right: "Right"
        }
    }
}

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

private extension WidgetContent {
    var title: String {
        switch self {
        case .spacer: "Spacer"
        case let .provider(name): name.capitalized
        case .workspaces: "Workspaces"
        case .activeApp: "Active app"
        case .clock: "Clock"
        case .text: "Text"
        case .script: "Script"
        }
    }

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

    var newWidgetProperties: [String: ConfigurationValue] {
        switch self {
        case .spacer: ["type": .string("spacer")]
        case let .provider(name): ["type": .string("provider"), "provider": .string(name)]
        case .workspaces: ["type": .string("workspaces")]
        case .activeApp: ["type": .string("activeApp")]
        case let .clock(format): ["type": .string("clock"), "format": .string(format)]
        case let .text(text): ["type": .string("text"), "text": .string(text)]
        case let .script(command, interval): ["type": .string("script"), "command": .string(command), "interval": interval.map(ConfigurationValue.number) ?? .null]
        }
    }
}

private let newWidgets: [WidgetContent] = [.text("New widget"), .clock(format: "EEE d MMM  HH:mm"), .activeApp, .workspaces]
    + DataSourceRegistry.builtIn.types.filter(\.isNative).map { .provider($0.name) }
    + [.script(command: "date +%H:%M", interval: 30), .spacer]

private struct WidgetsView: View {
    @Bindable var editor: ConfigurationEditor
    @State private var advanced = "{}"
    @State private var fontFamilies = NSFontManager.shared.availableFontFamilies

    private var store: BarStore { editor.store }
    private var widgets: [WidgetConfiguration] { store.configuration?.widgets ?? [] }

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 210, maxWidth: 280)
            Group {
                if let widget = widgets.first(where: { $0.id == editor.selectedID }) {
                    inspector(widget)
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
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $editor.selectedID) {
                ForEach(WidgetPosition.allCases, id: \.self) { position in
                    let section = widgets.filter { $0.position == position }
                    if !section.isEmpty {
                        Section(position.title) {
                            ForEach(section) { widget in
                                Label {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(widget.id).lineLimit(1)
                                        Text(widget.content.title).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: widget.content.symbol)
                                }
                                .opacity(widget.enabled ? 1 : 0.45)
                                .padding(.vertical, 2)
                                .tag(widget.id)
                            }
                            .onMove { offsets, destination in
                                var ids = section.map(\.id)
                                ids.move(fromOffsets: offsets, toOffset: destination)
                                var moved = ids.makeIterator()
                                editor.change(ConfigurationEdit(action: .reorder,
                                    ids: widgets.map { $0.position == position ? moved.next()! : $0.id }))
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 0) {
                Menu {
                    ForEach(Array(newWidgets.enumerated()), id: \.offset) { _, content in
                        Button(content.title, systemImage: content.symbol) {
                            let id = "widget-" + UUID().uuidString.prefix(8).lowercased()
                            editor.change(ConfigurationEdit(action: .add, properties: content.newWidgetProperties
                                .merging(["id": .string(id), "position": .string("left")]) { $1 }))
                            editor.selectedID = id
                        }
                    }
                } label: {
                    Image(systemName: "plus").frame(width: 28, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a widget")
                Divider().frame(height: 16)
                Button {
                    editor.change(ConfigurationEdit(action: .remove, id: editor.selectedID!))
                } label: {
                    Image(systemName: "minus").frame(width: 28, height: 24)
                }
                .help("Remove the selected widget")
                .disabled(editor.selectedID == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
    }

    private func inspector(_ widget: WidgetConfiguration) -> some View {
        let style = StyleFields(store: store, path: "widgets.\(widget.id).style", defaultsPath: "defaults", widgetID: widget.id,
                                values: editor.selectedStyle, set: { editor.set(["style": .object($0)]) },
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
                        Text(widget.id).font(.title3.weight(.semibold))
                        Text(widget.content.title + " widget").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: Binding(get: {
                        if case let .bool(value) = editor.selected["enabled"] { value } else { true }
                    }, set: { editor.set(["enabled": .bool($0)]) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Show this widget in the bar")
                }
            }
            Section("Content") {
                let origin = store.origins["widgets.\(widget.id).role"]
                OverrideRow(title: "Presentation role", source: origin.map { "From \(store.sourceText($0))" },
                            reset: origin.map(store.setsInMainFile) == true ? {
                    editor.change(ConfigurationEdit(action: .unset, id: widget.id, properties: ["role": .null]))
                } : nil) {
                    Picker("Presentation role", selection: Binding(get: { widget.role?.rawValue ?? "" }, set: {
                        if $0 != (widget.role?.rawValue ?? "") {
                            editor.set(["role": $0.isEmpty ? .null : .string($0)])
                        }
                    })) {
                        Text("None").tag("")
                        ForEach(PresentationRole.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                    }
                    .labelsHidden()
                }
                Picker("Position", selection: string("position", fallback: "left")) {
                    ForEach(WidgetPosition.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent("Icon") {
                    HStack {
                        TextField("Icon", text: string("icon"), prompt: Text("SF Symbol name"))
                            .labelsHidden()
                        Image(systemName: string("icon").wrappedValue)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                    }
                }
                if editor.selected["type"] == .string("text") { TextField("Text", text: string("text")) }
                if editor.selected["type"] == .string("clock") {
                    TextField("Date format", text: string("format", fallback: "EEE d MMM HH:mm"))
                }
                if widget.drawsTransitions {
                    Picker("Transition", selection: string("transition", fallback: WidgetTransition.none.rawValue)) {
                        ForEach(WidgetTransition.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                    .help("How the widget's text and symbols change")
                }
            }
            Section("Colors") {
                style.color("Text", "foreground")
                style.color("Background", "background")
                style.hoverBackground("Hover background")
                style.color("Border", "borderColor")
                style.color("Accent", "accent")
            }
            Section("Text and shape") {
                style.font(fontFamilies)
                style.weight()
                style.number("Font size", "fontSize", default: 12)
                style.number("Horizontal padding", "paddingHorizontal", default: 10)
                style.number("Corner radius", "cornerRadius", default: 14)
                style.number("Border width", "borderWidth", default: 1)
            }
            if widget.content == .workspaces {
                Section("Workspace presentation") {
                    WorkspacePresentationFields(store: store, path: "widgets.\(widget.id).workspace", defaultsPath: "workspaceDefaults",
                        values: (try? store.configuration?.workspaceDefaults.mergedProperties(editor.selected["workspace"])) ?? [:],
                        set: { editor.set(["workspace": .object($0)]) },
                        unset: { editor.change(ConfigurationEdit(action: .unset, id: widget.id, properties: ["workspace": .object($0)])) })
                }
            }
            Section {
                DisclosureGroup("Advanced properties") {
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
        .formStyle(.grouped)
    }

    private func string(_ key: String, fallback: String = "") -> Binding<String> {
        let value = if case let .string(value) = editor.selected[key] { value } else { fallback }
        return Binding(get: { value }, set: { if $0 != value { editor.set([key: .string($0)]) } })
    }
}

@MainActor
struct StyleFields {
    let store: BarStore
    let path: String
    var defaultsPath: String?
    var widgetID: String?
    let values: [String: ConfigurationValue]
    let set: ([String: ConfigurationValue]) -> Void
    /// Removes the given keys, set to `null`, from the main file.
    let unset: ([String: ConfigurationValue]) -> Void

    func color(_ title: String, _ key: String) -> some View {
        row(title, key) { origin in
            let color = try? values[key]?.decoded(HexColor.self)
            TokenPicker(token: origin?.token, color: color ?? HexColor(0)) { set([key: $0]) }
            ColorWells(color: color) { set([key: $0]) }
        }
    }

    /// Shows the hover background the bar draws and where it comes from, and sets it so it wins.
    func hoverBackground(_ title: String) -> some View {
        let drawn = HoverBackgroundRow.drawn(in: store.effectiveDocument, widget: widgetID)
        let origin = drawn.flatMap { store.origins[$0.path] }
        let own = drawn?.path.hasPrefix(path + ".") == true
        let color = try? drawn?.value.decoded(HexColor.self)
        return OverrideRow(title: title,
                           source: origin.map { own ? "From \(store.sourceText($0))" : "Default from \(store.sourceText($0))" },
                           reset: own && origin.map(store.setsInMainFile) == true ? { unset(HoverBackgroundRow.reset) } : nil) {
            TokenPicker(token: origin?.token, color: color ?? HexColor(0)) { set(HoverBackgroundRow.properties($0)) }
            ColorWells(color: color) { set(HoverBackgroundRow.properties($0)) }
        }
    }

    func number(_ title: String, _ key: String, default fallback: Double) -> some View {
        row(title, key) { _ in
            let value = if case let .number(number) = values[key] { number } else { fallback }
            let binding = Binding(get: { value }, set: { if $0 != value { set([key: .number($0)]) } })
            HStack(spacing: 6) {
                TextField(title, value: binding, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Text("pt").foregroundStyle(.secondary)
                Stepper(title, value: binding, in: 0...200).labelsHidden()
            }
        }
    }

    func font(_ families: [String]) -> some View {
        row("Font", "fontName") { _ in
            let selection = stringBinding("fontName", default: "system")
            let name = selection.wrappedValue
            Picker("Font", selection: selection) {
                Text("System").tag("system")
                Divider()
                ForEach(name == "system" || families.contains(name) ? families : [name] + families, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
        }
    }

    func choice(_ title: String, _ key: String, choices: [String], default fallback: String) -> some View {
        row(title, key) { _ in
            Picker(title, selection: stringBinding(key, default: fallback)) {
                ForEach(choices, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    func weight() -> some View {
        row("Weight", "fontWeight") { _ in
            Picker("Weight", selection: stringBinding("fontWeight", default: "medium")) {
                ForEach(fontWeights, id: \.name) { Text($0.name.capitalized).tag($0.name) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    func stringBinding(_ key: String, default fallback: String) -> Binding<String> {
        let value = if case let .string(value) = values[key] { value } else { fallback }
        return Binding(get: { value }, set: { if $0 != value { set([key: .string($0)]) } })
    }

    private func row<Control: View>(_ title: String, _ key: String, @ViewBuilder control: (ConfigurationOrigin?) -> Control) -> some View {
        let own = store.origins["\(path).\(key)"]
        let role = widgetID.flatMap { id in store.configuration?.widgets.first { $0.id == id }?.role }
        let inherited = role.flatMap { store.origins["roles.\($0.rawValue).\(key)"] }
            ?? defaultsPath.flatMap { store.origins["\($0).\(key)"] }
        return OverrideRow(title: title,
                           source: own.map { "From \(store.sourceText($0))" } ?? inherited.map { "Default from \(store.sourceText($0))" },
                           reset: own.map(store.setsInMainFile) == true ? { unset([key: .null]) } : nil) {
            control(own ?? inherited)
        }
    }
}

struct OverrideRow<Control: View>: View {
    let title: String
    let source: String?
    let reset: (() -> Void)?
    @ViewBuilder let control: Control

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) { control }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                HStack(spacing: 6) {
                    if let source { Text(source).foregroundStyle(.secondary) }
                    if let reset {
                        Button("Reset to default", action: reset)
                            .buttonStyle(.link)
                            .help("Remove this value from your configuration so the theme or default applies again")
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
        }
    }
}

struct TokenPicker: View {
    let token: String?
    let color: HexColor
    let set: (ConfigurationValue) -> Void

    var selection: Binding<String> {
        Binding(get: { token ?? "" }, set: {
            guard $0 != (token ?? "") else { return }
            set($0.isEmpty ? color.configurationValue : .string("@token.\($0)"))
        })
    }

    var body: some View {
        Picker("Color", selection: selection) {
            ForEach(themeTokens, id: \.name) { Text($0.title).tag($0.name) }
            if let token, !themeTokens.contains(where: { $0.name == token }) { Text(token).tag(token) }
            Divider()
            Text("Custom").tag("")
        }
        .labelsHidden()
        .fixedSize()
    }
}

struct ColorWells: View {
    let color: HexColor?
    let set: (ConfigurationValue) -> Void

    var body: some View {
        let shown = color ?? HexColor(0)
        Image(systemName: "sun.max").foregroundStyle(.secondary)
        ColorPicker("Light", selection: Binding(get: { HexColor(shown.light).color }, set: {
            set(HexColor(light: rgba($0), dark: color?.dark ?? rgba($0)).configurationValue)
        }))
        .labelsHidden()
        .help("Color in the light appearance")
        Image(systemName: "moon").foregroundStyle(.secondary)
        ColorPicker("Dark", selection: Binding(get: { HexColor(shown.dark).color }, set: {
            set(HexColor(light: color?.light ?? rgba($0), dark: rgba($0)).configurationValue)
        }))
        .labelsHidden()
        .help("Color in the dark appearance")
    }
}

private func rgba(_ color: Color) -> UInt32 {
    let color = NSColor(color).usingColorSpace(.sRGB)!
    let byte = { (component: CGFloat) in UInt32((min(max(component, 0), 1) * 255).rounded()) }
    return byte(color.redComponent) << 24 | byte(color.greenComponent) << 16 | byte(color.blueComponent) << 8 | byte(color.alphaComponent)
}

extension HexColor {
    var configurationValue: ConfigurationValue {
        light == dark ? .string(String(format: "#%08x", light))
            : .object(["light": .string(String(format: "#%08x", light)), "dark": .string(String(format: "#%08x", dark))])
    }
}

extension BarStore {
    func sourceText(_ origin: ConfigurationOrigin) -> String {
        let file = origin.file
        let packages = configurationURL.deletingLastPathComponent().appending(path: "packages").standardizedFileURL.path
        let text: String
        if file == configurationURL.standardizedFileURL.path {
            text = "your configuration"
        } else if let themes = bundledThemesDirectory?.standardizedFileURL.path, file.hasPrefix(themes + "/") {
            let id = file.dropFirst(themes.count + 1).prefix { $0 != "/" }
            text = id == "built-in" ? "the Built-in theme" : "the \(id.capitalized) theme"
        } else if file.hasPrefix(packages + "/") {
            text = "the \(file.dropFirst(packages.count + 1).prefix { $0 != "/" }) package"
        } else {
            text = URL(filePath: file).lastPathComponent
        }
        return origin.detail.isEmpty ? text : "\(text) \(origin.detail)"
    }

    func setsInMainFile(_ origin: ConfigurationOrigin) -> Bool {
        origin.file == configurationURL.standardizedFileURL.path && (origin.detail.isEmpty || origin.detail == "(widget override)")
    }
}
