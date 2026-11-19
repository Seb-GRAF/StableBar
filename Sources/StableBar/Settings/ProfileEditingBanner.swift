import SwiftUI

struct ProfileEditingBanner: View {
    let editor: ConfigurationEditor

    var body: some View {
        if let name = editor.editingProfile {
            HStack(spacing: 8) {
                Image(systemName: "pencil").foregroundStyle(SettingsPalette.profile)
                Text("Editing for profile **\(name)**. What you change now applies only while it’s active.")
                Spacer()
                Button("Done") { editor.showProfile(name) }
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(SettingsPalette.profileSoft, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(SettingsPalette.profile))
        }
    }
}

struct ProfilePicker: View {
    let editor: ConfigurationEditor

    var body: some View {
        let name = editor.editingProfile
        Menu {
            Picker("Profile", selection: Binding(get: { name ?? "" }, set: {
                if $0 != (name ?? "") { $0.isEmpty ? editor.endProfileEditing() : editor.editBar(for: $0) }
            })) {
                Text("No profile").tag("")
                ForEach(editor.store.profiles, id: \.name) { Text($0.name).tag($0.name) }
            }
            .pickerStyle(.inline)
        } label: {
            Text(name.map { "Profile: \($0)" } ?? "No profile")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }
}
