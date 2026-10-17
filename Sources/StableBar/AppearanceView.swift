import AppKit
import SwiftUI

let themeTokens: [(name: String, title: String)] = [
    ("surface", "Surface"), ("surfaceRaised", "Raised surface"), ("text", "Text"), ("textMuted", "Muted text"),
    ("accent", "Accent"), ("track", "Track"), ("hairline", "Hairline"), ("warning", "Warning"), ("critical", "Critical")
]

struct AppearanceView: View {
    let editor: ConfigurationEditor
    @State private var themes: [ThemeChoice] = []
    @State private var looks: [String: Configuration] = [:]
    @State private var fontFamilies = NSFontManager.shared.availableFontFamilies
    @State private var selectedRole = PresentationRole.time
    @State private var modeName = ""
    @State private var modeAlias = ""

    private var store: BarStore { editor.store }

    var body: some View {
        let theme = try? store.effectiveDocument["theme"]?.decoded(WidgetPackageSelection.self)
        let selected = theme?.enabled == true ? theme?.key : nil
        let tokens = document("tokens")
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
        let barStyle = StyleFields(store: store, path: "bar.style",
                                   values: (try? document("bar")["style"]?.decoded([String: ConfigurationValue].self)) ?? [:],
                                   set: { editor.change(ConfigurationEdit(action: .bar, properties: ["style": .object($0)])) },
                                   unset: { unset(["bar": .object(["style": .object($0)])]) })
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ThemeCard(title: "Built-in", look: looks[""], isSelected: selected == nil, mode: store.modePresentation) {
                        editor.change(ConfigurationEdit(action: .theme))
                    }
                    ForEach(themes, id: \.key) { choice in
                        ThemeCard(title: choice.title, look: looks[choice.key], isSelected: selected == choice.key, mode: store.modePresentation) {
                            editor.change(ConfigurationEdit(action: .theme, properties: choice.selection))
                        }
                    }
                }
                .padding(.vertical, 4)
                Picker("Appearance", selection: Binding(get: { store.configuration?.bar.appearance }, set: {
                    if $0 != store.configuration?.bar.appearance {
                        editor.change(ConfigurationEdit(action: .bar, properties: ["appearance": $0.map { .string($0.rawValue) } ?? .null]))
                    }
                })) {
                    Text("Automatic").tag(BarAppearance?.none)
                    Text("Light").tag(BarAppearance?.some(.light))
                    Text("Dark").tag(BarAppearance?.some(.dark))
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Theme")
            } footer: {
                Text("Automatic follows the system’s light or dark mode. Install other themes in Packages.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                ForEach(themeTokens, id: \.name) { token in
                    if let color = try? tokens[token.name]?.decoded(HexColor.self) {
                        let origin = store.origins["tokens.\(token.name)"]
                        OverrideRow(title: token.title, source: origin.map { "From \(store.sourceText($0))" },
                                    reset: origin.map(store.setsInMainFile) == true ? { unset(["tokens": .object([token.name: .null])]) } : nil) {
                            ColorWells(color: color) { editor.change(ConfigurationEdit(action: .tokens, properties: [token.name: $0])) }
                        }
                    }
                }
            } header: {
                Text("Theme colors")
            } footer: {
                Text("Changes are saved in your configuration’s tokens, so every widget, popup and package that uses a color follows.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("All widgets") {
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
            }
            Section("Popups") {
                popups.color("Background", "background")
                popups.color("Border", "borderColor")
                popups.color("Shadow", "shadowColor")
                popups.weight()
            }
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
            Section("Workspace defaults") {
                WorkspacePresentationFields(store: store, path: "workspaceDefaults", values: document("workspaceDefaults"),
                    set: { editor.change(ConfigurationEdit(action: .workspaceDefaults, properties: $0)) },
                    unset: { unset(["workspaceDefaults": .object($0)]) })
            }
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
            Section("Bar") {
                barStyle.color("Background", "background")
                barStyle.color("Border", "borderColor")
                barStyle.number("Border width", "borderWidth", default: 0)
                barStyle.choice("Border edges", "borderEdges", choices: BarBorderEdges.allCases.map(\.rawValue),
                                default: BarBorderEdges.bottom.rawValue)
                barStyle.number("Corner radius", "cornerRadius", default: 0)
                bar.number("Height", "height", default: 40)
                bar.number("Offset from top", "offset", default: 0)
                bar.number("Margin", "margin", default: 0)
                bar.number("Side inset", "inset", default: 12)
                bar.number("Spacing", "spacing", default: 8)
            }
            Section {
                let origin = store.origins["bar.keepWindowsClear"]
                OverrideRow(title: "Keep windows clear of StableBar", source: origin.map { "From \(store.sourceText($0))" },
                            reset: origin.map(store.setsInMainFile) == true ? { unset(["bar": .object(["keepWindowsClear": .null])]) } : nil) {
                    Toggle("Keep windows clear of StableBar", isOn: Binding(
                        get: { store.configuration?.bar.keepWindowsClear == true },
                        set: { enabled in
                            editor.change(ConfigurationEdit(action: .bar, properties: ["keepWindowsClear": .bool(enabled)]))
                            if enabled && !store.windowClearance.isTrusted { store.windowClearance.requestAccess() }
                        }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                if store.configuration?.bar.keepWindowsClear == true {
                    LabeledContent("Accessibility", value: store.windowClearance.isTrusted ? "Access granted" : "Access required")
                    if !store.windowClearance.isTrusted {
                        Button("Allow Accessibility Access…") { store.windowClearance.requestAccess() }
                    }
                }
            } header: {
                Text("Windows")
            } footer: {
                Text("Moves ordinary windows below the bar and reduces their height when needed. Fullscreen windows are unchanged. Leave this off if AeroSpace or yabai already manages your window gaps.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadThemes)
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

    private func loadThemes() {
        themes = themeChoices(packages: store.configurationURL.deletingLastPathComponent().appending(path: "packages"))
        var loader = ConfigurationLoader()
        looks = [:]
        looks[""] = try? loader.load(store.configurationURL, data: Data("{}".utf8))
        for theme in themes {
            looks[theme.key] = try? loader.load(store.configurationURL, data: JSONEncoder().encode(["theme": ConfigurationValue.object(theme.selection)]))
        }
    }
}

private struct ThemeCard: View {
    let title: String
    let look: Configuration?
    let isSelected: Bool
    let mode: ModePresentation
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    preview.environment(\.colorScheme, .light)
                    preview.environment(\.colorScheme, .dark)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: isSelected ? 2 : 1)
                }
                HStack(spacing: 4) {
                    Text(title)
                    if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }
                .font(.callout)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var preview: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .underPageBackgroundColor)
            if let look {
                let tile = WidgetAppearance(look.roleStyle(.time).inheriting(look.defaults).resolved(for: StyleStates(mode: mode)), defaults: WidgetStyle())
                let bar = look.bar.style.resolved(for: StyleStates(mode: mode))
                HStack(spacing: tile.spacing) {
                    Circle().fill(tile.accent).frame(width: 7, height: 7)
                    Text("9:41")
                }
                .font(tile.font)
                .foregroundStyle(tile.foreground)
                .padding(.horizontal, tile.paddingHorizontal)
                .padding(.vertical, tile.paddingVertical)
                .background(tile.background, in: RoundedRectangle(cornerRadius: tile.cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: tile.cornerRadius).strokeBorder(tile.borderColor, lineWidth: tile.borderWidth)
                }
                .shadow(color: tile.shadowColor, radius: tile.shadowRadius, y: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background((bar.background ?? look.bar.background).color, in: RoundedRectangle(cornerRadius: bar.cornerRadius ?? 0))
                .overlay { BarBorder(style: bar) }
                .overlay(alignment: .bottomLeading) {
                    if let workspace = try? look.workspaceDefaults.merging(nil), workspace.indicator == .underline {
                        let underline = workspace.cellStyle(.focused, mode: mode).underline
                        if underline.placement == .belowBar {
                            (underline.background?.color ?? tile.accent)
                                .frame(width: 20, height: max(0, underline.height ?? 2))
                                .offset(x: look.bar.inset, y: max(0, underline.height ?? 2) + (underline.offsetY ?? 0))
                                .allowsHitTesting(false)
                        }
                    }
                }
                .padding(look.bar.margin)
                .frame(height: look.bar.height)
            }
        }
        .frame(height: 56)
    }
}
