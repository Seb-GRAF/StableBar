import SwiftUI

struct ProfilesView: View {
    @Bindable var editor: ConfigurationEditor
    @State private var newName = ""

    private var store: BarStore { editor.store }
    private var selected: ConfigurationProfile? { store.profiles.first { $0.name == editor.selectedProfileName } }

    /// Profiles that apply together because the file predates choosing one profile at a time.
    private var combined: [String] {
        guard store.pinnedProfile == nil else { return [] }
        let active = store.profiles.filter { store.activeProfiles.contains($0.name) }
        return active.count > 1 || active.contains { $0.when == nil } ? active.map(\.name) : []
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Profile", selection: Binding(get: { store.pinnedProfile ?? "automatic" }, set: { store.chooseProfile($0) })) {
                ForEach(store.profileChoices, id: \.self) { Text(profileTitle($0)).tag($0) }
            }
            .padding(12)
            VStack(alignment: .leading, spacing: 4) {
                Text("On the bar: \(store.activeProfiles.isEmpty ? "Default" : store.activeProfiles.joined(separator: " + "))")
                    .font(.callout)
                Text(combined.isEmpty
                     ? "One profile applies at a time. Switch automatically uses the first profile in the list whose conditions all match, or Default when none do."
                     : "\(combined.count == 1 ? "\(combined[0]) always applies" : "\(combined.joined(separator: ", ")) apply together") because this configuration has no saved profile choice. Choose a profile to use one at a time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $editor.selectedProfileName) {
                        row("Default", detail: "Your main configuration", active: store.activeProfiles.isEmpty)
                            .tag("Default")
                        ForEach(store.profiles, id: \.name) { profile in
                            let conditions = profile.when
                            let parts = [conditions?.appearance?.capitalized,
                                         conditions?.onBattery.map { $0 ? "Battery" : "Power adapter" },
                                         conditions?.displayCount.map { "\($0) display(s)" },
                                         conditions?.externalDisplay.map { $0 ? "External display" : "No external display" },
                                         conditions?.app].compactMap { $0 }
                            row(profile.name, detail: profile.enabled ? (parts.isEmpty ? "Manual" : parts.joined(separator: " · ")) : "Disabled",
                                active: store.activeProfiles.contains(profile.name))
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
                        .disabled(newName.isEmpty || store.profileChoices.contains(newName) || store.profiles.contains { $0.name == newName })
                    }
                    .padding(10)
                }
                .frame(minWidth: 230, maxWidth: 300)
                Group {
                    if let selected {
                        settings(selected)
                    } else {
                        defaultSettings
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func row(_ name: String, detail: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name)
                Spacer()
                if active { Text("On the bar").font(.caption).foregroundStyle(Color.accentColor) }
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var defaultSettings: some View {
        Form {
            Section("Default") {
                Text("Default is your main configuration. Other profiles start from it and save only what they change, so a widget you add to Default appears in every profile that doesn't hide it.")
                    .foregroundStyle(.secondary)
                Button("Edit Default") { edit("Default") }
            }
        }
        .formStyle(.grouped)
    }

    private func settings(_ profile: ConfigurationProfile) -> some View {
        Form {
            Section(profile.name) {
                Text("Your bar, Appearance and Settings change this profile while it is on the bar. Values it doesn't change come from Default.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Edit \(profile.name)") { edit(profile.name) }
                    Spacer()
                    Button("Delete Profile", role: .destructive) { editor.deleteProfile(profile.name) }
                }
                Toggle("Enabled", isOn: Binding(get: { profile.enabled }, set: {
                    var edited = profile
                    edited.enabled = $0
                    editor.setProfile(edited)
                }))
            }
            Section {
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
            } header: {
                Text("Switch automatically when")
            } footer: {
                Text("All conditions must match. A profile without conditions is only used when you choose it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func edit(_ name: String) {
        store.previewProfile(name)
        editor.section = .widgets
    }

    private func condition<Value: Equatable>(_ profile: ConfigurationProfile, _ key: WritableKeyPath<ProfileConditions, Value?>, control: String) -> Binding<Value?> {
        Binding(get: { profile.when?[keyPath: key] }, set: { value in
            guard value != profile.when?[keyPath: key] else { return }
            editor.setProfileCondition(profile.name, key, value: value, control: control)
        })
    }
}

func profileTitle(_ choice: String) -> String {
    choice == "automatic" ? "Switch automatically" : choice
}
