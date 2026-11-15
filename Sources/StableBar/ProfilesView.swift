import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfilesView: View {
    @Bindable var editor: ConfigurationEditor
    @State private var naming = false
    @State private var newName = ""
    @State private var editingJSON = false
    @State private var hovered: String?
    @State private var deleting: String?

    private var store: BarStore { editor.store }
    private var selected: ConfigurationProfile? {
        store.profiles.first { $0.name == editor.selectedProfileName } ?? store.profiles.first
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 256)
                .background(SettingsPalette.sidebar)
            Divider()
            if let selected {
                detail(selected)
            } else {
                ContentUnavailableView("No profiles", systemImage: "switch.2",
                                       description: Text("Add a profile to change your bar in some situations."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.absoluteString == "settings:bar" { editor.section = .widgets } else { editingJSON = true }
            return .handled
        })
        .sheet(isPresented: $editingJSON) {
            if let selected {
                let json = try? String(decoding: configurationData(selected.configuration), as: UTF8.self)
                JSONSheet(title: "\(selected.name) as JSON", text: json ?? "{}", apply: {
                    editor.setProfileConfiguration(name: selected.name, configuration: $0)
                    return editor.error
                }, close: { editingJSON = false })
            }
        }
        .confirmationDialog(deleting.map { editor.profileRemoval($0) == .removeChanges ? "Remove your changes to \($0)?" : "Delete the \($0) profile?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { name in
            Button(editor.profileRemoval(name) == .removeChanges ? "Remove changes" : "Delete profile", role: .destructive) {
                editor.deleteProfile(name)
            }
        } message: { name in
            Text(editor.profileRemoval(name) == .removeChanges
                 ? "It comes from your theme, a package or an included file, so it stays with the conditions and changes set there."
                 : "Its conditions and changes are removed from your configuration.")
        }
        .onChange(of: editor.searchTarget, initial: true) {
            if editor.searchTarget == SettingsSearchResult.profiles.id { editor.searchTarget = nil }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Profiles change your bar in some situations. To choose what each screen shows, use [Bar](settings:bar).")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 12, leading: 12, bottom: 6, trailing: 12))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.profiles, id: \.name) { card($0) }
                    Text("When several match, the lower one wins.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .padding(EdgeInsets(top: 6, leading: 8, bottom: 10, trailing: 8))
            }
            Divider()
            Button("New profile", systemImage: "plus") { naming = true }
                .popover(isPresented: $naming, arrowEdge: .top) { newProfile }
                .padding(8)
        }
    }

    private func card(_ profile: ConfigurationProfile) -> some View {
        let isSelected = profile.name == selected?.name
        let count = changes(profile.configuration).count
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(profile.name).fontWeight(.semibold).lineLimit(1)
                if store.activeProfiles.contains(profile.name) { badge("Active", SettingsPalette.success) }
                if store.pinnedProfile == profile.name { badge("Pinned", SettingsPalette.profile) }
                Spacer(minLength: 0)
                enabledToggle(profile)
            }
            Text(sentence(profile)).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(count == 0 ? "Changes nothing yet" : "Changes \(count) \(count == 1 ? "thing" : "things")")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(EdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).strokeBorder(isSelected ? SettingsPalette.profile
                : hovered == profile.name ? Color.secondary.opacity(0.5) : SettingsPalette.groupBorder,
                                                           lineWidth: isSelected ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { hovered = $0 ? profile.name : nil }
        .onTapGesture { editor.selectedProfileName = profile.name }
        .contextMenu { removalButton(profile) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { editor.selectedProfileName = profile.name }
    }

    private func badge(_ title: String, _ color: Color) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
    }

    private func enabledToggle(_ profile: ConfigurationProfile) -> some View {
        Toggle("Enabled", isOn: Binding(get: { profile.enabled }, set: {
            var edited = profile
            edited.enabled = $0
            editor.setProfile(edited)
        }))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var newProfile: some View {
        let taken = store.profiles.contains { $0.name == newName }
        return VStack(alignment: .leading, spacing: 10) {
            Text("New profile").font(.headline)
            TextField("Name", text: $newName).frame(width: 220).onSubmit(addProfile)
            Text(taken ? "Another profile has this name." : " ")
                .font(.caption)
                .foregroundStyle(.red)
            HStack {
                Spacer()
                Button("Cancel") { naming = false }.keyboardShortcut(.cancelAction)
                Button("Create", action: addProfile).keyboardShortcut(.defaultAction).disabled(newName.isEmpty || taken)
            }
        }
        .padding(14)
    }

    private func addProfile() {
        guard !newName.isEmpty, !store.profiles.contains(where: { $0.name == newName }) else { return }
        editor.addProfile(name: newName)
        guard editor.error == nil else { return }
        editor.selectedProfileName = newName
        newName = ""
        naming = false
    }

    private func detail(_ profile: ConfigurationProfile) -> some View {
        let pinned = store.pinnedProfile == profile.name
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "switch.2")
                    .font(.system(size: 17))
                    .foregroundStyle(SettingsPalette.profile)
                    .frame(width: 36, height: 36)
                    .background(SettingsPalette.profileSoft, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.system(size: 15, weight: .semibold))
                    Text(store.activeProfiles.contains(profile.name) ? "Active now"
                         : profile.enabled ? "Waiting for its conditions" : "Turned off")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                enabledToggle(profile)
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 16))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    group("When") { conditionsRow(profile) }
                    group("What it changes") { changeRows(profile) }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            actions(profile, pinned: pinned)
                            Spacer(minLength: 0)
                            removalButton(profile)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) { actions(profile, pinned: pinned) }
                            removalButton(profile)
                        }
                    }
                    .padding(.top, 14)
                    Text("Preview pins the profile until you stop it, whatever its conditions. [Edit as JSON…](settings:json)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                }
                .padding(EdgeInsets(top: 2, leading: 16, bottom: 18, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private func actions(_ profile: ConfigurationProfile, pinned: Bool) -> some View {
        Button { editor.editBar(for: profile.name) } label: {
            Label("Edit the bar for this profile", systemImage: "pencil")
        }
        .buttonStyle(.borderedProminent)
        .tint(SettingsPalette.profile)
        Button(pinned ? "Stop previewing" : "Preview now") {
            editor.change(ConfigurationEdit(action: .profile, name: pinned ? nil : profile.name))
        }
    }

    private func removalButton(_ profile: ConfigurationProfile) -> some View {
        let removal = editor.profileRemoval(profile.name)
        return Button(removal == .removeChanges ? "Remove your changes…" : "Delete profile…", role: .destructive) {
            deleting = profile.name
        }
        .disabled(removal == .unavailable)
        .help(removal == .unavailable ? "This profile comes from your theme, a package or an included file. Turn it off instead." : "")
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.groupBorder))
        }
        .padding(.top, 14)
    }

    private func conditionsRow(_ profile: ConfigurationProfile) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { conditionItems(profile) }
            VStack(alignment: .leading, spacing: 6) { conditionItems(profile) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }

    @ViewBuilder private func conditionItems(_ profile: ConfigurationProfile) -> some View {
        let conditions = self.conditions(profile)
        ForEach(Array(conditions.enumerated()), id: \.element.id) { index, condition in
            if index > 0 { Text("and").font(.system(size: 11.5)).foregroundStyle(.tertiary) }
            chip(condition, profile: profile)
        }
        if conditions.isEmpty { Text("Always").font(.system(size: 11.5)).foregroundStyle(.secondary) }
        let screens = store.context.displayCount
        Menu {
            Button("Dark Mode is on") { editor.setProfileCondition(profile.name, \.appearance, value: "dark", control: "appearance") }
            Button("Light Mode is on") { editor.setProfileCondition(profile.name, \.appearance, value: "light", control: "appearance") }
            Divider()
            Button("On battery") { editor.setProfileCondition(profile.name, \.onBattery, value: true, control: "onBattery") }
            Button("On power adapter") { editor.setProfileCondition(profile.name, \.onBattery, value: false, control: "onBattery") }
            Divider()
            Button("A monitor is connected") {
                editor.setProfileCondition(profile.name, \.externalDisplay, value: true, control: "externalDisplay")
            }
            Button("Only the laptop screen is connected") {
                editor.setProfileCondition(profile.name, \.externalDisplay, value: false, control: "externalDisplay")
            }
            Button(screenCount(screens)) { editor.setProfileCondition(profile.name, \.displayCount, value: screens, control: "displayCount") }
            Divider()
            Button("An app is in front…") { chooseApp(for: profile) }
        } label: {
            Label("Condition", systemImage: "plus")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .fixedSize()
    }

    private func chip(_ condition: ProfileCondition, profile: ConfigurationProfile) -> some View {
        HStack(spacing: 4) {
            if let count = profile.when?.displayCount, condition.id == "displayCount" {
                Stepper("Screens", value: Binding(get: { count }, set: {
                    editor.setProfileCondition(profile.name, \.displayCount, value: $0, control: "displayCount")
                }), in: 1...9)
                .labelsHidden()
                .controlSize(.mini)
            }
            Text(condition.text)
            Button(action: condition.remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove this condition")
        }
        .font(.system(size: 12))
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(SettingsPalette.profileSoft, in: Capsule())
    }

    private func sentence(_ profile: ConfigurationProfile) -> String {
        let conditions = self.conditions(profile)
        return conditions.isEmpty ? "Always" : "When " + conditions.map(\.phrase).joined(separator: " and ")
    }

    private func conditions(_ profile: ConfigurationProfile) -> [ProfileCondition] {
        let when = profile.when ?? ProfileConditions()
        let name = profile.name
        var conditions: [ProfileCondition] = []
        if let appearance = when.appearance {
            let text = appearance == "dark" ? "Dark Mode is on" : "Light Mode is on"
            conditions.append(ProfileCondition(id: "appearance", text: text, phrase: text) {
                editor.setProfileCondition(name, \.appearance, value: nil, control: "appearance")
            })
        }
        if let battery = when.onBattery {
            conditions.append(ProfileCondition(id: "onBattery", text: battery ? "On battery" : "On power adapter",
                                               phrase: battery ? "on battery" : "on power adapter") {
                editor.setProfileCondition(name, \.onBattery, value: nil, control: "onBattery")
            })
        }
        if let count = when.displayCount {
            conditions.append(ProfileCondition(id: "displayCount", text: screenCount(count), phrase: screenCount(count)) {
                editor.setProfileCondition(name, \.displayCount, value: nil, control: "displayCount")
            })
        }
        if let external = when.externalDisplay {
            conditions.append(ProfileCondition(id: "externalDisplay",
                                               text: external ? "A monitor is connected" : "Only the laptop screen is connected",
                                               phrase: external ? "a monitor is connected" : "only the laptop screen is connected") {
                editor.setProfileCondition(name, \.externalDisplay, value: nil, control: "externalDisplay")
            })
        }
        if let app = when.app {
            let text = "\(NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)?.deletingPathExtension().lastPathComponent ?? app) is in front"
            conditions.append(ProfileCondition(id: "app", text: text, phrase: text) {
                editor.setProfileCondition(name, \.app, value: nil, control: "app")
            })
        }
        return conditions
    }

    private func screenCount(_ count: Int) -> String {
        count == 1 ? "1 screen is connected" : "\(count) screens are connected"
    }

    private func chooseApp(for profile: ConfigurationProfile) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose app"
        if panel.runModal() == .OK, let url = panel.url, let identifier = Bundle(url: url)?.bundleIdentifier {
            editor.setProfileCondition(profile.name, \.app, value: identifier, control: "app")
        }
    }

    @ViewBuilder private func changeRows(_ profile: ConfigurationProfile) -> some View {
        let changes = self.changes(profile.configuration)
        let main = try? store.editedMainDocument(replaying: store.customizationEdits)["profiles"]?
            .decoded([ConfigurationProfile].self).first { $0.name == profile.name }?.configuration
        let removable = Set(self.changes(main ?? [:]).map(\.path))
        let names = WidgetDisplayName.names(for: store.configuration?.widgets ?? [], packageNames: store.widgetPackageNames,
                                            providers: store.configuration?.providers ?? [:])
        if changes.isEmpty {
            Text("Nothing yet. Edit the bar for this profile and your changes land here.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        }
        ForEach(Array(changes.enumerated()), id: \.element.path) { index, change in
            HStack(spacing: 10) {
                Circle().fill(SettingsPalette.profile).frame(width: 7, height: 7)
                Text(changeTitle(change, names: names))
                Spacer()
                changeValue(change).font(.system(size: 12)).foregroundStyle(.secondary)
                Button { remove(change, from: profile) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove this change")
                .opacity(removable.contains(change.path) ? 1 : 0)
                .disabled(!removable.contains(change.path))
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(minHeight: 38)
            .overlay(alignment: .top) {
                if index > 0 { Rectangle().fill(SettingsPalette.separator).frame(height: 1) }
            }
        }
    }

    private func changes(_ configuration: [String: ConfigurationValue]) -> [(path: [String], value: ConfigurationValue)] {
        func leaves(_ value: ConfigurationValue, _ path: [String]) -> [(path: [String], value: ConfigurationValue)] {
            if case let .object(object) = value, !object.isEmpty, path != ["theme"], object["gradient"] == nil,
               (try? value.decoded(HexColor.self)) == nil {
                return object.keys.sorted().flatMap { leaves(object[$0]!, path + [$0]) }
            }
            return [(path, value)]
        }
        return configuration.keys.sorted().flatMap { key -> [(path: [String], value: ConfigurationValue)] in
            guard key == "widgets", case let .array(widgets) = configuration[key] else { return leaves(configuration[key]!, [key]) }
            return widgets.compactMap { widget in
                guard case let .object(definition) = widget, case let .string(id) = definition["id"] else { return nil }
                return (["widgets", id], widget)
            }
        }
    }

    private func changeTitle(_ change: (path: [String], value: ConfigurationValue), names: [String: String]) -> String {
        let path = change.path
        var detail = Array(path.dropFirst())
        let owner: String
        switch path[0] {
        case "bar" where path.count > 2 && path[1] == "glass":
            owner = "Liquid Glass"
            detail.removeFirst()
        case "bar": owner = "Bar"
        case "defaults": owner = "Every widget"
        case "popupDefaults": owner = "Popups"
        case "workspaceDefaults": owner = "Workspaces"
        case "tokens": owner = "Theme color"
        case "roles" where path.count > 1:
            owner = "\(friendly(path[1])) widgets"
            detail.removeFirst()
        case "widgets" where path.count > 1, "widgetOverrides" where path.count > 1:
            owner = names[path[1]] ?? path[1]
            detail.removeFirst()
        default: owner = friendly(path[0])
        }
        if path[0] == "widgets" { return "\(owner) · Added" }
        if path[0] == "widgetOverrides", detail == ["enabled"], case let .bool(shown) = change.value {
            return "\(owner) · \(shown ? "Shown" : "Hidden")"
        }
        detail.removeAll { $0 == "style" }
        return detail.isEmpty ? owner : "\(owner) · \(styleTitle(detail))"
    }

    @ViewBuilder private func changeValue(_ change: (path: [String], value: ConfigurationValue)) -> some View {
        let (path, value) = change
        let token: String? = if case let .string(text) = value, text.hasPrefix("@token.") { String(text.dropFirst(7)) } else { nil }
        if path[0] == "widgets" || (path[0] == "widgetOverrides" && path.count == 3 && path[2] == "enabled") {
            EmptyView()
        } else if let color = token.flatMap({ name in store.themeTokenColors.first { $0.name == name }?.color })
                    ?? (try? value.decoded(HexColor.self)) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 4).fill(color.color).frame(width: 14, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.gray.opacity(0.4)))
                Text(token.flatMap { name in themeTokens.first { $0.name == name }?.title } ?? String(format: "#%06X", color.light >> 8))
                if color.light != color.dark { Text("light/dark").foregroundStyle(.tertiary) }
            }
        } else if value.isGradient,
                  let fill = try? substituteConfigurationReferences(value, prefix: "@token.",
                      values: store.effectiveDocument["tokens"]?.decoded([String: ConfigurationValue].self) ?? [:]).decoded(BackgroundFill.self) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 4).fill(fill.shapeStyle).frame(width: 14, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.gray.opacity(0.4)))
                Text("Gradient")
            }
        } else {
            Text(valueText(path, value))
        }
    }

    private func valueText(_ path: [String], _ value: ConfigurationValue) -> String {
        switch value {
        case let .number(number):
            let points = path.last!.range(of: "size|width|height|radius|padding|spacing|inset|margin|offset",
                                          options: [.regularExpression, .caseInsensitive]) != nil
            return number.formatted() + (points ? " pt" : "")
        case let .object(object) where object["gradient"] != nil: return "Gradient"
        case let .object(object) where path == ["theme"]:
            if case let .string(id) = object["id"] { return friendly(id) }
            return value.sourceDescription
        case .null: return "None"
        case let .string(string): return string
        default: return value.sourceDescription
        }
    }

    private func remove(_ change: (path: [String], value: ConfigurationValue), from profile: ConfigurationProfile) {
        if change.path[0] == "widgets", case let .array(widgets) = profile.configuration["widgets"] {
            var configuration = profile.configuration
            configuration["widgets"] = .array(widgets.filter { widget in
                if case let .object(definition) = widget { return definition["id"] != .string(change.path[1]) }
                return true
            })
            editor.setProfileConfiguration(name: profile.name, configuration: configuration)
        } else {
            let mask = change.path.reversed().reduce(ConfigurationValue.null) { .object([$1: $0]) }
            editor.change(ConfigurationEdit(action: .unset, properties: [
                "profiles": .object([profile.name: .object(["configuration": mask])])
            ]))
        }
    }
}

private struct ProfileCondition: Identifiable {
    let id: String
    let text: String
    let phrase: String
    let remove: () -> Void
}
