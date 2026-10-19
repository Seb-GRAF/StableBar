import AppKit
import SwiftUI

@MainActor
final class CustomizationWindow: NSObject, NSWindowDelegate {
    private weak var store: BarStore?
    private var window: NSWindow?
    private var editor: ConfigurationEditor?

    init(store: BarStore? = nil) { self.store = store }

    func show(store: BarStore, widgetID: String? = nil) {
        self.store = store
        store.setInspectorOpen(true)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Customize StableBar"
            window.delegate = self
            window.minSize = NSSize(width: 900, height: 600)
            window.isReleasedWhenClosed = false
            let editor = ConfigurationEditor(store: store, endEditing: { [weak window] in window?.endEditing(for: nil) })
            self.editor = editor
            store.onEndCustomizationEditing = { [weak editor] in editor?.finishEditing() }
            window.contentView = NSHostingView(rootView: CustomizationView(store: store, editor: editor))
            window.center()
            self.window = window
        }
        if let widgetID { editor?.showWidget(widgetID) }
        NSApp.activate(ignoringOtherApps: true)
        window!.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        editor?.finishEditing()
        store?.flushCustomization()
        store?.customizationHistory.clearNotice()
        store?.setInspectorOpen(false)
    }
}

enum CustomizationSection: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", widgets = "Widgets", profiles = "Profiles", packages = "Packages", diagnostics = "Diagnostics", about = "About"

    var id: Self { self }

    func bannerError(customization: String?, configuration: String?) -> String? {
        if [.appearance, .widgets, .profiles].contains(self) { return customization ?? configuration }
        return customization == configuration ? nil : customization
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .widgets: "square.grid.2x2"
        case .profiles: "person.crop.square"
        case .packages: "shippingbox"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }
}

private struct CustomizationView: View {
    let store: BarStore
    @Bindable var editor: ConfigurationEditor
    private var section: CustomizationSection? { editor.section }

    var body: some View {
        HStack(spacing: 0) {
            List(CustomizationSection.allCases, selection: $editor.section) { section in
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
                case .about: AboutView(update: store.update)
                }
                if let error = (section ?? .appearance).bannerError(customization: editor.error, configuration: store.configurationError) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.1))
                }
                if let notice = editor.history.notice {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                if !store.sessionEdits.isEmpty { commandLineNotice }
                if [.appearance, .widgets, .profiles, .packages].contains(section ?? .appearance) {
                    Divider()
                    footer
                }
            }
        }
        .onChange(of: store.configuration?.widgets.map(\.id)) { editor.keepSelection() }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            ControlGroup {
                Button("Undo", systemImage: "arrow.uturn.backward", action: editor.undo)
                    .keyboardShortcut("z").disabled(!editor.history.canUndo).help("Undo")
                Button("Redo", systemImage: "arrow.uturn.forward", action: editor.redo)
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!editor.history.canRedo).help("Redo")
            }
            .labelStyle(.iconOnly)
            .fixedSize()
            Text(editor.history.hasPendingChanges ? "Saving changes…" : "All changes saved")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var commandLineNotice: some View {
        HStack(spacing: 10) {
            Text("Command-line changes are temporary. Save or discard them separately.")
                .font(.callout)
            Spacer()
            Button("Discard", action: editor.discardCommandLineChanges)
                .accessibilityLabel("Discard command-line changes")
            Button("Save", action: editor.saveCommandLineChanges)
                .accessibilityLabel("Save command-line changes")
                .keyboardShortcut("s")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
    var menuTitle: String {
        switch self {
        case .notchLeft: "Left of Notch"
        case .notchRight: "Right of Notch"
        default: title
        }
    }

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

    func number(_ title: String, _ key: String, default fallback: Double, in range: ClosedRange<Double> = 0...200) -> some View {
        row(title, key) { _ in
            let binding = numberBinding(key, default: fallback)
            HStack(spacing: 6) {
                TextField(title, value: binding, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 52)
                Text("pt").foregroundStyle(.secondary)
                Stepper(title, value: binding, in: range).labelsHidden()
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

    func toggle(_ title: String, _ key: String, default fallback: Bool) -> some View {
        row(title, key) { _ in
            let isOn = if case let .bool(value) = values[key] { value } else { fallback }
            Toggle(title, isOn: Binding(get: { isOn }, set: { if $0 != isOn { set([key: .bool($0)]) } }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    func percentage(_ title: String, _ key: String, default fallback: Double) -> some View {
        row(title, key) { _ in
            let value = if case let .number(number) = values[key] { number } else { fallback }
            HStack(spacing: 8) {
                Slider(value: Binding(get: { value }, set: {
                    let rounded = ($0 * 100).rounded() / 100
                    if rounded != value { set([key: .number(rounded)]) }
                }), in: 0...1, step: 0.05)
                .labelsHidden()
                .frame(width: 160)
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
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

    func numberBinding(_ key: String, default fallback: Double) -> Binding<Double> {
        let value = if case let .number(number) = values[key] { number } else { fallback }
        return Binding(get: { value }, set: { if $0 != value { set([key: .number($0)]) } })
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
        } else if let themes = themesDirectory?.standardizedFileURL.path, file.hasPrefix(themes + "/") {
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
