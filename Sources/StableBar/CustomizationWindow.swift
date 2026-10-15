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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Customize StableBar"
            window.delegate = self
            window.minSize = NSSize(width: 800, height: 580)
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

private struct CustomizationView: View {
    let store: BarStore

    var body: some View {
        TabView {
            ConfigurationEditorView(store: store).tabItem { Label("Editor", systemImage: "slider.horizontal.3") }
            InspectorView(store: store).tabItem { Label("Inspector", systemImage: "stethoscope") }
            PackagesView(store: store).tabItem { Label("Packages", systemImage: "shippingbox") }
        }
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
        case let .provider(name):
            ["battery": "battery.100percent", "system": "cpu", "network": "network", "audio": "speaker.wave.2"][name]
                ?? "gauge.with.dots.needle.33percent"
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

private let newWidgets: [WidgetContent] = [
    .text("New widget"), .clock(format: "EEE d MMM  HH:mm"), .activeApp, .workspaces,
    .provider("battery"), .provider("system"), .provider("network"), .provider("audio"),
    .script(command: "date +%H:%M", interval: 30), .spacer
]

private struct ConfigurationEditorView: View {
    let store: BarStore
    @State private var editor: ConfigurationEditor
    @State private var advanced = "{}"
    @State private var showsBar = false
    @State private var showsProfiles = false
    @Environment(\.colorScheme) private var colorScheme

    init(store: BarStore) {
        self.store = store
        _editor = State(initialValue: ConfigurationEditor(store: store))
    }

    private var widgets: [WidgetConfiguration] { store.configuration?.widgets ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Edit", selection: $showsProfiles) {
                Text("Widgets").tag(false)
                Text("Profiles").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(12)
            Divider()
            if showsProfiles {
                ProfilesView(editor: editor)
            } else {
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
            }
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
                Button("Bar", systemImage: "rectangle.topthird.inset.filled") { showsBar = true }
                    .help("Bar size and default widget style")
                    .popover(isPresented: $showsBar) { barSettings }
                    .padding(.trailing, 6)
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
    }

    private func inspector(_ widget: WidgetConfiguration) -> some View {
        Form {
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
            }
            Section("Appearance") {
                colorPicker("Text color", value: editor.selectedStyle["foreground"], fallback: builtInStyle.foreground!) {
                    editor.set(["style": .object(["foreground": .string($0)])])
                }
                colorPicker("Background", value: editor.selectedStyle["background"], fallback: builtInStyle.background!) {
                    editor.set(["style": .object(["background": .string($0)])])
                }
                ForEach([("Font size", "fontSize", 12.0), ("Horizontal padding", "paddingHorizontal", 10), ("Corner radius", "cornerRadius", 14)],
                        id: \.1) { title, key, fallback in
                    numberField(title, value: editor.selectedStyle[key], fallback: fallback) {
                        editor.set(["style": .object([key: .number($0)])])
                    }
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

    private var barSettings: some View {
        var bar: [String: ConfigurationValue] = [:]
        var defaults: [String: ConfigurationValue] = [:]
        if case let .object(object) = store.effectiveDocument["bar"] { bar = object }
        if case let .object(object) = store.effectiveDocument["defaults"] { defaults = object }
        return Form {
            Section("Bar") {
                ForEach([("Height", "height", 40.0), ("Offset from top", "offset", 0), ("Side inset", "inset", 12), ("Spacing", "spacing", 8)],
                        id: \.1) { title, key, fallback in
                    numberField(title, value: bar[key], fallback: fallback) {
                        editor.change(ConfigurationEdit(action: .bar, properties: [key: .number($0)]))
                    }
                }
            }
            Section("All widgets") {
                colorPicker("Text color", value: defaults["foreground"], fallback: builtInStyle.foreground!) {
                    editor.change(ConfigurationEdit(action: .defaults, properties: ["foreground": .string($0)]))
                }
                colorPicker("Background", value: defaults["background"], fallback: builtInStyle.background!) {
                    editor.change(ConfigurationEdit(action: .defaults, properties: ["background": .string($0)]))
                }
                numberField("Font size", value: defaults["fontSize"], fallback: 12) {
                    editor.change(ConfigurationEdit(action: .defaults, properties: ["fontSize": .number($0)]))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
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

    private func string(_ key: String, fallback: String = "") -> Binding<String> {
        Binding(get: { if case let .string(value) = editor.selected[key] { value } else { fallback } },
                set: { editor.set([key: .string($0)]) })
    }

    private func numberField(_ title: String, value: ConfigurationValue?, fallback: Double, set: @escaping (Double) -> Void) -> some View {
        let displayed: Double
        if case let .number(number) = value { displayed = number }
        else { displayed = fallback }
        let binding = Binding(get: { displayed }, set: { if $0 != displayed { set($0) } })
        return LabeledContent(title) {
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

    private var builtInStyle: WidgetStyle { colorScheme == .dark ? .dark : .light }

    private func colorPicker(_ title: String, value: ConfigurationValue?, fallback: HexColor, set: @escaping (String) -> Void) -> some View {
        ColorPicker(title, selection: Binding(get: {
            ((try? value?.decoded(HexColor.self)) ?? fallback).color
        }, set: {
            let color = NSColor($0).usingColorSpace(.sRGB)!
            set(String(format: "#%02x%02x%02x%02x", Int((color.redComponent * 255).rounded()),
                       Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()),
                       Int((color.alphaComponent * 255).rounded())))
        }))
    }
}
