import SwiftUI

struct ProfilesView: View {
    let editor: ConfigurationEditor
    @State private var selectedName: String?
    @State private var newName = ""
    @State private var configuration = "{}"

    private var store: BarStore { editor.store }
    private var selected: ConfigurationProfile? { store.profiles.first { $0.name == selectedName } }

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
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $selectedName) {
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
                                    if store.activeProfiles.contains(profile.name) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.accentColor)
                                            .help("Active")
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
                            if editor.error == nil { selectedName = newName; newName = "" }
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
            Section("Configuration") {
                Text("Settings applied by this profile, as JSON. For example: {\"bar\": {\"height\": 36}}.")
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
        .formStyle(.grouped)
    }

    private func condition<Value: Equatable>(_ profile: ConfigurationProfile, _ key: WritableKeyPath<ProfileConditions, Value?>, control: String) -> Binding<Value?> {
        Binding(get: { profile.when?[keyPath: key] }, set: { value in
            guard value != profile.when?[keyPath: key] else { return }
            editor.setProfileCondition(profile.name, key, value: value, control: control)
        })
    }
}
