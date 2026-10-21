import AppKit
import SwiftUI

@MainActor
final class CustomizationWindow: NSObject, NSWindowDelegate {
    private weak var store: BarStore?
    private var window: NSWindow?
    private var editor: ConfigurationEditor?

    init(store: BarStore? = nil) { self.store = store }

    func show(store: BarStore, widgetID: String? = nil, section: CustomizationSection? = nil) {
        self.store = store
        store.setInspectorOpen(true)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "StableBar Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.delegate = self
            window.minSize = NSSize(width: 900, height: 620)
            window.isReleasedWhenClosed = false
            let editor = ConfigurationEditor(store: store, endEditing: { [weak window] in window?.endEditing(for: nil) })
            self.editor = editor
            store.onEndCustomizationEditing = { [weak editor] in editor?.finishEditing() }
            store.onCustomizeProfile = { [weak editor] name in editor?.showProfile(name) }
            window.contentView = NSHostingView(rootView: SettingsView(store: store, editor: editor))
            window.center()
            self.window = window
        }
        if let widgetID { editor?.showWidget(widgetID) }
        if let section { editor?.section = section }
        NSApp.activate(ignoringOtherApps: true)
        window!.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        editor?.endProfileEditing()
        editor?.finishEditing()
        store?.flushCustomization()
        store?.showScreenSetup(ScreenSetup(NSScreen.screens.map(BarDisplay.init)))
        store?.customizationHistory.clearNotice()
        store?.setInspectorOpen(false)
    }
}

enum CustomizationSection: String, CaseIterable, Identifiable {
    case general = "General", widgets = "Bar", appearance = "Theme", profiles = "Profiles", packages = "Packages", diagnostics = "Status"

    var id: Self { self }

    func bannerError(customization: String?, configuration: String?) -> String? {
        if [.appearance, .widgets, .profiles, .general].contains(self) { return customization ?? configuration }
        return customization == configuration ? nil : customization
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .widgets: "menubar.rectangle"
        case .appearance: "paintpalette"
        case .profiles: "switch.2"
        case .packages: "shippingbox"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

struct SettingsView: View {
    let store: BarStore
    @Bindable var editor: ConfigurationEditor
    @State private var optionHeld = false
    @State private var flagsMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader(editor: editor)
            Divider()
            if editor.editingProfile != nil {
                ProfileEditingBanner(editor: editor).padding(12)
            }
            ZStack(alignment: .topTrailing) {
                Group {
                    switch editor.section ?? .general {
                    case .general: GeneralSettingsView(editor: editor)
                    case .widgets: WidgetsView(editor: editor)
                    case .appearance: AppearanceView(editor: editor)
                    case .profiles: ProfilesView(editor: editor)
                    case .packages: PackagesView(store: store, selectedPackageID: editor.selectedPackageID, searchTarget: $editor.searchTarget)
                    case .diagnostics: DiagnosticsView(editor: editor)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                if !editor.search.isEmpty {
                    SettingsSearchResults(editor: editor).padding(.trailing, 12).padding(.top, 4)
                }
            }
            if let error = (editor.section ?? .general).bannerError(customization: editor.error, configuration: store.configurationError) {
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
            Divider()
            footer
        }
        .background(SettingsPalette.background)
        .environment(store)
        .environment(\.showsValueSources, editor.showsValueSources || optionHeld)
        .onAppear {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                optionHeld = event.modifierFlags.contains(.option)
                return event
            }
        }
        .onDisappear {
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            optionHeld = false
        }
        .onChange(of: editor.section) {
            editor.finishEditing()
            if editor.section != .packages { editor.selectedPackageID = nil }
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
            .controlSize(.small)
            .fixedSize()
            Text(editor.error != nil ? "Change not saved" : editor.history.hasPendingChanges ? "Saving…" : "All changes saved")
                .foregroundStyle(.secondary)
            Spacer()
            Button(editor.showsValueSources ? "Hide where values come from" : "Show where values come from") {
                editor.showsValueSources.toggle()
            }
            .buttonStyle(.link)
            Text("or hold ⌥").foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(SettingsPalette.sidebar)
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

private struct SettingsHeader: View {
    @Bindable var editor: ConfigurationEditor
    @Environment(BarStore.self) private var store
    @FocusState private var searching: Bool

    var body: some View {
        ZStack {
            HStack(spacing: 2) {
                ForEach(CustomizationSection.allCases) { section in
                    SettingsTab(section: section, selected: (editor.section ?? .general) == section,
                                badge: section == .diagnostics ? attentionCount : 0) {
                        editor.section = section
                    }
                }
            }
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                    TextField("Search settings", text: $editor.search)
                        .textFieldStyle(.plain)
                        .focused($searching)
                        .onSubmit {
                            if let result = SettingsSearchResult.allCases.first(where: { $0.matches(editor.search) }) {
                                editor.showSetting(result)
                            }
                        }
                        .onExitCommand { editor.search = "" }
                        .accessibilityLabel("Search settings")
                }
                .padding(.horizontal, 8)
                .frame(width: 170, height: 26)
                .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(searching ? Color.accentColor : SettingsPalette.groupBorder,
                                                                         lineWidth: searching ? 2 : 1))
                Button("") { searching = true }.keyboardShortcut("f").hidden().frame(width: 0)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(SettingsPalette.sidebar)
    }

    private var attentionCount: Int {
        (store.configuration?.widgets ?? []).filter { store.widgetStatus(for: $0).needsAttention }.count
    }
}

private struct SettingsTab: View {
    let section: CustomizationSection
    let selected: Bool
    let badge: Int
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: 2) {
                Image(systemName: section.symbol)
                    .font(.system(size: 16))
                    .frame(width: 24, height: 20)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text("\(badge)")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .frame(minWidth: 14, minHeight: 14)
                                .background(SettingsPalette.warning, in: Capsule())
                                .offset(x: 8, y: -4)
                        }
                    }
                Text(section.rawValue).font(.system(size: 11))
            }
            .foregroundStyle(selected ? Color.accentColor : hovering ? .primary : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(minWidth: 56)
            .background(selected ? SettingsPalette.control : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .accessibilityLabel(section.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SettingsSearchResults: View {
    let editor: ConfigurationEditor

    var body: some View {
        let results = SettingsSearchResult.allCases.filter { $0.matches(editor.search) }
        VStack(alignment: .leading, spacing: 0) {
            if results.isEmpty {
                Text("No matching settings").font(.callout).foregroundStyle(.secondary).padding(8)
            }
            ForEach(Array(results.prefix(8).enumerated()), id: \.element) { index, result in
                SearchResultRow(result: result, first: index == 0) { editor.showSetting(result) }
            }
        }
        .padding(5)
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.groupBorder))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
    }
}

private struct SearchResultRow: View {
    let result: SettingsSearchResult
    let first: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        let highlighted = hovering || (first && !hovering)
        Button(action: select) {
            VStack(alignment: .leading, spacing: 1) {
                Text(result.title)
                Text(result.path).font(.caption).foregroundStyle(highlighted ? .white.opacity(0.8) : .secondary)
            }
            .foregroundStyle(highlighted ? .white : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
        row(title, key) { _ in colorButton(title, key) }
    }

    func colorButton(_ title: String, _ key: String) -> some View {
        let property = property(key)
        return FillButton(title: title, value: origin(key).flatMap(\.token).map { .string("@token.\($0)") } ?? property.editingFill,
                   tokens: store.themeTokenColors, allowsGradient: key == "background", allowsNone: key != "foreground") {
            set([key: $0])
        }
    }

    /// Shows the hover background the bar draws and where it comes from, and sets it so it wins.
    func hoverBackground(_ title: String) -> some View {
        let drawn = HoverBackgroundRow.drawn(in: store.effectiveDocument, widget: widgetID)
        var values = values
        values["hoverBackground"] = drawn?.value
        let property = store.propertySources(path: path, key: "hoverBackground", defaultsPath: defaultsPath,
                                             widgetID: widgetID, values: values, hover: true)
        let origin = property.saved?.origin ?? drawn.flatMap { store.origins[$0.path] }
        return SettingRow(title: title, property: property, source: store.propertySourceText(property),
                          reset: property.saved.map { source in { resetHoverBackground(source) } }) {
            FillButton(title: title, value: origin?.token.map { .string("@token.\($0)") } ?? property.editingFill,
                       tokens: store.themeTokenColors, allowsGradient: true, allowsNone: true) {
                set(HoverBackgroundRow.properties($0))
            }
        }
    }

    func resetHoverBackground(_ source: PropertyValueSource) {
        if source.value == .null, source.path.last != "hoverBackground" {
            reset(source)
        } else {
            unset(HoverBackgroundRow.reset)
        }
    }

    func number(_ title: String, _ key: String, default fallback: Double, in range: ClosedRange<Double> = 0...200,
                step: Double = 1, unit: String = "pt", slider: Bool = false, hint: String? = nil) -> some View {
        NumberDraft(value: numberBinding(key, default: fallback)) { binding in
            row(title, key, scrub: Scrub(value: binding, range: range, step: step), hint: hint) { _ in
                NumberField(title: title, value: binding, range: range, step: step, unit: unit, slider: slider)
            }
        }
    }

    func font(_ families: [String]) -> some View {
        row("Font", "fontName") { _ in
            let selection = stringBinding("fontName", default: "system")
            let name = selection.wrappedValue
            choiceMenu("Font", selection: selection, selectedTitle: name == "system" ? "System" : name) {
                Text("System").tag("system")
                Divider()
                ForEach(name == "system" || families.contains(name) ? families : [name] + families, id: \.self) { Text($0).tag($0) }
            }
        }
    }

    func toggle(_ title: String, _ key: String, default fallback: Bool, hint: String? = nil) -> some View {
        row(title, key, hint: hint) { _ in
            let isOn = if case let .bool(value) = property(key).editingValue { value } else { fallback }
            Toggle(title, isOn: Binding(get: { isOn }, set: { if $0 != isOn { set([key: .bool($0)]) } }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    func percentage(_ title: String, _ key: String, default fallback: Double) -> some View {
        row(title, key) { _ in
            NumberDraft(value: numberBinding(key, default: fallback)) { value in
                HStack(spacing: 8) {
                    Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 * 100).rounded() / 100 }),
                           in: 0...1, step: 0.05)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 140)
                    Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
    }

    func choice(_ title: String, _ key: String, choices: [String], default fallback: String) -> some View {
        row(title, key) { _ in
            let selection = stringBinding(key, default: fallback)
            choiceMenu(title, selection: selection, selectedTitle: selection.wrappedValue.capitalized) {
                ForEach(choices, id: \.self) { Text($0.capitalized).tag($0) }
            }
        }
    }

    func weight() -> some View {
        row("Weight", "fontWeight") { _ in
            let selection = stringBinding("fontWeight", default: "medium")
            choiceMenu("Weight", selection: selection, selectedTitle: selection.wrappedValue.capitalized) {
                ForEach(fontWeights, id: \.name) { Text($0.name.capitalized).tag($0.name) }
            }
        }
    }

    private func choiceMenu<Choices: View>(_ title: String, selection: Binding<String>, selectedTitle: String,
                                          @ViewBuilder choices: () -> Choices) -> some View {
        Menu {
            Picker(title, selection: selection, content: choices).pickerStyle(.inline)
        } label: {
            HStack(spacing: 7) {
                Text(selectedTitle).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7)).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(width: 200, height: 28)
            .background(SettingsPalette.control, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SettingsPalette.groupBorder))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(title)
        .accessibilityValue(selectedTitle)
    }

    func stringBinding(_ key: String, default fallback: String) -> Binding<String> {
        let value = if case let .string(value) = property(key).editingValue { value } else { fallback }
        return Binding(get: { value }, set: { if $0 != value { set([key: .string($0)]) } })
    }

    func numberBinding(_ key: String, default fallback: Double) -> Binding<Double> {
        let value = if case let .number(number) = property(key).editingValue { number } else { fallback }
        return Binding(get: { value }, set: { if $0 != value { set([key: .number($0)]) } })
    }

    func row<Control: View>(_ title: String, _ key: String, scrub: Scrub? = nil, hint: String? = nil,
                            @ViewBuilder control: (ConfigurationOrigin?) -> Control) -> some View {
        let property = property(key)
        return SettingRow(title: title, property: property, source: store.propertySourceText(property),
                          reset: property.saved.map { saved in { reset(saved) } }, scrub: scrub, hint: hint) {
            control(origin(key))
        }
    }

    private func origin(_ key: String) -> ConfigurationOrigin? {
        let role = widgetID.flatMap { id in store.configuration?.widgets.first { $0.id == id }?.role }
        return property(key).saved?.origin ?? store.origins["\(path).\(key)"]
            ?? role.flatMap { store.origins["roles.\($0.rawValue).\(key)"] } ?? defaultsPath.flatMap { store.origins["\($0).\(key)"] }
    }

    func property(_ key: String) -> PropertySources {
        store.propertySources(path: path, key: key, defaultsPath: defaultsPath, widgetID: widgetID, values: values)
    }

    func reset(_ source: PropertyValueSource) {
        do { try store.removePropertySource(source) }
        catch { store.customizationHistory.error = errorMessage(error) }
    }
}

struct OverrideRow<Control: View>: View {
    let title: String
    let source: String?
    let reset: (() -> Void)?
    var sourceDetails: PropertySourceView? = nil
    @ViewBuilder let control: Control

    var body: some View {
        SettingRow(title: title, property: sourceDetails?.property, source: source, reset: reset) { control }
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
