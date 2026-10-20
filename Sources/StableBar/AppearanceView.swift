import AppKit
import SwiftUI

struct AppearanceView: View {
    let editor: ConfigurationEditor
    @State private var gallery: ThemeGallery

    init(editor: ConfigurationEditor) {
        self.editor = editor
        _gallery = State(initialValue: ThemeGallery(store: editor.store))
    }
    @State private var fontFamilies = NSFontManager.shared.availableFontFamilies
    @State private var selectedRole = PresentationRole.time
    @State private var modeName = ""
    @State private var modeAlias = ""
    @State private var browsingThemes = false
    @State private var advanced = false

    private var store: BarStore { editor.store }

    var body: some View {
        let tokens = document("tokens")
        let appearanceSource = store.propertySources(path: "bar", key: "appearance", values: document("bar"))
        let appearance = try? appearanceSource.editingValue?.decoded(BarAppearance.self)
        let defaults = StyleFields(store: store, path: "defaults", values: document("defaults"),
                                   set: { editor.change(ConfigurationEdit(action: .defaults, properties: $0)) },
                                   unset: { unset(["defaults": .object($0)]) })
        let popups = StyleFields(store: store, path: "popupDefaults", defaultsPath: "defaults",
                                 values: document("defaults").merging(document("popupDefaults")) { $1 },
                                 set: { editor.change(ConfigurationEdit(action: .popupDefaults, properties: $0)) },
                                 unset: { unset(["popupDefaults": .object($0)]) })
        let bar = StyleFields(store: store, path: "bar", values: document("bar"),
                              set: { editor.change(ConfigurationEdit(action: .bar, properties: $0)) },
                              unset: { unset(["bar": .object($0)]) })
        let glass = StyleFields(store: store, path: "bar.glass",
                                values: (try? document("bar")["glass"]?.decoded([String: ConfigurationValue].self)) ?? [:],
                                set: { editor.change(ConfigurationEdit(action: .bar, properties: ["glass": .object($0)])) },
                                unset: { unset(["bar": .object(["glass": .object($0)])]) })
        let barStyle = StyleFields(store: store, path: "bar.style",
                                   values: (try? document("bar")["style"]?.decoded([String: ConfigurationValue].self)) ?? [:],
                                   set: { editor.change(ConfigurationEdit(action: .bar, properties: ["style": .object($0)])) },
                                   unset: { unset(["bar": .object(["style": .object($0)])]) })
        ScrollViewReader { scroll in
            Form {
                Section {
                    if let choice = gallery.choices.first(where: { $0.key == gallery.selectedKey }) {
                        ThemeCard(title: choice.title, look: gallery.previews[choice.key]?.configuration(for: gallery.previewAppearance),
                                  appearance: gallery.previewAppearance, isSelected: true, error: gallery.error(for: choice.key)) {
                            browsingThemes.toggle()
                        }
                    }
                    DisclosureGroup("Browse themes", isExpanded: $browsingThemes) {
                        LazyVStack(spacing: 12) {
                            ForEach(gallery.choices, id: \.key) { choice in
                                ThemeCard(title: choice.title, look: gallery.previews[choice.key]?.configuration(for: gallery.previewAppearance),
                                          appearance: gallery.previewAppearance,
                                          isSelected: gallery.selectedKey == choice.key, error: gallery.error(for: choice.key)) {
                                    gallery.select(choice)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        if gallery.storeUnavailable {
                            Text("The Store is unavailable. Your installed themes are ready to use.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else if !gallery.storeThemes.isEmpty {
                            Text("From the Store").font(.headline)
                            LazyVStack(spacing: 12) {
                                ForEach(gallery.storeThemes, id: \.versionKey) { entry in
                                    ThemeCard(title: entry.name, look: gallery.previews[entry.versionKey]?.configuration(for: gallery.previewAppearance),
                                              appearance: gallery.previewAppearance,
                                              progress: gallery.progress[entry.versionKey], error: gallery.error(for: entry.versionKey), isStore: true) {
                                        Task { await gallery.get(entry) }
                                    }
                                }
                            }
                        }
                    }
                    if !gallery.overrides.values.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(gallery.overrides.notice).font(.headline)
                            Text(gallery.overrides.values.map(\.title).joined(separator: ", "))
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Reset them") { editor.change(gallery.overrides.resetEdit) }
                                .accessibilityLabel("Reset your settings that override this theme")
                        }
                        .padding(.vertical, 8)
                    }
                    OverrideRow(title: "Appearance", source: store.propertySourceText(appearanceSource),
                                reset: appearanceSource.saved.map { source in { reset(source) } },
                                sourceDetails: PropertySourceView(store: store, title: "Appearance", property: appearanceSource)) {
                        Picker("Appearance", selection: Binding(get: { appearance }, set: {
                            if $0 != appearance {
                                editor.change(ConfigurationEdit(action: .bar, properties: ["appearance": $0.map { .string($0.rawValue) } ?? .null]))
                            }
                        })) {
                            Text("Automatic").tag(BarAppearance?.none)
                            Text("Light").tag(BarAppearance?.some(.light))
                            Text("Dark").tag(BarAppearance?.some(.dark))
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                } header: {
                    Text("Theme")
                } footer: {
                    Text("Automatic follows the system’s light or dark mode. Choose a theme to apply and save it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .id(SettingsSearchResult.theme.id)
                Section {
                    glass.toggle("Use Liquid Glass", "enabled", default: false)
                    if glass.values["enabled"] == .bool(true) {
                        glass.percentage("See-through", "transparency", default: 0.3)
                        glass.toggle("Widgets", "widgets", default: true)
                        glass.toggle("Popups", "popups", default: true)
                        glass.toggle("Bar", "bar", default: true)
                    }
                } header: {
                    Text("Liquid Glass")
                } footer: {
                    Text("Experimental. Draws the widgets, popups and bar your theme gives a background as native macOS glass, tinted with the theme’s colors. See-through sets how much glass shows through them; the higher it is, the more your wallpaper can make text hard to read. Needs macOS 26 or later.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .id(SettingsSearchResult.glass.id)
                Section {
                    ForEach(themeTokens, id: \.name) { token in
                        if tokens[token.name] != nil {
                            let property = store.propertySources(path: "tokens", key: token.name, values: tokens)
                            let color = try? property.editingValue?.decoded(HexColor.self)
                            OverrideRow(title: token.title, source: store.propertySourceText(property),
                                        reset: property.saved.map { source in { reset(source) } },
                                        sourceDetails: PropertySourceView(store: store, title: token.title, property: property)) {
                                ColorWells(color: color) { editor.change(ConfigurationEdit(action: .tokens, properties: [token.name: $0])) }
                            }
                        }
                    }
                } header: {
                    Text("Theme colors")
                } footer: {
                    Text("Every widget, popup and package that uses a theme color follows your changes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .id(SettingsSearchResult.colors.id)
                Section {
                    defaults.color("Text", "foreground")
                    defaults.color("Background", "background")
                    defaults.hoverBackground("Hover background")
                    defaults.color("Border", "borderColor")
                    defaults.color("Shadow", "shadowColor")
                    defaults.color("Accent", "accent")
                    defaults.color("Accent text", "accentText")
                    defaults.font(fontFamilies)
                    defaults.weight()
                    defaults.number("Font size", "fontSize", default: 12)
                    defaults.number("Horizontal padding", "paddingHorizontal", default: 10)
                    defaults.number("Vertical padding", "paddingVertical", default: 6)
                    defaults.number("Corner radius", "cornerRadius", default: 14)
                } header: { Text("Default widget appearance") }
                footer: { Text("Widgets follow these defaults unless a role, widget setting, profile or live output overrides them.") }
                .id(SettingsSearchResult.defaults.id)
                Section("Popups") {
                    popups.color("Background", "background")
                    popups.color("Border", "borderColor")
                    popups.color("Shadow", "shadowColor")
                    popups.weight()
                }
                .id(SettingsSearchResult.popups.id)
                Section("Bar") {
                    barStyle.color("Background", "background")
                    barStyle.color("Border", "borderColor")
                    barStyle.number("Border width", "borderWidth", default: 0)
                    barStyle.choice("Border edges", "borderEdges", choices: BarBorderEdges.allCases.map(\.rawValue),
                                    default: BarBorderEdges.bottom.rawValue)
                    barStyle.number("Corner radius", "cornerRadius", default: 0)
                    bar.number("Height", "height", default: 40)
                    bar.number("Side inset", "inset", default: 12)
                    bar.number("Spacing", "spacing", default: 8)
                }
                .id(SettingsSearchResult.barStyle.id)
                Section {
                    DisclosureGroup("Advanced appearance", isExpanded: $advanced) {
                        Section("Presentation roles") {
                            Picker("Role", selection: $selectedRole) {
                                ForEach(PresentationRole.allCases, id: \.rawValue) { Text($0.rawValue.capitalized).tag($0) }
                            }
                            let role = roleFields(selectedRole)
                            role.font(fontFamilies)
                            role.weight()
                            role.number("Font size", "fontSize", default: 12)
                            role.color("Text", "foreground")
                            role.color("Background", "background")
                            role.color("Border", "borderColor")
                            role.color("Accent", "accent")
                            role.number("Border width", "borderWidth", default: 0)
                            role.number("Corner radius", "cornerRadius", default: 0)
                            role.number("Horizontal padding", "paddingHorizontal", default: 0)
                            role.number("Vertical padding", "paddingVertical", default: 0)
                            Text("Only widgets and layout blocks explicitly assigned this role use it. A bar widget’s role does not style its popup.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .id(SettingsSearchResult.roles.id)
                        Section("Workspace defaults") {
                            WorkspacePresentationFields(store: store, path: "workspaceDefaults", values: document("workspaceDefaults"),
                                set: { editor.change(ConfigurationEdit(action: .workspaceDefaults, properties: $0)) },
                                unset: { unset(["workspaceDefaults": .object($0)]) })
                        }
                        .id(SettingsSearchResult.workspaceStyle.id)
                        Section("AeroSpace mode aliases") {
                            ForEach((store.configuration?.modeAliases ?? [:]).keys.sorted(), id: \.self) { name in
                                let origin = store.origins["modeAliases.\(name)"]
                                OverrideRow(title: name, source: origin.map { "From \(store.sourceText($0))" },
                                            reset: origin.map(store.setsInMainFile) == true ? { unset(["modeAliases": .object([name: .null])]) } : nil) {
                                    Text("mode.\(store.configuration?.modeAliases[name] ?? "")")
                                    Button("Remove") { editor.change(ConfigurationEdit(action: .modeAliases, properties: [name: .null])) }
                                }
                            }
                            HStack {
                                TextField("Local mode, e.g. tailing", text: $modeName)
                                TextField("Alias, e.g. command", text: $modeAlias)
                                Button("Set mapping") {
                                    editor.change(ConfigurationEdit(action: .modeAliases, properties: [modeName: .string(modeAlias)]))
                                    if editor.error == nil { modeName = ""; modeAlias = "" }
                                }.disabled(modeName.isEmpty || modeAlias.isEmpty)
                            }
                            Text("Your configuration maps mode names; the selected theme controls their colors and borders.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .id(SettingsSearchResult.modeAliases.id)
                    }
                }
            }
            .formStyle(.grouped)
            .task { await gallery.refresh() }
            .task(id: browsingThemes) { if browsingThemes { await gallery.loadStore() } }
            .task(id: editor.searchTarget) {
                if let target = editor.searchTarget {
                    if [SettingsSearchResult.roles.id, SettingsSearchResult.workspaceStyle.id, SettingsSearchResult.modeAliases.id].contains(target) { advanced = true }
                    if target == SettingsSearchResult.theme.id { browsingThemes = true }
                    await Task.yield()
                    if Task.isCancelled { return }
                    scroll.scrollTo(target, anchor: .top)
                    editor.searchTarget = nil
                }
            }
            .onChange(of: store.effectiveDocument) { _, _ in gallery.configurationChanged() }
            .onChange(of: store.configurationError) { _, _ in gallery.contextChanged() }
            .onChange(of: store.context) { _, _ in gallery.contextChanged() }
        }
    }

    private func document(_ key: String) -> [String: ConfigurationValue] {
        (try? store.effectiveDocument[key]?.decoded([String: ConfigurationValue].self)) ?? [:]
    }

    private func roleFields(_ role: PresentationRole) -> StyleFields {
        let style = (store.configuration?.roleStyle(role).inheriting(store.configuration?.defaults ?? WidgetStyle()) ?? WidgetStyle()).configurationValue
        return StyleFields(store: store, path: "roles.\(role.rawValue)", defaultsPath: "defaults",
            values: (try? style.decoded([String: ConfigurationValue].self)) ?? [:],
            set: { editor.change(ConfigurationEdit(action: .roles, properties: [role.rawValue: .object($0)])) },
            unset: { unset(["roles": .object([role.rawValue: .object($0)])]) })
    }

    private func unset(_ properties: [String: ConfigurationValue]) {
        editor.change(ConfigurationEdit(action: .unset, properties: properties))
    }

    private func reset(_ source: PropertyValueSource) {
        do { try store.removePropertySource(source) }
        catch { store.customizationHistory.error = errorMessage(error) }
    }

}
