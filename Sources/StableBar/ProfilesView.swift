import SwiftUI

struct ProfilesView: View {
    @Bindable var editor: ConfigurationEditor
    @State private var newName = ""
    @State private var configuration = "{}"
    @State private var technical = false

    private var store: BarStore { editor.store }
    private var selected: ConfigurationProfile? { store.profiles.first { $0.name == editor.selectedProfileName } }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Matching", selection: Binding(get: { store.pinnedProfile }, set: {
                if $0 != store.pinnedProfile { editor.change(ConfigurationEdit(action: .profile, name: $0)) }
            })) {
                Text("Automatic").tag(Optional<String>.none)
                ForEach(store.profiles, id: \.name) { profile in
                    Text("Pinned: \(profile.name)").tag(Optional(profile.name))
                }
            }
            .padding(12)
            VStack(alignment: .leading, spacing: 4) {
                Text("Active profiles: \(store.activeProfiles.isEmpty ? "None" : store.activeProfiles.joined(separator: " → "))")
                    .font(.callout)
                Text("Applied from left to right. Later profiles override earlier ones; disabled profiles never apply.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $editor.selectedProfileName) {
                        ForEach(store.profiles, id: \.name) { profile in
                            let conditions = profile.when
                            let parts = [conditions?.appearance?.capitalized,
                                         conditions?.onBattery.map { $0 ? "Battery" : "Power adapter" },
                                         conditions?.displayCount.map { "\($0) display(s)" },
                                         conditions?.externalDisplay.map { $0 ? "External display" : "No external display" },
                                         conditions?.app].compactMap { $0 }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(profile.name)
                                    Spacer()
                                    if let index = store.activeProfiles.firstIndex(of: profile.name) {
                                        Text("\(index + 1) · Active")
                                            .font(.caption)
                                            .foregroundStyle(Color.accentColor)
                                    } else {
                                        Text(profile.enabled ? "Not active" : "Disabled")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text(parts.isEmpty ? "Always matches" : parts.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                            .tag(profile.name)
                        }
                    }
                    .listStyle(.sidebar)
                    Divider()
                    HStack {
                        TextField("New profile name", text: $newName)
                        Button("Add", systemImage: "plus") {
                            editor.addProfile(name: newName)
                            if editor.error == nil { editor.selectedProfileName = newName; newName = "" }
                        }
                        .labelStyle(.iconOnly)
                        .disabled(newName.isEmpty || store.profiles.contains { $0.name == newName })
                    }
                    .padding(10)
                }
                .frame(minWidth: 230, maxWidth: 300)
                Group {
                    if let selected {
                        settings(selected)
                    } else {
                        ContentUnavailableView("Select a profile", systemImage: "slider.horizontal.3",
                                               description: Text("Choose a profile to edit its conditions, or add one."))
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: selected, initial: true) {
            configuration = (try? String(decoding: configurationData(selected?.configuration ?? [:]), as: UTF8.self)) ?? "{}"
        }
        .onChange(of: editor.selectedProfileName) { technical = false }
    }

    private func settings(_ profile: ConfigurationProfile) -> some View {
        Form {
            Section(profile.name) {
                Toggle("Enabled", isOn: Binding(get: { profile.enabled }, set: {
                    var edited = profile
                    edited.enabled = $0
                    editor.setProfile(edited)
                }))
                Text("All conditions must match in Automatic mode. A pinned profile ignores its conditions.")
                    .foregroundStyle(.secondary)
            }
            Section("Conditions") {
                Picker("Appearance", selection: condition(profile, \.appearance, control: "appearance")) {
                    Text("Any").tag(Optional<String>.none)
                    Text("Light").tag(Optional("light"))
                    Text("Dark").tag(Optional("dark"))
                }
                Picker("Power", selection: condition(profile, \.onBattery, control: "onBattery")) {
                    Text("Any").tag(Optional<Bool>.none)
                    Text("Battery").tag(Optional(true))
                    Text("Power adapter").tag(Optional(false))
                }
                TextField("Display count", value: condition(profile, \.displayCount, control: "displayCount"), format: .number, prompt: Text("Any"))
                Picker("External display", selection: condition(profile, \.externalDisplay, control: "externalDisplay")) {
                    Text("Any").tag(Optional<Bool>.none)
                    Text("Connected").tag(Optional(true))
                    Text("Disconnected").tag(Optional(false))
                }
                TextField("Focused app", text: Binding(get: { profile.when?.app ?? "" }, set: {
                    condition(profile, \.app, control: "app").wrappedValue = $0.isEmpty ? nil : $0
                }), prompt: Text("Any, or a bundle identifier"))
            }
            Section {
                number("Bar height", section: "bar", key: "height", profile: profile, fallback: store.configuration?.bar.height ?? 40)
                number("Offset from top", section: "bar", key: "offset", profile: profile, fallback: store.configuration?.bar.offset ?? 0)
                let bar = (try? profile.configuration["bar"]?.decoded([String: ConfigurationValue].self)) ?? [:]
                let appearance: String = if case let .string(value) = bar["appearance"] { value }
                    else if bar["appearance"] == .null { "automatic" }
                    else { "unchanged" }
                Picker("Bar appearance", selection: Binding(get: { appearance }, set: {
                    setProfileValue($0 == "automatic" ? .null : .string($0), section: "bar", key: "appearance", profile: profile)
                })) {
                    if appearance == "unchanged" { Text("Not set by this profile").tag("unchanged") }
                    Text("Automatic").tag("automatic")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                number("Default widget font size", section: "defaults", key: "fontSize", profile: profile,
                       fallback: store.configuration?.defaults.fontSize ?? 12)
            } header: {
                Text("Common settings")
            } footer: {
                Text("Only fields you change are saved in this profile. Unset number fields show the current bar's value. Automatic follows macOS even when your base appearance is Light or Dark.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let other = otherSettings(profile)
            if !other.isEmpty {
                Section("Other settings") {
                    Text("This profile also configures: \(other.joined(separator: ", ")).")
                    Text("Edit these settings in Technical details. Changing a common setting keeps them intact.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                DisclosureGroup("Technical details", isExpanded: $technical) {
                    Text("All settings applied by this profile, as JSON. Apply after editing. Omitted inherited properties become null overrides; use the main configuration file to remove an override completely.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $configuration)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 160)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    Button("Apply configuration") {
                        do {
                            editor.setProfileConfiguration(name: profile.name, configuration:
                                try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(configuration.utf8)))
                        } catch { editor.error = errorMessage(error) }
                    }
                    Text("Edits are saved in the main configuration file; included files stay unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func number(_ title: String, section: String, key: String, profile: ConfigurationProfile, fallback: Double) -> some View {
        let values = (try? profile.configuration[section]?.decoded([String: ConfigurationValue].self)) ?? [:]
        let property = values[key]
        let value = if case let .number(number) = property { number } else { fallback }
        return LabeledContent {
            TextField(title, value: Binding(get: { value }, set: {
                if property != .number($0) { setProfileValue(.number($0), section: section, key: key, profile: profile) }
            }), format: .number)
                .labelsHidden().multilineTextAlignment(.trailing).frame(width: 70)
            Text("pt").foregroundStyle(.secondary)
        } label: {
            Text(title)
            Text(property.map { "Profile value: \($0.sourceDescription)" } ?? "Not set by this profile")
        }
    }

    private func setProfileValue(_ value: ConfigurationValue, section: String, key: String, profile: ConfigurationProfile) {
        var configuration = profile.configuration
        configuration[section] = .object([key: value]).overriding(configuration[section] ?? .object([:]))
        editor.setProfileConfiguration(name: profile.name, configuration: configuration)
    }

    private func otherSettings(_ profile: ConfigurationProfile) -> [String] {
        var settings = profile.configuration
        for (section, keys) in [("bar", ["height", "offset", "appearance"]), ("defaults", ["fontSize"])] {
            if case var .object(values) = settings[section] {
                for key in keys { values[key] = nil }
                if values.isEmpty { settings[section] = nil }
            }
        }
        return settings.keys.sorted()
    }

    private func condition<Value: Equatable>(_ profile: ConfigurationProfile, _ key: WritableKeyPath<ProfileConditions, Value?>, control: String) -> Binding<Value?> {
        Binding(get: { profile.when?[keyPath: key] }, set: { value in
            guard value != profile.when?[keyPath: key] else { return }
            editor.setProfileCondition(profile.name, key, value: value, control: control)
        })
    }
}
