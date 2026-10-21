import AppKit
import SwiftUI

struct AppearanceView: View {
    @Bindable var editor: ConfigurationEditor
    @State private var gallery: ThemeGallery

    init(editor: ConfigurationEditor) {
        self.editor = editor
        _gallery = State(initialValue: ThemeGallery(store: editor.store))
    }
    @State private var filter = ThemeFilter.all
    @State private var advanced: AdvancedSheet?
    @State private var screen: ScreenKind?
    @State private var fontFamilies: [String] = []
    @State private var savingTheme = false
    @State private var themeName = ""

    private var store: BarStore { editor.store }
    private var kinds: [ScreenKind] { ScreenKind.allCases.filter { store.screenSetup?.kinds.contains($0) == true } }
    private var document: [String: ConfigurationValue] { screen.flatMap { store.screenDocuments[$0.rawValue] } ?? store.effectiveDocument }
    private var screenTheme: WidgetPackageSelection? {
        let screens = (try? store.effectiveDocument["screens"]?.decoded([String: [String: ConfigurationValue]].self)) ?? [:]
        return screen.flatMap { try? screens[$0.rawValue]?["theme"]?.decoded(WidgetPackageSelection.self) }
    }

    var body: some View {
        let appearance = gallery.previewAppearance
        VStack(spacing: 0) {
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            if kinds.count > 1 {
                                SettingsSegments(selection: $screen, options: [(nil, "Every screen")] + kinds.map { ($0, $0.screenTitle) },
                                                 stretches: false)
                                    .fixedSize()
                            }
                            Spacer()
                            if editor.editingProfile == nil, !store.screenSetupsWithOwnBars.isEmpty {
                                SettingsSegments(selection: $editor.themeChangesEveryBar,
                                                 options: [(true, "All setups"),
                                                           (false, store.configurationURL == store.sharedConfigurationURL ? "Shared bar only" : "This setup only")],
                                                 stretches: false)
                                    .fixedSize()
                            }
                            ProfilePicker(editor: editor)
                        }
                        .padding(.top, 16)
                        if let configuration = store.configuration {
                            ThemePreviewStrip(look: screen.map(configuration.onScreen) ?? configuration, appearance: appearance)
                                .padding(.top, 10).padding(.bottom, 4)
                        }
                        themes(appearance)
                        if screen == nil { overrides }
                        colors(appearance)
                        HStack(alignment: .top, spacing: 20) {
                            widgets
                            VStack(spacing: 22) {
                                popups
                                bar
                            }
                        }
                        .padding(.top, 22)
                        glass.padding(.top, 22)
                        ThemeGroup(title: "Advanced") {
                            SettingRow(title: "Presentation roles", hint: "Shared styles for widgets with a role, such as time or status") {
                                Button("Edit…") { advanced = .roles }.controlSize(.small)
                            }
                            SettingRow(title: "Workspace look", hint: "Focused, visible and empty workspaces") {
                                Button("Edit…") { advanced = .workspaceStyle }.controlSize(.small)
                            }
                            SettingRow(title: "AeroSpace mode names", hint: "Match your mode names to the ones themes style") {
                                Button("Edit…") { advanced = .modeAliases }.controlSize(.small)
                            }
                        }
                        .padding(.top, 22)
                        .id(SettingsSearchResult.roles.id)
                    }
                    .frame(maxWidth: 780)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .task {
                    fontFamilies = NSFontManager.shared.availableFontFamilies
                    await gallery.refresh()
                    await gallery.loadStore()
                }
                .task(id: editor.searchTarget) {
                    if let target = editor.searchTarget {
                        advanced = AdvancedSheet(rawValue: target)
                        await Task.yield()
                        if Task.isCancelled { return }
                        scroll.scrollTo(advanced == nil ? target : SettingsSearchResult.roles.id, anchor: .top)
                        editor.searchTarget = nil
                    }
                }
            }
        }
        .sheet(item: $advanced) { ThemeAdvancedSheet(editor: editor, sheet: $0, screen: screen) }
        .onChange(of: kinds) { if let screen, !kinds.contains(screen) { self.screen = nil } }
        .onChange(of: store.effectiveDocument) { _, _ in gallery.configurationChanged() }
        .onChange(of: store.configurationError) { _, _ in gallery.contextChanged() }
        .onChange(of: store.context) { _, _ in gallery.contextChanged() }
    }

    private func themes(_ appearance: BarAppearance) -> some View {
        let bar = editor.fields(["bar"], on: screen, values: editor.values("bar", on: screen))
        let source = store.propertySources(path: bar.path, key: "appearance", defaultsPath: bar.defaultsPath, values: bar.values)
        let saved = try? source.editingValue?.decoded(BarAppearance.self)
        let shown = shownThemes
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Theme").font(.system(size: 13, weight: .semibold))
                if let screen, screenTheme != nil {
                    Button("Use the theme of every screen") {
                        editor.unset(["screens": .object([screen.rawValue: .object(["theme": .null])])])
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                }
                if screen == nil, editor.editingProfile == nil, let choice = gallery.choices.first(where: { $0.key == gallery.selectedKey }) {
                    Button("Save as Theme…") {
                        themeName = choice.isBundled || choice.manifest.repository != nil ? "My \(choice.manifest.name)" : choice.manifest.name
                        savingTheme = true
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .sheet(isPresented: $savingTheme) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Save as Theme").font(.headline)
                            TextField("Name", text: $themeName).frame(width: 360)
                            HStack {
                                Spacer()
                                Button("Cancel") { savingTheme = false }.keyboardShortcut(.cancelAction)
                                Button("Save") {
                                    Task { await gallery.save(choice, as: themeName, everyBar: editor.themeChangesEveryBar) }
                                    savingTheme = false
                                }
                                .keyboardShortcut(.defaultAction)
                                .disabled(themeName.isEmpty)
                            }
                        }
                        .padding(24)
                    }
                    if !choice.isBundled {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([choice.directory]) }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                }
                Spacer()
                RevertSettingButton(title: "Appearance", property: source, reset: source.saved.map { saved in { reset(saved) } })
                SettingsSegments(selection: Binding(get: { saved }, set: {
                    if $0 != saved { bar.set(["appearance": $0.map { .string($0.rawValue) } ?? .null]) }
                }), options: [(nil, "Automatic"), (.light, "Light"), (.dark, "Dark")], stretches: false)
                .fixedSize()
            }
            .padding(.top, 24)
            .padding(.horizontal, 2)
            .id(SettingsSearchResult.theme.id)
            SettingsSegments(selection: $filter, options: [(.all, "All"), (.included, "Included"), (.store, "Store")],
                             stretches: false)
                .fixedSize()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(shown) { card($0, appearance: appearance) }
            }
            ForEach(shown) { item in
                if let error = gallery.error(for: item.id) {
                    Label("\(item.title): \(error)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if gallery.storeUnavailable && filter != .included {
                Text("The Store is unavailable. Your installed themes are ready to use.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var shownThemes: [ThemeItem] {
        let included = gallery.choices.filter(\.isBundled).map(ThemeItem.installed)
        let others = (gallery.choices.filter { !$0.isBundled }.map(ThemeItem.installed) + gallery.storeThemes.map(ThemeItem.store))
            .sorted { $0.title < $1.title }
        switch filter {
        case .all: return included + others
        case .included: return included
        case .store: return others.filter { item in
            if case let .installed(choice) = item { return gallery.source(of: choice) == .listed }
            return true
        }
        }
    }

    private func card(_ item: ThemeItem, appearance: BarAppearance) -> ThemeCard {
        let look = gallery.previews[item.id]?.configuration(for: appearance)
        switch item {
        case let .installed(choice):
            let selected = screenTheme.map { $0.enabled ? $0.key : "built-in" } ?? gallery.selectedKey
            return ThemeCard(title: choice.title, look: look, appearance: appearance, isSelected: selected == choice.key,
                             progress: gallery.progress[item.id], error: gallery.error(for: item.id),
                             source: gallery.source(of: choice)) { gallery.select(choice, on: screen, everyBar: editor.themeChangesEveryBar) }
        case let .store(entry):
            return ThemeCard(title: entry.name, look: look, appearance: appearance, progress: gallery.progress[item.id],
                             error: gallery.error(for: item.id), isStore: true) {
                Task { await gallery.get(entry, on: screen, everyBar: editor.themeChangesEveryBar) }
            }
        }
    }

    @ViewBuilder private var overrides: some View {
        if !gallery.overrides.values.isEmpty, let theme = gallery.choices.first(where: { $0.key == gallery.selectedKey }) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(gallery.overrides.notice(theme: theme.title)).fontWeight(.semibold)
                    Text(gallery.overrides.summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Reset them") { editor.change(gallery.overrides.resetEdit, everyBar: editor.themeChangesEveryBar) }
                    .controlSize(.small)
                    .accessibilityLabel("Reset your settings that override this theme")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(SettingsPalette.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.warning.opacity(0.3)))
            .padding(.top, 12)
        }
    }

    private func colors(_ appearance: BarAppearance) -> some View {
        let tokens = editor.fields(["tokens"], on: screen, values: editor.values("tokens", on: screen))
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Theme colors").font(.system(size: 13, weight: .semibold))
                Text("Widgets, popups and packages that use a color follow it.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(store.themeTokenColors(in: document)) { token in
                    let property = store.propertySources(path: tokens.path, key: token.name, defaultsPath: tokens.defaultsPath, values: tokens.values)
                    let color = (try? property.editingValue?.decoded(HexColor.self)) ?? token.color
                    TokenColorButton(title: token.title, color: color, dark: appearance.colorScheme == .dark,
                                     property: property, reset: property.saved.map { source in { reset(source) } }) {
                        tokens.set([token.name: $0])
                    }
                }
            }
        }
        .padding(.top, 24)
        .id(SettingsSearchResult.colors.id)
    }

    private var glass: some View {
        let glass = editor.fields(["bar", "glass"], on: screen,
                                  values: (try? editor.values("bar", on: screen)["glass"]?.decoded([String: ConfigurationValue].self)) ?? [:])
        return VStack(alignment: .leading, spacing: 6) {
            ThemeGroup(title: "Liquid Glass") {
                glass.toggle("Use Liquid Glass", "enabled", default: false)
                if glass.values["enabled"] == .bool(true) {
                    glass.percentage("See-through", "transparency", default: 0.3)
                    glass.toggle("Widgets", "widgets", default: true)
                    glass.toggle("Popups", "popups", default: true)
                    glass.toggle("Bar", "bar", default: true)
                }
            }
            Text("Experimental. Needs macOS 26 or later.").font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity)
        .id(SettingsSearchResult.glass.id)
    }

    private var widgets: some View {
        let defaults = editor.fields(["defaults"], on: screen, values: editor.values("defaults", on: screen))
        return ThemeGroup(title: "Widgets") {
            defaults.color("Text", "foreground")
            defaults.color("Background", "background")
            defaults.color("Border", "borderColor")
            defaults.color("Shadow", "shadowColor")
            defaults.color("Accent", "accent")
            defaults.color("Accent text", "accentText")
            defaults.font(fontFamilies)
            defaults.weight()
            defaults.number("Text size", "fontSize", default: 12, in: 6...40)
            defaults.number("Horizontal padding", "paddingHorizontal", default: 10, in: 0...40)
            defaults.number("Vertical padding", "paddingVertical", default: 6, in: 0...40)
            defaults.number("Corner radius", "cornerRadius", default: 14, in: 0...40)
        }
        .frame(maxWidth: .infinity)
    }

    private var popups: some View {
        let popups = editor.fields(["popupDefaults"], on: screen, defaultsPath: "defaults",
                                   values: editor.values("defaults", on: screen).merging(editor.values("popupDefaults", on: screen)) { $1 })
        return ThemeGroup(title: "Popups") {
            popups.color("Background", "background")
            popups.color("Border", "borderColor")
            popups.color("Shadow", "shadowColor")
            popups.weight()
            popups.number("Text size", "fontSize", default: 12, in: 6...40)
            popups.number("Corner radius", "cornerRadius", default: 14, in: 0...40)
        }
        .frame(maxWidth: .infinity)
        .id(SettingsSearchResult.popups.id)
    }

    private var bar: some View {
        let values = editor.values("bar", on: screen)
        let bar = editor.fields(["bar"], on: screen, values: values)
        let style = editor.fields(["bar", "style"], on: screen, values: (try? values["style"]?.decoded([String: ConfigurationValue].self)) ?? [:])
        return ThemeGroup(title: "Bar") {
            style.color("Background", "background")
            style.color("Border", "borderColor")
            style.number("Border width", "borderWidth", default: 0, in: 0...6, step: 0.5)
            style.choice("Border edges", "borderEdges", choices: BarBorderEdges.allCases.map(\.rawValue), default: BarBorderEdges.bottom.rawValue)
            style.number("Corner radius", "cornerRadius", default: 0, in: 0...40)
            bar.number("Height", "height", default: 40, in: 16...100)
            bar.number("Side inset", "inset", default: 12, in: 0...100)
            bar.number("Spacing", "spacing", default: 8, in: 0...50)
        }
        .frame(maxWidth: .infinity)
    }

    private func reset(_ source: PropertyValueSource) {
        do { try store.removePropertySource(source, everyBar: editor.themeChangesEveryBar) }
        catch { store.customizationHistory.error = errorMessage(error) }
    }
}

struct ThemePreviewStrip: View {
    let look: Configuration
    let appearance: BarAppearance

    var body: some View {
        ThemeSampleBar(look: look)
            .background(SampleWallpaper())
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(SettingsPalette.groupBorder))
            .environment(\.colorScheme, appearance.colorScheme)
            .accessibilityHidden(true)
    }
}

struct SampleWallpaper: View {
    var body: some View { Wallpaper() }
}

private enum ThemeFilter {
    case all, included, store
}

private enum ThemeItem: Identifiable {
    case installed(ThemeChoice)
    case store(PackageIndex.Entry)

    var id: String {
        switch self {
        case let .installed(choice): choice.key
        case let .store(entry): entry.versionKey
        }
    }

    var title: String {
        switch self {
        case let .installed(choice): choice.title
        case let .store(entry): entry.name
        }
    }
}

private struct ThemeGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
            VStack(spacing: 0) { content }
                .labeledContentStyle(ThemeGroupRow())
                .padding(.top, -1)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.groupBorder))
        }
    }
}

private struct ThemeGroupRow: LabeledContentStyle {
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

enum AdvancedSheet: String, Identifiable {
    case roles, workspaceStyle, modeAliases

    var id: String { rawValue }
}

struct ThemeAdvancedSheet: View {
    let editor: ConfigurationEditor
    let sheet: AdvancedSheet
    let screen: ScreenKind?
    @State private var fontFamilies: [String] = []
    @State private var selectedRole = PresentationRole.time
    @State private var modeName = ""
    @State private var modeAlias = ""
    @Environment(\.dismiss) private var dismiss

    private var store: BarStore { editor.store }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                switch sheet {
                case .roles: roles
                case .workspaceStyle: workspaces
                case .modeAliases: modeAliases
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
        .background(SettingsPalette.background)
        .task { fontFamilies = NSFontManager.shared.availableFontFamilies }
    }

    private var roles: some View {
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
    }

    private var workspaces: some View {
        Section("Workspace look") {
            let fields = editor.fields(["workspaceDefaults"], on: screen, values: editor.values("workspaceDefaults", on: screen))
            WorkspacePresentationFields(store: store, path: fields.path, values: fields.values, set: fields.set, unset: fields.unset)
        }
    }

    private var modeAliases: some View {
        let aliases = editor.fields(["modeAliases"], on: screen, values: [:])
        let look = screen.map { store.configuration?.look(on: $0) } ?? store.configuration
        return Section("AeroSpace mode names") {
            ForEach((look?.modeAliases ?? [:]).keys.sorted(), id: \.self) { name in
                let own = store.origins["\(aliases.path).\(name)"]
                let origin = own ?? store.origins["modeAliases.\(name)"]
                OverrideRow(title: name, source: origin.map { "From \(store.sourceText($0))" },
                            reset: own.map(store.setsInMainFile) == true ? { aliases.unset([name: .null]) } : nil) {
                    Text("mode.\(look?.modeAliases[name] ?? "")")
                    Button("Remove") { aliases.set([name: .null]) }
                }
            }
            HStack {
                TextField("Local mode, e.g. tailing", text: $modeName)
                TextField("Alias, e.g. command", text: $modeAlias)
                Button("Set mapping") {
                    aliases.set([modeName: .string(modeAlias)])
                    if editor.error == nil { modeName = ""; modeAlias = "" }
                }.disabled(modeName.isEmpty || modeAlias.isEmpty)
            }
            Text("Your configuration maps mode names; the selected theme controls their colors and borders.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func roleFields(_ role: PresentationRole) -> StyleFields {
        let look = screen.map { store.configuration?.look(on: $0) } ?? store.configuration
        let style = (look?.roleStyle(role).inheriting(look?.defaults ?? WidgetStyle()) ?? WidgetStyle()).configurationValue
        return editor.fields(["roles", role.rawValue], on: screen, defaultsPath: "defaults",
                             values: (try? style.decoded([String: ConfigurationValue].self)) ?? [:])
    }
}

private extension ConfigurationEditor {
    func values(_ key: String, on screen: ScreenKind?) -> [String: ConfigurationValue] {
        let document = screen.flatMap { store.screenDocuments[$0.rawValue] } ?? store.effectiveDocument
        return (try? document[key]?.decoded([String: ConfigurationValue].self)) ?? [:]
    }

    func fields(_ keys: [String], on screen: ScreenKind?, defaultsPath: String? = nil, values: [String: ConfigurationValue]) -> StyleFields {
        let path = (screen.map { ["screens", $0.rawValue] } ?? []) + keys
        let nest = { (properties: [String: ConfigurationValue]) in path.dropFirst().reversed().reduce(properties) { [$1: .object($0)] } }
        return StyleFields(store: store, path: path.joined(separator: "."),
                           defaultsPath: screen == nil ? defaultsPath : keys.joined(separator: "."), values: values,
                           set: { self.change(ConfigurationEdit(action: ConfigurationEdit.Action(rawValue: path[0])!, properties: nest($0)),
                                              everyBar: self.themeChangesEveryBar) },
                           unset: { self.unset([path[0]: .object(nest($0))]) })
    }

    func unset(_ properties: [String: ConfigurationValue]) {
        change(ConfigurationEdit(action: .unset, properties: properties), everyBar: themeChangesEveryBar)
    }
}
