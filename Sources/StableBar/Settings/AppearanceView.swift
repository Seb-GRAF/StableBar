import AppKit
import SwiftUI

struct AppearanceView: View {
    @Bindable var editor: ConfigurationEditor
    @State private var advanced: AdvancedSheet?
    @State private var screen: ScreenKind?
    @State private var fontFamilies: [String] = []
    /// Customize's sections opened or closed by hand; the others open while they have edits.
    @State private var expanded: [String: Bool] = [:]

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
                        colors
                        lookSections
                        glass
                        let advancedChanges = editor.lookChanges(under: ["roles", "workspaceDefaults"])
                        SettingsGroup("Advanced", detail: changeCount(advancedChanges.count),
                                      reset: editor.reset(advancedChanges, everyBar: editor.themeChangesEveryBar),
                                      isExpanded: expansion("Advanced", opens: !advancedChanges.isEmpty)) {
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
                        let sections = [SettingsSearchResult.colors.id: "Theme colors", SettingsSearchResult.popups.id: "Popups",
                                        SettingsSearchResult.glass.id: "Liquid Glass"]
                        if let section = advanced == nil ? sections[target] : "Advanced" { expanded[section] = true }
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

    private var gallerySections: [(title: String, items: [ThemeItem])] {
        let installed = gallery.choices.onePerTheme(keeping: Set([gallery.selectedKey] + (screenTheme.map { [$0.key] } ?? [])))
            .filter { !$0.isBundled }
        let isYours = { (choice: ThemeChoice) in [.installed, .local, .saved, .themeLink, .barLink].contains(gallery.source(of: choice)) }
        let yours = installed.filter(isYours)
        let fromSources = installed.filter { !isYours($0) }.map(ThemeItem.installed)
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
                             isEdited: gallery.editedThemes.contains(choice.manifest.id),
                             progress: gallery.progress[item.id], error: gallery.error(for: item.id), source: gallery.source(of: choice),
                             showInFinder: choice.isBundled ? nil : { NSWorkspace.shared.activateFileViewerSelecting([choice.directory]) },
                             delete: choice.isBundled ? nil : { Task { await gallery.delete(choice) } }) {
                gallery.select(choice, on: screen, everyBar: editor.themeChangesEveryBar)
            }
        case let .store(entry):
            return ThemeCard(title: entry.name, look: look, appearance: appearance, progress: gallery.progress[item.id],
                             error: gallery.error(for: item.id), isStore: true,
                             source: entry.sourceID == PackageSource.storeID ? nil : .privateSource(gallery.sourceName(entry.sourceID))) {
                Task { await gallery.get(entry, on: screen, everyBar: editor.themeChangesEveryBar) }
            }
        }
    }

    private var colors: some View {
        let tokens = editor.fields(["tokens"], on: screen, values: editor.values("tokens", on: screen))
        let changes = editor.lookChanges(under: [tokens.path])
        return SettingsGroup("Theme colors", detail: changeCount(changes.count), reset: editor.reset(changes, everyBar: editor.themeChangesEveryBar),
                             isExpanded: expansion("Theme colors", opens: true)) {
            LightDarkHeader()
            ForEach(store.themeTokenColors(in: document).filter(\.isShared)) { token in
                let property = store.propertySources(path: tokens.path, key: token.name, defaultsPath: tokens.defaultsPath, values: tokens.values)
                let color = (try? property.editingValue?.decoded(HexColor.self)) ?? token.color
                TokenColorButton(title: token.title, color: color, property: property, reset: property.saved.map { source in { reset(source) } }) {
                    tokens.set([token.name: $0])
                }
            }
        }
        .id(SettingsSearchResult.colors.id)
    }

    private var glass: some View {
        let glass = editor.fields(["bar", "glass"], on: screen,
                                  values: (try? editor.values("bar", on: screen)["glass"]?.decoded([String: ConfigurationValue].self)) ?? [:])
        let changes = editor.lookChanges(under: [glass.path])
        return SettingsGroup("Liquid Glass", detail: changeCount(changes.count), reset: editor.reset(changes, everyBar: editor.themeChangesEveryBar),
                             isExpanded: expansion("Liquid Glass", opens: !changes.isEmpty)) {
            glass.toggle("Use Liquid Glass", "enabled", default: false, hint: "Experimental. Needs macOS 26 or later.")
            if glass.values["enabled"] == .bool(true) {
                glass.percentage("See-through", "transparency", default: 0.3)
                glass.toggle("Widgets", "widgets", default: true)
                glass.toggle("Popups", "popups", default: true)
                glass.toggle("Bar", "bar", default: true)
            }
        }
        .id(SettingsSearchResult.glass.id)
    }

    private func expansion(_ title: String, opens: Bool) -> Binding<Bool> {
        Binding(get: { expanded[title] ?? opens }, set: { expanded[title] = $0 })
    }

    /// The same sections as the bar editor's, for the screens Editing names.
    @ViewBuilder private var lookSections: some View {
        let everyBar = editor.themeChangesEveryBar
        let look = screen.map { store.configuration?.onScreen($0) } ?? store.configuration
        let bar = editor.values("bar", on: screen)
        let barFields = editor.fields(["bar"], on: screen, values: bar)
        WidgetsLookSection(editor: editor, style: editor.fields(["defaults"], on: screen, values: editor.values("defaults", on: screen)),
                           fontFamilies: fontFamilies, everyBar: everyBar, expansion: $expanded["Widgets"])
        GroupsLookSection(editor: editor, style: editor.fields(["groupDefaults"], on: screen, values: editor.values("groupDefaults", on: screen)),
                          flared: look?.groupDefaults.flare != nil, spacing: look?.bar.spacing ?? 8, everyBar: everyBar,
                          expansion: $expanded["Groups"])
        PopupsLookSection(editor: editor,
                          style: editor.fields(["popupDefaults"], on: screen, defaultsPath: "defaults",
                                               values: editor.values("defaults", on: screen).merging(editor.values("popupDefaults", on: screen)) { $1 }),
                          spacing: editor.fields(["popupDefaults"], on: screen, values: editor.values("popupDefaults", on: screen)),
                          bar: barFields, fontFamilies: fontFamilies, everyBar: everyBar, expansion: $expanded["Popups"])
            .id(SettingsSearchResult.popups.id)
        BarLookSection(editor: editor, bar: barFields,
                       style: editor.fields(["bar", "style"], on: screen, values: (try? bar["style"]?.decoded([String: ConfigurationValue].self)) ?? [:]),
                       everyBar: everyBar, expansion: $expanded["Bar"])
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
            LightDarkHeader()
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
