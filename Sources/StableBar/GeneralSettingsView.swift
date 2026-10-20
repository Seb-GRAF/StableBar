import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    let editor: ConfigurationEditor
    @State private var aboutExpanded = false
    private var store: BarStore { editor.store }

    var body: some View {
        ScrollViewReader { scroll in
            Form {
                Section("General") {
                    LoginItemSettings()
                }
                .id(SettingsSearchResult.login.id)
                Section {
                    let bar = StyleFields(store: store, path: "bar",
                        values: (try? store.effectiveDocument["bar"]?.decoded([String: ConfigurationValue].self)) ?? [:],
                        set: { editor.change(ConfigurationEdit(action: .bar, properties: $0)) },
                        unset: { editor.change(ConfigurationEdit(action: .unset, properties: ["bar": .object($0)])) })
                    bar.number("Offset from top", "offset", default: 0)
                    bar.number("Margin", "margin", default: 0)
                    scale("Built-in display scale", key: "builtIn")
                    scale("External display scale", key: "external")
                    bar.toggle("Keep windows clear of StableBar", "keepWindowsClear", default: false)
                    bar.toggle("Keep notifications clear of StableBar", "keepNotificationsClear", default: false)
                } header: {
                    Text("Displays and placement")
                } footer: {
                    Text("Window clearance moves and resizes ordinary windows below the bar. Fullscreen windows stay unchanged. Leave it off when AeroSpace or yabai manages window gaps. Notification clearance requires macOS 26.")
                }
                .id(SettingsSearchResult.placement.id)
                Section("Access") {
                    let permissions = requiredPermissions
                    if permissions.isEmpty {
                        Text("Your current widgets do not need additional access.").foregroundStyle(.secondary)
                    } else {
                        SourcePermissionList(permissions: permissions)
                    }
                }
                .id(SettingsSearchResult.access.id)
                Section("Workspace connection") {
                    Picker("Source", selection: Binding(get: { store.configuration?.workspaceSource ?? .aerospace }, set: {
                        editor.change(ConfigurationEdit(action: .workspaceSource, name: $0.rawValue))
                    })) {
                        Text("AeroSpace").tag(WorkspaceSource.aerospace)
                        Text("yabai").tag(WorkspaceSource.yabai)
                    }
                    HStack {
                        Text("The workspace manager must be installed and configured separately.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reconnect", action: store.workspaceStore.reconnect)
                    }
                    if let error = store.workspaceStore.error {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .id(SettingsSearchResult.connections.id)
                Section {
                    LabeledContent("File") {
                        Text(store.configurationURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    HStack {
                        Button("Open File", action: store.openConfiguration)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.configurationURL]) }
                        Spacer()
                        Button("Reload", action: store.reloadConfiguration)
                    }
                } header: {
                    Text("Configuration")
                } footer: {
                    Text("Saved file changes apply automatically. Customize writes to your main configuration; imported files stay intact. Temporary command-line changes have their own Save and Discard actions.")
                }
                .id(SettingsSearchResult.configuration.id)
                Section("Getting started") {
                    Text("Select a widget in Your bar to change its content, appearance and behavior. Arrange on desktop moves widgets directly on the bar. Undo reverses saved edits.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Set Up StableBar…") { NSApp.sendAction(#selector(AppDelegate.showSetup), to: NSApp.delegate, from: nil) }
                        Link("User guide", destination: URL(string: "https://github.com/Seb-GRAF/StableBar#readme")!)
                    }
                }
                .id(SettingsSearchResult.help.id)
                Section {
                    DisclosureGroup("About and updates", isExpanded: $aboutExpanded) {
                        AboutView(update: store.update).sections
                    }
                }
                .id(SettingsSearchResult.updates.id)
            }
            .formStyle(.grouped)
            .task(id: editor.searchTarget) {
                if let target = editor.searchTarget {
                    if target == SettingsSearchResult.updates.id { aboutExpanded = true }
                    await Task.yield()
                    if Task.isCancelled { return }
                    scroll.scrollTo(target, anchor: .top)
                    editor.searchTarget = nil
                }
            }
        }
    }

    private var requiredPermissions: [SourcePermission] {
        var permissions = store.registry.permissions(for: store.configuration)
        if store.configuration?.bar.keepWindowsClear == true || store.configuration?.bar.keepNotificationsClear == true {
            permissions.removeAll { $0.privacyPane == SourcePermission.accessibility.privacyPane }
            permissions.append(SourcePermission(title: "Accessibility",
                detail: "StableBar needs access to move windows and notifications clear of the bar, and to show app menus.",
                symbol: "accessibility", privacyPane: "Privacy_Accessibility"))
        }
        return permissions
    }

    private func scale(_ title: String, key: String) -> some View {
        let values = store.configuration?.bar.displayScale.mapValues(ConfigurationValue.number) ?? [:]
        let property = store.propertySources(path: "bar.displayScale", key: key, values: values)
        let value = if case let .number(value) = property.editingValue { value } else { 1.0 }
        let binding = Binding(get: { value }, set: { scale in
            if scale != value {
                editor.change(ConfigurationEdit(action: .bar, properties: ["displayScale": .object([key: .number(scale)])]))
            }
        })
        return OverrideRow(title: title, source: store.propertySourceText(property),
            reset: property.saved.map { source in {
                do { try store.removePropertySource(source) }
                catch { store.customizationHistory.error = errorMessage(error) }
            } },
            sourceDetails: PropertySourceView(store: store, title: title, property: property)) {
                TextField(title, value: binding, format: .number)
                    .labelsHidden().frame(width: 60).multilineTextAlignment(.trailing)
                Text("×").foregroundStyle(.secondary)
                Stepper(title, value: binding, in: 0.25...3, step: 0.05).labelsHidden()
            }
    }
}
