import AppKit
import SwiftUI

struct AppearanceView: View {
    @Bindable var editor: ConfigurationEditor
    @State private var advanced: AdvancedSheet?
    @State private var screen: ScreenKind?
    @State private var fontFamilies: [String] = []

    private var store: BarStore { editor.store }
    private var gallery: ThemeGallery { editor.gallery }
    private var kinds: [ScreenKind] { ScreenKind.allCases.filter { store.configurationStore.screenSetup?.kinds.contains($0) == true } }
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
                        header
                        scopeLine
                        if let configuration = store.configuration {
                            ThemePreviewStrip(look: screen.map(configuration.onScreen) ?? configuration, appearance: appearance)
                                .padding(.top, 12).padding(.bottom, 4)
                        }
                        themes(appearance)
                        if screen == nil, editor.editingProfile == nil, let theme = gallery.selectedChoice {
                            ThemeEditsLine(editor: editor, theme: theme).padding(.top, 12)
                        }
                        if screen == nil, editor.editingProfile == nil, let theme = gallery.selectedChoice {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Customize \(theme.manifest.name)").font(.system(size: 14, weight: .semibold))
                                Text("Your changes stay with \(theme.manifest.name). Other themes keep their own look.")
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                            .padding(.top, 28)
                        }
                        colors(appearance)
                        HStack(alignment: .top, spacing: 20) {
                            VStack(spacing: 22) {
                                widgets
                                groups
                                animation
                            }
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
                .task(id: store.pendingLinks.theme?.choice.directory) {
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
        .onChange(of: store.configurationStore.context) { _, _ in gallery.contextChanged() }
        .onChange(of: store.pendingLinks.theme?.choice.directory) { _, _ in gallery.contextChanged() }
        .onChange(of: store.pendingLinks.theme?.state) { _, _ in gallery.contextChanged() }
    }

    /// The page's title, what it edits and the bar's appearance.
    private var header: some View {
        let bar = editor.fields(["bar"], on: screen, values: editor.values("bar", on: screen))
        let source = store.propertySources(path: bar.path, key: "appearance", defaultsPath: bar.defaultsPath, values: bar.values)
        let saved = try? source.editingValue?.decoded(BarAppearance.self)
        return HStack(spacing: 10) {
            Text("Theme").font(.system(size: 15, weight: .semibold))
            if let screen, screenTheme != nil {
                Button("Use the theme of every screen") {
                    editor.unset(["screens": .object([screen.rawValue: .object(["theme": .null])])])
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            Spacer()
            if kinds.count > 1 || hasSetups || !themeProfiles.isEmpty { editingMenu }
            RevertSettingButton(title: "Appearance", property: source, reset: source.saved.map { saved in { reset(saved) } })
            SettingsSegments(selection: Binding(get: { saved }, set: {
                if $0 != saved { bar.set(["appearance": $0.map { .string($0.rawValue) } ?? .null]) }
            }), options: [(nil, "Automatic"), (.light, "Light"), (.dark, "Dark")], stretches: false)
            .fixedSize()
        }
        .padding(.top, 18)
        .padding(.horizontal, 2)
        .id(SettingsSearchResult.theme.id)
    }

    private var hasSetups: Bool { editor.editingProfile == nil && !store.configurationStore.screenSetupsWithOwnBars.isEmpty }
    private var themeProfiles: [ConfigurationProfile] { store.profiles.filter { $0.when?.onlyTheme == nil } }
    private var setupTitle: String {
        store.configurationStore.configurationURL == store.configurationStore.sharedConfigurationURL ? "Shared bar only" : "This setup only"
    }

    private var editingTitle: String {
        var parts = [screen?.screenTitle ?? "All screens"]
        if hasSetups, !editor.themeChangesEveryBar { parts.append(setupTitle.lowercased()) }
        if let profile = editor.editingProfile { parts.append("profile \(profile)") }
        return parts.joined(separator: ", ")
    }

    /// Which screens, setups and profile the page edits.
    private var editingMenu: some View {
        Menu {
            if kinds.count > 1 {
                Section("Screens") {
                    Picker("Screens", selection: $screen) {
                        Text("All screens").tag(ScreenKind?.none)
                        ForEach(kinds, id: \.self) { Text($0.screenTitle).tag(Optional($0)) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
            }
            if hasSetups {
                Section("Screen setups") {
                    Picker("Screen setups", selection: $editor.themeChangesEveryBar) {
                        Text("All setups").tag(true)
                        Text(setupTitle).tag(false)
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
            }
            if !themeProfiles.isEmpty {
                Section("Profile") {
                    Picker("Profile", selection: Binding(get: { editor.editingProfile ?? "" }, set: {
                        if $0 != (editor.editingProfile ?? "") { $0.isEmpty ? editor.endProfileEditing() : editor.editBar(for: $0) }
                    })) {
                        Text("No profile").tag("")
                        ForEach(themeProfiles, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                }
            }
        } label: {
            Text("Editing: \(editingTitle)")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    /// Says in words when the page edits less than every screen and setup.
    @ViewBuilder private var scopeLine: some View {
        if let screen {
            ScopeLine(text: "Editing \(screen.phrase) only. Other screens keep their look.", action: "Edit All Screens") { self.screen = nil }
        } else if hasSetups, !editor.themeChangesEveryBar {
            ScopeLine(text: "Changes apply to this setup only. Other setups keep their look.", action: "Apply to All Setups") {
                editor.themeChangesEveryBar = true
            }
        }
    }

    private func themes(_ appearance: BarAppearance) -> some View {
        let sections = gallerySections
        let items = sections.flatMap(\.items)
        return VStack(alignment: .leading, spacing: 10) {
            if let candidate = store.pendingLinks.theme, candidate.state != .used {
                LinkedThemeCard(candidate: candidate, editor: editor, screen: screen, everyBar: editor.themeChangesEveryBar)
                    .id(candidate.choice.directory)
                    .padding(.bottom, 4)
            } else if let message = store.pendingLinks.themeError {
                LinkedThemeErrorCard(message: message) { store.pendingLinks.themeError = nil }
                    .padding(.bottom, 4)
            }
            if let candidate = store.pendingLinks.bar, candidate.state != .used {
                LinkedBarCard(candidate: candidate, editor: editor, screen: screen, everyBar: editor.themeChangesEveryBar)
                    .id(candidate.look.choice.directory)
                    .padding(.bottom, 4)
            } else if let message = store.pendingLinks.barError {
                LinkedThemeErrorCard(message: message) { store.pendingLinks.barError = nil }
                    .padding(.bottom, 4)
            }
            ForEach(sections, id: \.title) { section in
                Text(section.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.top, 8).padding(.horizontal, 2)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(section.items) { card($0, appearance: appearance) }
                }
            }
            ForEach(items) { item in
                if let error = gallery.error(for: item.id) {
                    Label("\(item.title): \(error)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if gallery.storeUnavailable {
                Text("The Store is unavailable. Your installed themes are ready to use.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    /// The themes that come with StableBar, yours, and the Store's, each section shown when it has a theme.
    private var gallerySections: [(title: String, items: [ThemeItem])] {
        let installed = gallery.choices.onePerTheme(keeping: Set([gallery.selectedKey] + (screenTheme.map { [$0.key] } ?? [])))
            .filter { !$0.isBundled }
        let yours = installed.filter { [.installed, .local].contains(gallery.source(of: $0)) }
        let fromSources = installed.filter { ![.installed, .local].contains(gallery.source(of: $0)) }.map(ThemeItem.installed)
            + gallery.storeThemes.map(ThemeItem.store)
        return [("Included", gallery.choices.filter(\.isBundled).map(ThemeItem.installed)),
                ("Yours", yours.map(ThemeItem.installed).sorted { $0.title < $1.title }),
                ("Store", fromSources.sorted { $0.title < $1.title })].filter { !$0.items.isEmpty }
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
                             error: gallery.error(for: item.id), isStore: true,
                             source: entry.sourceID == PackageSource.storeID ? nil : .privateSource(gallery.sourceName(entry.sourceID))) {
                Task { await gallery.get(entry, on: screen, everyBar: editor.themeChangesEveryBar) }
            }
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
                ForEach(store.themeTokenColors(in: document).filter(\.isShared)) { token in
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
            defaults.number("Text size", "fontSize", default: 13, in: 6...40)
            defaults.number("Horizontal padding", "paddingHorizontal", default: 10, in: 0...40)
            defaults.number("Vertical padding", "paddingVertical", default: 6, in: 0...40)
            defaults.number("Corner radius", "cornerRadius", default: 14, in: 0...40)
        }
        .frame(maxWidth: .infinity)
    }

    private var groups: some View {
        let groups = editor.fields(["groupDefaults"], on: screen, values: editor.values("groupDefaults", on: screen))
        let look = screen.map { store.configuration?.onScreen($0) } ?? store.configuration
        let flared = look?.groupDefaults.flare != nil
        return ThemeGroup(title: "Groups") {
            groups.color("Background", "background")
            groups.color("Border", "borderColor").disabled(flared)
            groups.number("Border width", "borderWidth", default: 0, in: 0...6, step: 0.5).disabled(flared)
            groups.number("Corner radius", "cornerRadius", default: 0, in: 0...40)
            groups.number("Horizontal padding", "paddingHorizontal", default: 0, in: 0...30)
            groups.number("Vertical padding", "paddingVertical", default: 0, in: 0...20)
            groups.number("Spacing", "spacing", default: look?.bar.spacing ?? 8, in: 0...30)
        }
        .frame(maxWidth: .infinity)
    }

    private var animation: some View {
        let values = editor.values("bar", on: screen)
        let bar = editor.fields(["bar"], on: screen, values: values)
        let motion = (try? values["motion"]?.decoded(BarMotion.self)) ?? .smooth
        return ThemeGroup(title: "Animation") {
            bar.choice("Motion", "motion", choices: BarMotion.allCases.map(\.rawValue), default: BarMotion.smooth.rawValue)
            bar.choice("Popups", "popupTransition", choices: PopupTransition.allCases.map(\.rawValue), default: motion.popupTransition.rawValue)
            bar.toggle("Morph between popups", "morphPopups", default: true,
                       hint: "Opening another widget's popup or tooltip moves the open one into it.")
        }
        .frame(maxWidth: .infinity)
        .id(SettingsSearchResult.animation.id)
    }

    private var popups: some View {
        let popups = editor.fields(["popupDefaults"], on: screen, defaultsPath: "defaults",
                                   values: editor.values("defaults", on: screen).merging(editor.values("popupDefaults", on: screen)) { $1 })
        // Popups don't take the bar widgets' padding and spacing from defaults.
        let spacing = editor.fields(["popupDefaults"], on: screen, values: editor.values("popupDefaults", on: screen))
        let popupPadding = PopupConfiguration.defaultPadding
        let bar = editor.fields(["bar"], on: screen, values: editor.values("bar", on: screen))
        return ThemeGroup(title: "Popups") {
            popups.color("Background", "background")
            popups.color("Border", "borderColor")
            popups.color("Shadow", "shadowColor")
            popups.weight()
            popups.number("Text size", "fontSize", default: 13, in: 6...40)
            popups.number("Corner radius", "cornerRadius", default: 14, in: 0...40)
            spacing.number("Horizontal padding", "paddingHorizontal", default: popupPadding.paddingHorizontal!, in: 0...40)
            spacing.number("Vertical padding", "paddingVertical", default: popupPadding.paddingVertical!, in: 0...40)
            spacing.number("Spacing", "spacing", default: PopupConfiguration.blockSpacing, in: 0...40,
                           hint: "Unset, a popup's blocks sit 12 apart and the items of a row, column or list 6. A value sets both.")
            bar.number("Gap below the bar", "popupOffset", default: BarSettings().popupOffset, in: 0...40,
                       hint: "Also moves tooltips and hover controls. A popup's own offset wins.")
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

private enum ThemeItem: Identifiable {
    case installed(ThemeChoice)
    case store(PackageIndex.Entry)

    var id: String {
        switch self {
        case let .installed(choice): choice.key
        case let .store(entry): entry.key
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
            role.number("Font size", "fontSize", default: 13)
            role.color("Text", "foreground")
            role.color("Background", "background")
            role.color("Border", "borderColor")
            role.color("Accent", "accent")
            role.number("Border width", "borderWidth", default: 0)
            role.number("Corner radius", "cornerRadius", default: 0)
            if selectedRole == .slider { role.number("Height", "height", default: 28) }
            role.number("Horizontal padding", "paddingHorizontal", default: 0)
            role.number("Vertical padding", "paddingVertical", default: 0)
            Text(selectedRole == .slider
                 ? "Sliders follow this role unless they set filled or another role. An empty role keeps the native slider."
                 : "Only widgets and layout blocks explicitly assigned this role use it. A bar widget’s role does not style its popup.")
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
                           set: { self.changeLook(ConfigurationEdit(action: ConfigurationEdit.Action(rawValue: path[0])!, properties: nest($0)),
                                                  everyBar: self.themeChangesEveryBar) },
                           unset: { self.unset([path[0]: .object(nest($0))]) })
    }

    func unset(_ properties: [String: ConfigurationValue]) {
        changeLook(ConfigurationEdit(action: .unset, properties: properties), everyBar: themeChangesEveryBar)
    }
}

/// A tinted line saying what the page edits when it's less than everything, with the way back.
private struct ScopeLine: View {
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
            Spacer(minLength: 8)
            Button(action, action: perform).controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor.opacity(0.35)))
        .padding(.top, 10)
    }
}
