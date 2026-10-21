import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum BarItem {
    case bar, everyWidget, widget
}

enum BarTab: CaseIterable {
    case size, look, placement

    var title: String {
        switch self {
        case .size: "Size"
        case .look: "Look"
        case .placement: "Placement"
        }
    }
}

enum WidgetTab: CaseIterable {
    case content, style, behavior

    var title: String {
        switch self {
        case .content: "Content"
        case .style: "Style"
        case .behavior: "Behavior"
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

struct BarInspector: View {
    @Bindable var editor: ConfigurationEditor
    let screen: ScreenKind
    let kinds: [ScreenKind]
    let names: [String: String]
    let source: (WidgetConfiguration) -> PackageSource
    let useSharedBar: (ScreenSetup) -> Void
    @Binding var scrollPositions: [String: String]
    @State private var fontFamilies: [String] = []
    @State private var customClockFormat = false
    @State private var json = ""
    @State private var jsonError: String?
    @State private var editingJSON = false
    @State private var webPage = ""
    @State private var editingWebPage = false
    @State private var clickError: String?
    @State private var explainingSetup = false
    @State private var barOnScreen = false
    @State private var resetting: WidgetConfiguration?
    private var store: BarStore { editor.store }

    private static let styleKeys = ["foreground", "background", "accent", "accentText", "shadowColor", "fontName", "fontWeight", "fontSize",
                                    "paddingHorizontal", "paddingVertical", "paddingLeading", "paddingTrailing", "paddingTop", "paddingBottom",
                                    "cornerRadius", "borderWidth", "borderColor"]

    var body: some View {
        let widget = editor.barItem == .widget ? store.configuration?.onScreen(screen).widgets.first { $0.id == editor.selectedID } : nil
        let key = widget.map { "widget/\($0.id)/\(editor.widgetTab)" } ?? (editor.barItem == .everyWidget ? "everyWidget" : "bar/\(editor.barTab)")
        VStack(spacing: 0) {
            Group {
                if let widget {
                    widgetHeader(widget)
                } else if editor.barItem == .everyWidget {
                    header(Text("Aa").font(.system(size: 17, weight: .medium)), title: "Every widget") {
                        Text("Widgets use this look unless you style them yourself")
                    }
                } else {
                    header(Image(systemName: "menubar.rectangle").font(.system(size: 18)), title: "Bar") { Text("The strip itself") }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 14)
            if widget != nil {
                SettingsSegments(selection: $editor.widgetTab, options: WidgetTab.allCases.map { ($0, $0.title) })
                    .padding(.horizontal, 20).padding(.bottom, 8)
            } else if editor.barItem != .everyWidget {
                SettingsSegments(selection: $editor.barTab, options: BarTab.allCases.map { ($0, $0.title) })
                    .padding(.horizontal, 20).padding(.bottom, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 0).id("top")
                    if let widget {
                        widgetPanel(widget)
                    } else if editor.barItem == .everyWidget {
                        stylePanel(defaultsStyle, name: "Widget", widget: nil)
                        SettingsCallout(systemImage: "sparkle",
                                        text: Text("Widgets with their own values keep them. Use the revert arrow beside a value to follow this shared look again."))
                            .padding(.top, 12)
                    } else {
                        barPanel
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
                .padding(.top, 2)
                .padding(.bottom, 24)
            }
            .scrollPosition(id: Binding(get: { scrollPositions[key] }, set: { scrollPositions[key] = $0 }), anchor: .top)
            .id(key)
        }
        .task { fontFamilies = NSFontManager.shared.availableFontFamilies }
        .onChange(of: editor.selectedID) {
            customClockFormat = false
            clickError = nil
        }
        .sheet(isPresented: $editingJSON) { jsonSheet }
        .sheet(isPresented: $editingWebPage) { webPageSheet }
        .confirmationDialog("Reset \(resetting.map { names[$0.id] ?? $0.id } ?? "")?",
                            isPresented: Binding(get: { resetting != nil }, set: { if !$0 { resetting = nil } }), presenting: resetting) { widget in
            Button("Reset") { editor.reset(widget) }
        } message: { widget in
            Text(editor.definedInMainFile(widget)
                 ? "Its style, role, rules, transition, tooltip, click action, format and workspace options go back to the defaults. What it shows and where it sits stay."
                 : "Everything you changed goes back to how its package or imported file defines it. Where it sits and the screens it shows on stay.")
        }
    }


    private func header<Icon: View, Subtitle: View>(_ icon: Icon, title: String, @ViewBuilder subtitle: () -> Subtitle) -> some View {
        HStack(spacing: 10) {
            icon
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) { subtitle() }.font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func widgetHeader(_ widget: WidgetConfiguration) -> some View {
        HStack(spacing: 10) {
            header(Image(systemName: widget.content.symbol).font(.system(size: 18)), title: names[widget.id] ?? widget.id) {
                Text(typeName(widget))
                PackageSourceBadge(source: source(widget))
            }
            Toggle("Show on bar", isOn: Binding(get: { widget.enabled }, set: { editor.set(["enabled": .bool($0)], for: widget.id) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help("Show this widget in the bar")
            moreMenu(widget)
        }
    }

    private func moreMenu(_ widget: WidgetConfiguration) -> some View {
        Menu {
            Button("Edit as JSON…") {
                var properties = editor.properties(for: widget.id)
                properties["id"] = nil
                json = (try? String(decoding: configurationData(properties), as: UTF8.self)) ?? "{}"
                jsonError = nil
                editingJSON = true
            }
            Button("Copy widget ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(widget.id, forType: .string)
            }
            Divider()
            Section("Advanced") {
                Picker("Presentation role", selection: Binding(get: { widget.role?.rawValue ?? "" }, set: {
                    if $0 != (widget.role?.rawValue ?? "") { editor.set(["role": $0.isEmpty ? .null : .string($0)], for: widget.id) }
                })) {
                    Text("None").tag("")
                    ForEach(PresentationRole.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0.rawValue) }
                }
                if widget.drawsTransitions {
                    Picker("Transition", selection: string("transition", for: widget, fallback: WidgetTransition.none.rawValue)) {
                        ForEach(WidgetTransition.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                }
                Button("Troubleshoot…") { editor.troubleshoot(widget.id) }
            }
            Divider()
            Button("Reset to defaults…") { resetting = widget }
            Button("Remove from bar", role: .destructive) { editor.change(ConfigurationEdit(action: .remove, id: widget.id)) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }


    @ViewBuilder private var barPanel: some View {
        let target = barOnScreen ? screen : nil
        let values = target.map(barValues) ?? document("bar")
        let bar = StyleFields(store: store, path: target.map { "screens.\($0.rawValue).bar" } ?? "bar", defaultsPath: barOnScreen ? "bar" : nil,
                              values: values, set: { setBar($0, on: target) }, unset: { unsetBar($0, on: target) })
        let barStyle = StyleFields(store: store, path: bar.path + ".style", defaultsPath: barOnScreen ? "bar.style" : nil,
                                   values: (try? values["style"]?.decoded([String: ConfigurationValue].self)) ?? [:],
                                   set: { setBar(["style": .object($0)], on: target) },
                                   unset: { unsetBar(["style": .object($0)], on: target) })
        if kinds.count > 1 || store.configuration?.screenLooks[screen.rawValue] != nil {
            SettingsSegments(selection: $barOnScreen, options: [(false, "Every screen"), (true, screen.screenTitle)], stretches: false)
                .fixedSize()
                .padding(.bottom, 12)
        }
        switch editor.barTab {
        case .size:
            SettingsGroup("Size") {
                bar.number("Height", "height", default: 40, in: 16...100, slider: true)
                barStyle.number("Corner radius", "cornerRadius", default: 0, in: 0...40, slider: true)
                bar.number("Side inset", "inset", default: 12, in: 0...100)
                bar.number("Space between widgets", "spacing", default: 8, in: 0...50)
            }
            SettingsCallout(systemImage: "arrow.left.and.right",
                            text: Text("Drag a label or a **↔** handle to change a value; hold Shift for steps of 10. The preview and your real bar follow as you drag."))
                .padding(.top, 12)
        case .look:
            SettingsGroup("Background") {
                barStyle.color("Fill", "background")
            }
            SettingsGroup("Border") {
                barStyle.number("Width", "borderWidth", default: 0, in: 0...6, step: 0.5)
                barStyle.color("Color", "borderColor")
                barStyle.row("Edges", "borderEdges") { _ in
                    SettingsSegments(selection: barStyle.stringBinding("borderEdges", default: BarBorderEdges.bottom.rawValue),
                                     options: BarBorderEdges.allCases.map { ($0.rawValue, $0.rawValue.capitalized) }, stretches: false)
                }
            }
        case .placement:
            SettingsGroup("Position") {
                bar.number("Offset from top", "offset", default: 0, in: 0...200)
                bar.number("Margin", "margin", default: 0, in: 0...40, hint: "Floats the bar in from the screen edges")
            }
            SettingsGroup("Size on each screen") {
                scale("Laptop", key: "builtIn")
                scale("Monitors", key: "external")
            }
            if let setup = store.screenSetup {
                let ownsBar = store.configurationURL != store.sharedConfigurationURL
                let screens = kinds.map(\.name).joined(separator: " + ")
                SettingsGroup("These screens") {
                    SettingRow(title: ownsBar ? "\(screens) \(setup.kinds.count == 1 ? "has its" : "have their") own bar"
                                              : "\(screens) \(setup.kinds.count == 1 ? "uses" : "use") the shared bar",
                               hint: "Each set of connected screens can have its own widgets, theme and size.") {
                        Button(ownsBar ? "Manage…" : "Give them their own bar…") { explainingSetup = true }
                            .controlSize(.small)
                            .popover(isPresented: $explainingSetup, arrowEdge: .bottom) {
                                ScreenSetupPopover(editor: editor, setup: setup, title: screens) {
                                    explainingSetup = false
                                    useSharedBar($0)
                                }
                            }
                    }
                }
            }
        }
    }

    private func scale(_ title: String, key: String) -> some View {
        let values = store.configuration?.bar.displayScale.mapValues(ConfigurationValue.number) ?? [:]
        let property = store.propertySources(path: "bar.displayScale", key: key, values: values)
        let value = if case let .number(value) = property.editingValue { value * 100 } else { 100.0 }
        let binding = Binding(get: { value }, set: { percent in
            if percent != value {
                editor.change(ConfigurationEdit(action: .bar, properties: ["displayScale": .object([key: .number(percent / 100)])]))
            }
        })
        return NumberDraft(value: binding) { binding in
            SettingRow(title: title, property: property, source: store.propertySourceText(property),
                       reset: property.saved.map { source in { reset(source) } },
                       scrub: Scrub(value: binding, range: 25...300, step: 5)) {
                NumberField(title: title, value: binding, range: 25...300, step: 5, unit: "%", slider: true)
            }
        }
    }


    private var defaultsStyle: StyleFields {
        StyleFields(store: store, path: "defaults", values: document("defaults"),
                    set: { editor.change(ConfigurationEdit(action: .defaults, properties: $0)) },
                    unset: { unset(["defaults": .object($0)]) })
    }

    @ViewBuilder private func stylePanel(_ style: StyleFields, name: String, widget: WidgetConfiguration?) -> some View {
        SettingsGroup("Colors") {
            style.color("Text", "foreground")
            style.color("Background", "background")
            style.hoverBackground("Hover background")
            style.color("Accent", "accent")
            if widget == nil {
                style.color("Accent text", "accentText")
                style.color("Shadow", "shadowColor")
            }
        }
        SettingsGroup("Text") {
            style.font(fontFamilies)
            style.weight()
            style.number("Size", "fontSize", default: 12, in: 6...40, slider: true)
        }
        SettingsGroup("Padding and corners") {
            BoxModel(style: style, name: name)
            NumberDraft(value: style.numberBinding("borderWidth", default: 0)) { width in
                style.row("Border", "borderWidth", scrub: Scrub(value: width, range: 0...6, step: 0.5)) { _ in
                    NumberField(title: "Border width", value: width, range: 0...6, step: 0.5)
                    style.colorButton("Border color", "borderColor")
                }
            }
        }
        if let widget, widget.content == .workspaces {
            SettingsGroup("Workspaces") {
                WorkspacePresentationFields(store: store, path: "widgets.\(widget.id).workspace", defaultsPath: "workspaceDefaults", widgetID: widget.id,
                    values: (try? store.configuration?.workspaceDefaults.mergedProperties(editor.properties(for: widget.id)["workspace"])) ?? [:],
                    set: { editor.set(["workspace": .object($0)], for: widget.id) },
                    unset: { editor.change(ConfigurationEdit(action: .unset, id: widget.id, properties: ["workspace": .object($0)])) })
            }
        }
        if widget != nil, Self.styleKeys.contains(where: { style.property($0).saved != nil }) || style.property("hoverBackground").saved != nil {
            Button("Go back to the Every widget look") {
                style.unset(Dictionary(uniqueKeysWithValues: Self.styleKeys.map { ($0, ConfigurationValue.null) }).merging(HoverBackgroundRow.reset) { $1 })
            }
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
        }
    }


    @ViewBuilder private func widgetPanel(_ widget: WidgetConfiguration) -> some View {
        if !screen.shows(widget.display, among: NSScreen.screens.map(BarDisplay.init), activeID: store.activeDisplayID) {
            SettingsCallout(systemImage: "eye.slash", text: Text("Not shown on \(screen.phrase).")) {
                Button("Show here") { editor.setWidget(widget, shown: true, on: screen) }.controlSize(.small)
            }
            .padding(.top, 12)
        }
        let status = store.widgetStatus(for: widget)
        if status.needsAttention {
            SettingsCallout(systemImage: status.symbol, text: Text("**\(status.title).** \(status.detail)")) {
                Button("Troubleshoot…") { editor.troubleshoot(widget.id) }.controlSize(.small)
            }
            .padding(.top, 12)
        }
        switch editor.widgetTab {
        case .content: contentPanel(widget)
        case .style:
            stylePanel(StyleFields(store: store, path: "widgets.\(widget.id).style", defaultsPath: "defaults", widgetID: widget.id,
                                   values: editor.style(for: widget.id), set: { editor.set(["style": .object($0)], for: widget.id) },
                                   unset: { editor.change(ConfigurationEdit(action: .unset, id: widget.id, properties: ["style": .object($0)])) }),
                       name: names[widget.id] ?? widget.id, widget: widget)
        case .behavior: behaviorPanel(widget)
        }
    }

    @ViewBuilder private func contentPanel(_ widget: WidgetConfiguration) -> some View {
        if let name = widget.providerName, let type = store.configuration?.providers[name]?.type,
           type == "battery" || type == "audio" {
            let source = type == "battery" ? "percent" : "volume"
            let current = WidgetMetricDisplay.current(editor.properties(for: widget.id)["layout"], source: source)
            SettingsGroup("Display") {
                SettingRow(title: "Show") {
                    Picker("Show", selection: Binding(get: { current }, set: { choice in
                        if let layout = choice.layout(for: source) { editor.set(["layout": layout], for: widget.id) }
                    })) {
                        ForEach(WidgetMetricDisplay.choices(for: source).filter { $0 != .custom || current == .custom }, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .labelsHidden().frame(width: 180)
                }
            }
        }
        if let packageID = store.widgetPackageIDs[widget.id] {
            SettingsCallout(systemImage: source(widget).symbol,
                            text: Text("Settings from the **\(store.widgetPackageNames[widget.id] ?? packageID)** package, shared by its widgets.")) {
                Button("Open package") { editor.showPackage(packageID) }.controlSize(.small)
            }
            .padding(.top, 12)
            SettingsGroup("Package settings") {
                WidgetPackageSettings(store: store, packageID: packageID) { editor.showPackage(packageID) }.groupRow()
            }
            iconGroup(widget)
        } else {
            switch widget.content {
            case let .clock(format):
                SettingsGroup("Format") { clockFormats(widget, format: format).groupRow() }
                iconGroup(widget)
            case .text:
                SettingsGroup("Text") {
                    SettingRow(title: "Text") { TextField("Text", text: string("text", for: widget)).labelsHidden().frame(width: 220) }
                }
                iconGroup(widget)
            case .workspaces:
                SettingsGroup("Workspaces") {
                    SettingRow(title: "Show each window") {
                        Toggle("Show each window", isOn: Binding(get: { widget.workspace?.windows == true }, set: {
                            editor.set(["workspace": .object(["windows": .bool($0)])], for: widget.id)
                        }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                    if widget.workspace?.windows == true {
                        let length = Binding(get: { Double(widget.workspace?.titleLength ?? 0) }, set: {
                            editor.set(["workspace": .object(["titleLength": .number($0)])], for: widget.id)
                        })
                        NumberDraft(value: length) { length in
                            SettingRow(title: "Title length", scrub: Scrub(value: length, range: 0...200), hint: "0 shows only app icons") {
                                NumberField(title: "Title length", value: length, range: 0...200, unit: "chars")
                            }
                        }
                    }
                }
                iconGroup(widget)
            case let .appMenu(expandOnHover):
                SettingsGroup("App menus") {
                    SettingRow(title: "Expand on hover", hint: "Show only the app’s name until the pointer is over the widget") {
                        Toggle("Expand on hover", isOn: Binding(get: { expandOnHover }, set: {
                            editor.set(["expandOnHover": .bool($0)], for: widget.id)
                        }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                }
                iconGroup(widget)
            default:
                if widget.content.drawsOwnView {
                    SettingsCallout(systemImage: "sparkle",
                                    text: Text("\(names[widget.id] ?? widget.id) has nothing to set here. Its look is in **Style** and its clicks in **Behavior**."))
                        .padding(.top, 12)
                }
                iconGroup(widget)
            }
        }
    }

    private func iconGroup(_ widget: WidgetConfiguration) -> some View {
        let icon = string("icon", for: widget)
        return SettingsGroup("Icon") {
            SettingRow(title: "Symbol", hint: "Any SF Symbol name") {
                Image(systemName: icon.wrappedValue).foregroundStyle(.secondary).frame(width: 20)
                TextField("Symbol", text: icon, prompt: Text("SF Symbol name")).labelsHidden().frame(width: 160)
            }
        }
    }

    private func clockFormats(_ widget: WidgetConfiguration, format: String) -> some View {
        let custom = customClockFormat || !WidgetClockFormat.common.contains { $0.value == format }
        return VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 5, alignment: .leading)], alignment: .leading, spacing: 5) {
                ForEach(WidgetClockFormat.common, id: \.value) { choice in
                    chip(choice.sample, selected: !custom && format == choice.value) {
                        customClockFormat = false
                        editor.set(["format": .string(choice.value)], for: widget.id)
                    }
                    .help(choice.title)
                }
                chip("Custom…", selected: custom) { customClockFormat = true }
            }
            if custom {
                HStack(spacing: 8) {
                    TextField("Date pattern", text: string("format", for: widget, fallback: format)).labelsHidden().frame(width: 200)
                    Text("Date pattern, such as EEE HH:mm").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(SettingsPalette.control), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? .clear : SettingsPalette.groupBorder))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func behaviorPanel(_ widget: WidgetConfiguration) -> some View {
        SettingsGroup("Clicks") {
            clickRow(widget)
            if let popup = widget.popup {
                SettingRow(title: "Open its popup on hover") {
                    Toggle("Open its popup on hover", isOn: Binding(get: { popup.openOnHover }, set: {
                        editor.set(["popup": .object(["openOnHover": .bool($0)])], for: widget.id)
                    }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
            }
            SettingRow(title: "Tooltip") {
                TextField("Tooltip", text: Binding(get: { widget.tooltip ?? "" }, set: {
                    editor.set(["tooltip": $0.isEmpty ? .null : .string($0)], for: widget.id)
                }), prompt: Text("The widget’s own"))
                .labelsHidden()
                .frame(width: 200)
            }
        }
        SettingsGroup("Screens") {
            let displays = NSScreen.screens.map(BarDisplay.init)
            if case let .ids(ids) = widget.display {
                SettingRow(title: "Show on", hint: "Specific screens: \(ids.map(String.init).joined(separator: ", ")). Change them with Edit as JSON.") {}
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SettingRow(title: "Show on", hint: "Same as the eye in the list. Screens of the same kind show the same widgets.") {}
                    HStack(spacing: 8) {
                        ForEach(ScreenKind.allCases, id: \.self) { kind in
                            let shown = kind.shows(widget.display, among: displays, activeID: store.activeDisplayID)
                            Button { editor.setWidget(widget, shown: !shown, on: kind) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: kind.symbol).font(.system(size: 15))
                                    Text(kind.name).font(.system(size: 12.5))
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                                        .opacity(shown ? 1 : 0)
                                }
                                .padding(.horizontal, 11)
                                .frame(height: 32)
                                .background(shown ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(SettingsPalette.control),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(shown ? Color.accentColor : SettingsPalette.groupBorder,
                                                                                        lineWidth: shown ? 1.5 : 1))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(shown ? .isSelected : [])
                        }
                    }
                    .padding(.leading, 17)
                }
                .groupRow()
            }
            SettingRow(title: "Rule") {
                Picker("Rule", selection: Binding(get: { WidgetScreenChoice(widget.display) }, set: {
                    if $0 != WidgetScreenChoice(widget.display), let properties = $0.properties { editor.set(properties, for: widget.id) }
                })) {
                    ForEach(WidgetScreenChoice.allCases.filter { $0 != .specific || WidgetScreenChoice(widget.display) == .specific }, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
        }
        SettingsGroup("Position") {
            SettingRow(title: "Group on the bar", hint: "Or drag it in the list") {
                SettingsSegments(selection: Binding(get: { widget.position }, set: { if $0 != widget.position { move(widget.id, to: $0) } }),
                                 options: WidgetPlacement.destinations.map { ($0, $0.title) }, stretches: false)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder private func clickRow(_ widget: WidgetConfiguration) -> some View {
        let output = store.scripts[widget.id]?.output
        switch WidgetClickChoice.control(for: widget, output: output) {
        case .hidden: EmptyView()
        case .explanation(let explanation):
            SettingRow(title: "When clicked", hint: explanation) {}
        case .choices:
            let current = WidgetClickChoice.current(for: widget, output: output)
            SettingRow(title: "When clicked", hint: clickError ?? widget.open) {
                if let open = widget.open {
                    Button(current == .application ? "Choose another app…" : "Edit web page…") {
                        if current == .application { chooseApplication(widget) } else { webPage = open; editingWebPage = true }
                    }
                    .controlSize(.small)
                }
                Picker("When clicked", selection: Binding(get: { current }, set: { choice in
                    guard choice != current else { return }
                    switch choice {
                    case .nothing: setClick(.nothing, widget: widget)
                    case .application: chooseApplication(widget)
                    case .webPage:
                        webPage = current == .webPage ? widget.open ?? "" : "https://"
                        editingWebPage = true
                    case .advanced: break
                    }
                })) {
                    ForEach(WidgetClickChoice.allCases.filter { $0 != .advanced }, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 200)
            }
        }
    }


    private var jsonSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(names[editor.selectedID ?? ""] ?? "Widget") as JSON").font(.headline)
            TextEditor(text: $json)
                .font(.system(size: 11.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(width: 480, height: 300)
                .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SettingsPalette.groupBorder))
            if let jsonError { Text(jsonError).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack(spacing: 8) {
                Text("Removing a property clears it. Includes and templates stay as they are.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { editingJSON = false }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    do {
                        editor.replaceProperties(try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(json.utf8)))
                        jsonError = editor.error
                    } catch { jsonError = errorMessage(error) }
                    if jsonError == nil { editingJSON = false }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private var webPageSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open a web page").font(.headline)
            TextField("Web address", text: $webPage).frame(width: 360)
            if let clickError { Text(clickError).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { editingWebPage = false }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    if let widget = store.configuration?.widgets.first(where: { $0.id == editor.selectedID }) {
                        setClick(.webPage, widget: widget, value: webPage)
                    }
                    if clickError == nil { editingWebPage = false }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
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

    private func move(_ id: String, to position: WidgetPosition) {
        do { try WidgetSetup(store: store).move(id, to: position, on: screen) }
        catch { editor.error = errorMessage(error) }
    }

    private func typeName(_ widget: WidgetConfiguration) -> String {
        store.widgetPackageNames[widget.id] ?? WidgetDisplayName.title(for: widget.content, providers: store.configuration?.providers ?? [:])
    }

    private func string(_ key: String, for widget: WidgetConfiguration, fallback: String = "") -> Binding<String> {
        let value = if case let .string(value) = editor.properties(for: widget.id)[key] { value } else { fallback }
        return Binding(get: { value }, set: { if $0 != value { editor.set([key: .string($0)], for: widget.id) } })
    }

    private func document(_ key: String) -> [String: ConfigurationValue] {
        (try? store.effectiveDocument[key]?.decoded([String: ConfigurationValue].self)) ?? [:]
    }

    private func barValues(_ kind: ScreenKind) -> [String: ConfigurationValue] {
        let screens = (try? store.effectiveDocument["screens"]?.decoded([String: [String: ConfigurationValue]].self)) ?? [:]
        let own = screens[kind.rawValue]?["bar"] ?? .object([:])
        return (try? own.overriding(.object(document("bar"))).decoded([String: ConfigurationValue].self)) ?? [:]
    }

    private func setBar(_ properties: [String: ConfigurationValue], on kind: ScreenKind?) {
        if let kind {
            editor.change(ConfigurationEdit(action: .screens, properties: [kind.rawValue: .object(["bar": .object(properties)])]))
        } else {
            editor.change(ConfigurationEdit(action: .bar, properties: properties))
        }
    }

    private func unsetBar(_ properties: [String: ConfigurationValue], on kind: ScreenKind?) {
        unset(kind.map { ["screens": .object([$0.rawValue: .object(["bar": .object(properties)])])] } ?? ["bar": .object(properties)])
    }

    private func unset(_ properties: [String: ConfigurationValue]) {
        editor.change(ConfigurationEdit(action: .unset, properties: properties))
    }

    private func reset(_ source: PropertyValueSource) {
        do { try store.removePropertySource(source) }
        catch { store.customizationHistory.error = errorMessage(error) }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) { content }
                .labeledContentStyle(GroupRowStyle())
                .padding(.top, -1)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.groupBorder))
        }
        .padding(.top, 22)
        .id(title)
    }
}

private struct GroupRowStyle: LabeledContentStyle {
    func makeBody(configuration: LabeledContentStyleConfiguration) -> some View {
        HStack(spacing: 10) {
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
            configuration.content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 46)
        .overlay(alignment: .top) { SettingsPalette.separator.frame(height: 1) }
    }
}

extension View {
    func groupRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .overlay(alignment: .top) { SettingsPalette.separator.frame(height: 1) }
    }
}

private struct BoxModel: View {
    let style: StyleFields
    let name: String

    var body: some View {
        let horizontal = style.numberBinding("paddingHorizontal", default: 10)
        let vertical = style.numberBinding("paddingVertical", default: 6)
        let corner = style.numberBinding("cornerRadius", default: 14)
        VStack(spacing: 6) {
            Text(name)
                .font(.system(size: 12))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(SettingsPalette.groupBorder))
                .padding(.horizontal, horizontal.wrappedValue * 1.5)
                .padding(.vertical, vertical.wrappedValue * 1.5)
                .background(Color.accentColor.opacity(0.2), in: RoundedRectangle(cornerRadius: corner.wrappedValue))
                .overlay(RoundedRectangle(cornerRadius: corner.wrappedValue).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .leading) { field("Horizontal padding", "paddingHorizontal", horizontal, symbol: "arrow.left.and.right") }
                .overlay(alignment: .trailing) { field("Horizontal padding", "paddingHorizontal", horizontal, symbol: "arrow.left.and.right") }
                .overlay(alignment: .top) { field("Vertical padding", "paddingVertical", vertical, symbol: "arrow.up.and.down") }
                .overlay(alignment: .bottom) { field("Vertical padding", "paddingVertical", vertical, symbol: "arrow.up.and.down") }
                .overlay(alignment: .topLeading) { field("Corner radius", "cornerRadius", corner, symbol: "square.dashed") }
                .frame(height: 150)
            HStack(spacing: 12) {
                Label("side padding", systemImage: "arrow.left.and.right")
                Label("top and bottom", systemImage: "arrow.up.and.down")
                Label("corners", systemImage: "square.dashed")
                Text("Drag a symbol, or use ↑ ↓ in a field").foregroundStyle(.tertiary)
            }
            .labelStyle(LegendLabelStyle())
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .groupRow()
    }

    private func field(_ title: String, _ key: String, _ value: Binding<Double>, symbol: String) -> some View {
        let property = style.property(key)
        return HStack(spacing: 4) {
            RevertSettingButton(title: title, property: property, reset: property.saved.map { source in { style.reset(source) } })
            NumberDraft(value: value) { NumberField(title: title, value: $0, range: 0...30, unit: "", symbol: symbol) }
        }
        .padding(4)
        .help(title)
    }
}

private struct LegendLabelStyle: LabelStyle {
    func makeBody(configuration: LabelStyleConfiguration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .semibold))
            configuration.title
        }
    }
}

extension ConfigurationEditor {
    func setWidget(_ widget: WidgetConfiguration, shown: Bool, on kind: ScreenKind) {
        let displays = NSScreen.screens.map(BarDisplay.init)
        let kinds = ScreenKind.allCases.filter { $0 == kind ? shown : $0.shows(widget.display, among: displays, activeID: store.activeDisplayID) }
        var properties: [String: ConfigurationValue] = ["display": .array(kinds.map { .string($0.selection) })]
        if shown && !widget.enabled { properties["enabled"] = .bool(true) }
        set(properties, for: widget.id)
    }
}
