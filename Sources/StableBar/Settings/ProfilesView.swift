import AppKit
import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

struct ProfilesView: View {
    @Bindable var editor: ConfigurationEditor
    @State private var naming = false
    @State private var newName = ""
    @State private var editingJSON = false
    @State private var hovered: String?
    @State private var deleting: String?
    @State private var themeOptions: [ProfileThemeOption] = []
    @State private var network: String?
    @State private var locationAccess = false
    /// Reads the Wi-Fi network, camera and microphone for every profile while the page shows: the bar reads them only
    /// for profiles that are turned on.
    @State private var liveWatch: SystemContext?
    @State private var live = ConfigurationContext()
    @Environment(\.offline) private var offline

    private var store: BarStore { editor.store }
    private var selected: ConfigurationProfile? {
        let groups = ProfileGroups(store: store)
        let listed = groups.yours + groups.themeEdits + groups.elsewhere.map(\.profile)
        return listed.first { $0.name == editor.selectedProfileName } ?? listed.first
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
        .task {
            let catalog = ThemeCatalog(packages: store.configurationStore.configurationURL.deletingLastPathComponent().appending(path: "packages"),
                                       themesDirectory: store.configurationStore.themesDirectory)
            themeOptions = await Task.detached { catalog.profileThemeOptions }.value
            if !offline {
                network = SystemContext.wifiNetwork()
                locationAccess = CLLocationManager().authorizationStatus == .authorizedAlways
            }
        }
        .onAppear {
            guard !offline else { return }
            live = SystemContext.current(checking: store.profiles)
            liveWatch = SystemContext { [store] in
                live = SystemContext.current(checking: store.profiles)
                network = SystemContext.wifiNetwork()
            }
            liveWatch?.watch(store.profiles)
        }
        .onChange(of: store.profiles) { liveWatch?.watch(store.profiles) }
        .onDisappear {
            liveWatch?.stop()
            liveWatch = nil
        }
    }

    private var list: some View {
        let groups = ProfileGroups(store: store)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Profiles change your bar in some situations. To choose what each screen shows, use [Bar](settings:bar).")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 12, leading: 12, bottom: 6, trailing: 12))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !groups.yours.isEmpty {
                        listGroup("Yours") {
                            ForEach(groups.yours, id: \.name) { card($0) }
                            Text("When several match, the lower one wins.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .padding(4)
                        }
                    }
                    if !groups.themeEdits.isEmpty {
                        listGroup("Theme edits") {
                            ForEach(groups.themeEdits, id: \.name) { themeEditsCard($0) }
                        }
                    }
                    if !groups.elsewhere.isEmpty {
                        listGroup("From packages and themes") {
                            ForEach(groups.elsewhere, id: \.profile.name) { card($0.profile, from: sourceName($0.file)) }
                        }
                    }
                }
                .padding(EdgeInsets(top: 6, leading: 8, bottom: 10, trailing: 8))
            }
            Divider()
            Button("New profile", systemImage: "plus") { naming = true }
                .popover(isPresented: $naming, arrowEdge: .top) { newProfile }
                .padding(8)
        }
    }

    private func listGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            content()
        }
    }

    private func card(_ profile: ConfigurationProfile, from source: String? = nil) -> some View {
        let count = changes(profile.configuration).count
        return listCard(profile) {
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
            if let source {
                Text("From \(source)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// A profile's card in the list: a click selects it.
    private func listCard(_ profile: ConfigurationProfile, @ViewBuilder content: () -> some View) -> some View {
        let isSelected = profile.name == selected?.name
        return VStack(alignment: .leading, spacing: 3, content: content)
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

    private func themeEditsCard(_ profile: ConfigurationProfile) -> some View {
        let main = (try? store.configurationStore.editedMainDocument(replaying: store.configurationStore.customizationEdits)) ?? [:]
        let count = ThemeEdits(main: main, themeID: profile.when!.onlyTheme!).changes.count
        return listCard(profile) {
            HStack(spacing: 6) {
                Text(profile.name).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 0)
                Button("Edit in Theme") { editor.section = .appearance }
                    .controlSize(.small)
            }
            Text("\(sentence(profile)) · \(count) \(count == 1 ? "change" : "changes")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func sourceName(_ file: String) -> String {
        let loader = store.configurationStore.configurationLoader
        guard let name = loader.packageNames[file] else { return URL(filePath: file).lastPathComponent }
        return themeOptions.contains { $0.id == loader.packageIDs[file] } ? "the \(name) theme" : name
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
        let unmet = conditions(profile).filter { !$0.met }.map(\.phrase)
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
                         : !profile.enabled ? "Turned off"
                         : unmet.isEmpty ? "Waiting for its conditions" : "Waiting until " + unmet.joined(separator: " and "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                enabledToggle(profile)
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 10, trailing: 16))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    group("When") { conditionRows(profile) }
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

    private var context: ConfigurationContext {
        var context = store.profileContext
        context.app = store.configurationStore.context.app
        context.displays = store.configurationStore.context.displays
        context.wifi = live.wifi
        context.camera = live.camera
        context.microphone = live.microphone
        return context
    }

    @ViewBuilder private func conditionRows(_ profile: ConfigurationProfile) -> some View {
        let conditions = self.conditions(profile)
        ForEach(Array(conditions.enumerated()), id: \.element.id) { index, condition in
            HStack(spacing: 10) {
                Image(systemName: condition.met ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(condition.met ? SettingsPalette.success : .secondary)
                Text(condition.kind)
                Text(condition.met ? "True now" : "Not true now").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Menu(condition.value) {
                    ForEach(Array(condition.choices.enumerated()), id: \.offset) { _, choice in
                        Toggle(choice.title, isOn: Binding(get: { choice.isOn }, set: { _ in choice.choose() }))
                    }
                }
                .fixedSize()
                Button(action: condition.remove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove this condition")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(minHeight: 38)
            .overlay(alignment: .top) {
                if index > 0 { Rectangle().fill(SettingsPalette.separator).frame(height: 1) }
            }
        }
        HStack(spacing: 10) {
            if conditions.isEmpty { Text("Always").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            addCondition(profile)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .overlay(alignment: .top) {
            if !conditions.isEmpty { Rectangle().fill(SettingsPalette.separator).frame(height: 1) }
        }
    }

    private func addCondition(_ profile: ConfigurationProfile) -> some View {
        let when = profile.when ?? ProfileConditions()
        let context = self.context
        let name = profile.name
        return Menu {
            Section("Appearance") {
                Button("Light or Dark Mode") {
                    editor.setProfileCondition(name, \.appearance, value: context.appearance, control: "appearance")
                }
                .disabled(when.appearance != nil)
            }
            Section("Power") {
                Button("On battery or power adapter") {
                    editor.setProfileCondition(name, \.onBattery, value: context.onBattery, control: "onBattery")
                }
                .disabled(when.onBattery != nil)
            }
            Section("Screens") {
                Button("Number of screens") {
                    editor.setProfileCondition(name, \.displayCount, value: context.displayCount, control: "displayCount")
                }
                .disabled(when.displayCount != nil)
                Button("Any monitor") {
                    editor.setProfileCondition(name, \.externalDisplay, value: context.externalDisplay, control: "externalDisplay")
                }
                .disabled(when.externalDisplay != nil)
                Menu("A monitor by name") {
                    ForEach(Set(context.displays).sorted(), id: \.self) { display in
                        Button(display) { editor.setProfileCondition(name, \.display, value: display, control: "display") }
                    }
                }
                .disabled(when.display != nil)
            }
            Section("Network") {
                Button(network.map { "Wi-Fi network: \($0)" } ?? (locationAccess ? "Wi-Fi network: not connected" : "Wi-Fi network: needs Location access")) {
                    editor.setProfileCondition(name, \.wifi, value: network, control: "wifi")
                }
                .disabled(network == nil || when.wifi != nil)
            }
            Section("Calls") {
                Button("Camera in use") { editor.setProfileCondition(name, \.camera, value: true, control: "camera") }
                    .disabled(when.camera != nil)
                Button("Microphone in use") { editor.setProfileCondition(name, \.microphone, value: true, control: "microphone") }
                    .disabled(when.microphone != nil)
            }
            Section("Apps") {
                Button("An app is in front…") { chooseApp(for: profile) }
                    .disabled(when.appList != nil)
            }
            Section("Theme") {
                Menu("The theme is…") {
                    ForEach(themeOptions, id: \.id) { option in
                        Button(option.name) { editor.setProfileCondition(name, \.theme, value: option.id, control: "theme") }
                    }
                }
                .disabled(when.theme != nil)
            }
        } label: {
            Label("Condition", systemImage: "plus")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .fixedSize()
    }

    private func sentence(_ profile: ConfigurationProfile) -> String {
        let conditions = self.conditions(profile)
        return conditions.isEmpty ? "Always" : "When " + conditions.map(\.phrase).joined(separator: " and ")
    }

    private func conditions(_ profile: ConfigurationProfile) -> [ProfileCondition] {
        let when = profile.when ?? ProfileConditions()
        let unmet = when.unmet(in: context)
        let name = profile.name
        func condition<Value: Equatable>(_ key: WritableKeyPath<ProfileConditions, Value?>, _ id: ProfileConditions.CodingKeys,
                                         _ kind: String, _ value: String, _ phrase: String,
                                         _ choices: [(title: String, value: Value)]) -> ProfileCondition {
            ProfileCondition(id: id, kind: kind, value: value, phrase: phrase, met: !unmet.contains(id), choices: choices.map { choice in
                ProfileCondition.Choice(title: choice.title, isOn: when[keyPath: key] == choice.value) {
                    editor.setProfileCondition(name, key, value: choice.value, control: id.rawValue)
                }
            }) {
                editor.setProfileCondition(name, key, value: nil, control: id.rawValue)
            }
        }
        var conditions: [ProfileCondition] = []
        if let appearance = when.appearance {
            conditions.append(condition(\.appearance, .appearance, "Appearance", appearance == "dark" ? "Dark" : "Light",
                                        appearance == "dark" ? "Dark Mode is on" : "Light Mode is on",
                                        [("Light", "light"), ("Dark", "dark")]))
        }
        if let battery = when.onBattery {
            conditions.append(condition(\.onBattery, .onBattery, "Power", battery ? "On battery" : "On power adapter",
                                        battery ? "on battery" : "on power adapter", [("On battery", true), ("On power adapter", false)]))
        }
        if let count = when.displayCount {
            conditions.append(condition(\.displayCount, .displayCount, "Screens", "\(count)", screenCount(count),
                                        (1...9).map { ("\($0)", $0) }))
        }
        if let external = when.externalDisplay {
            conditions.append(condition(\.externalDisplay, .externalDisplay, "Monitors",
                                        external ? "A monitor is connected" : "Only the laptop screen",
                                        external ? "a monitor is connected" : "only the laptop screen is connected",
                                        [("A monitor is connected", true), ("Only the laptop screen", false)]))
        }
        if let display = when.display {
            conditions.append(condition(\.display, .display, "Monitor", display, "\(display) is connected",
                                        Set(context.displays + [display]).sorted().map { ($0, $0) }))
        }
        if let wifi = when.wifi {
            conditions.append(condition(\.wifi, .wifi, "Wi-Fi network", wifi, "the Wi-Fi network is \(wifi)",
                                        Set([wifi] + [network].compactMap { $0 }).sorted().map { ($0, $0) }))
        }
        if let camera = when.camera {
            conditions.append(condition(\.camera, .camera, "Camera", camera ? "In use" : "Not in use",
                                        camera ? "the camera is in use" : "the camera isn't in use", [("In use", true), ("Not in use", false)]))
        }
        if let microphone = when.microphone {
            conditions.append(condition(\.microphone, .microphone, "Microphone", microphone ? "In use" : "Not in use",
                                        microphone ? "the microphone is in use" : "the microphone isn't in use",
                                        [("In use", true), ("Not in use", false)]))
        }
        if let apps = when.appList {
            let names = apps.map { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.deletingPathExtension().lastPathComponent ?? $0 }
            let choices = zip(apps, names).map { app, title in
                ProfileCondition.Choice(title: title, isOn: true) {
                    editor.setProfileCondition(name, \.appList, value: apps.filter { $0 != app }, control: "app")
                }
            } + [ProfileCondition.Choice(title: "Add an app…", isOn: false) { chooseApp(for: profile) }]
            conditions.append(ProfileCondition(id: .app, kind: apps.count == 1 ? "App in front" : "Apps in front",
                                               value: names.joined(separator: ", "), phrase: "\(names.joined(separator: " or ")) is in front",
                                               met: !unmet.contains(.app) && !unmet.contains(.apps), choices: choices) {
                editor.setProfileCondition(name, \.appList, value: nil, control: "app")
            })
        }
        if let theme = when.theme {
            let themeName = themeOptions.first { $0.id == theme }?.name ?? theme
            conditions.append(condition(\.theme, .theme, "Theme", themeName, "\(themeName) is the theme",
                                        themeOptions.map { ($0.name, $0.id) }))
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
        let apps = profile.when?.appList ?? []
        if panel.runModal() == .OK, let url = panel.url, let identifier = Bundle(url: url)?.bundleIdentifier, !apps.contains(identifier) {
            editor.setProfileCondition(profile.name, \.appList, value: apps + [identifier], control: "app")
        }
    }

    @ViewBuilder private func changeRows(_ profile: ConfigurationProfile) -> some View {
        let changes = self.changes(profile.configuration)
        let main = try? store.configurationStore.editedMainDocument(replaying: store.configurationStore.customizationEdits)["profiles"]?
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
               changeColor(value) == nil {
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
        case "groupDefaults": owner = "Every group"
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
        } else if let color = changeColor(value) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 4).fill(color.color).frame(width: 14, height: 14)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.gray.opacity(0.4)))
                Text(token.flatMap { name in store.themeTokenColors.first { $0.name == name }?.title } ?? String(format: "#%06X", color.light >> 8))
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

    /// The color a change sets, with theme colors substituted first: a side of a light and dark pair can name one.
    private func changeColor(_ value: ConfigurationValue) -> HexColor? {
        try? substituteConfigurationReferences(value, prefix: "@token.",
            values: store.effectiveDocument["tokens"]?.decoded([String: ConfigurationValue].self) ?? [:]).decoded(HexColor.self)
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

struct ProfileGroups {
    var yours: [ConfigurationProfile] = []
    var themeEdits: [ConfigurationProfile] = []
    var elsewhere: [(profile: ConfigurationProfile, file: String)] = []

    @MainActor init(store: BarStore) {
        let main = store.configurationStore.configurationURL.standardizedFileURL.path
        for profile in store.profiles {
            if let file = store.contributions["profiles.\(profile.name).name"]?.map(\.origin.file).first(where: { $0 != main }) {
                elsewhere.append((profile, file))
            } else if profile.when?.onlyTheme != nil {
                themeEdits.append(profile)
            } else {
                yours.append(profile)
            }
        }
    }
}

private struct ProfileCondition: Identifiable {
    let id: ProfileConditions.CodingKeys
    /// What it checks, such as Power, and its value, such as On battery.
    let kind: String
    let value: String
    let phrase: String
    /// Whether it's true now.
    let met: Bool
    let choices: [Choice]
    let remove: () -> Void

    struct Choice {
        let title: String
        let isOn: Bool
        let choose: () -> Void
    }
}
