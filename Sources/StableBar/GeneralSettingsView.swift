import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var macOSVersion = MacOSVersion()
}

struct GeneralSettingsView: View {
    let editor: ConfigurationEditor
    private var store: BarStore { editor.store }
    @Environment(\.macOSVersion) private var macOSVersion
    /// Observed, so the reminder to finish setup updates while Settings is open.
    @AppStorage(SetupProgress.skippedKey) private var setupSkipped = false
    @AppStorage(SetupProgress.completedKey) private var setupCompleted = false

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(spacing: 0) {
                    SettingsGroup("Startup") {
                        LoginItemSettings()
                    }
                    .id(SettingsSearchResult.login.id)
                    SettingsGroup("Native menu bar") {
                        let bar = StyleFields(store: store, path: "bar",
                            values: (try? store.effectiveDocument["bar"]?.decoded([String: ConfigurationValue].self)) ?? [:],
                            set: { editor.change(ConfigurationEdit(action: .bar, properties: $0)) },
                            unset: { editor.change(ConfigurationEdit(action: .unset, properties: ["bar": .object($0)])) })
                        MenuBarAutoHideSettings()
                        bar.number("Reveal delay", "menuBarRevealDelay", default: 0, in: 0...10000, step: 100, unit: "ms",
                                   hint: "Wait at the top edge before showing the hidden macOS menu bar. 0 adds no delay. Requires Accessibility access.")
                        bar.toggle("Always hide", "hideMenuBar", default: false,
                                   hint: "Keep the macOS menu bar invisible while StableBar runs, even at the top edge.")
                    }
                    .id(SettingsSearchResult.menuBar.id)
                    SettingsGroup("Windows and notifications") {
                        let bar = StyleFields(store: store, path: "bar",
                            values: (try? store.effectiveDocument["bar"]?.decoded([String: ConfigurationValue].self)) ?? [:],
                            set: { editor.change(ConfigurationEdit(action: .bar, properties: $0)) },
                            unset: { editor.change(ConfigurationEdit(action: .unset, properties: ["bar": .object($0)])) })
                        bar.toggle("Keep windows clear of the bar", "keepWindowsClear", default: false,
                                   hint: "Moves ordinary windows below the bar. Leave it off when AeroSpace, yabai, OmniWM or Rift sets gaps.")
                        NotificationClearanceSettings(bar: bar, macOSVersion: macOSVersion)
                    }
                    .id(SettingsSearchResult.windows.id)
                    SettingsGroup("Hover") {
                        let bar = StyleFields(store: store, path: "bar",
                            values: (try? store.effectiveDocument["bar"]?.decoded([String: ConfigurationValue].self)) ?? [:],
                            set: { editor.change(ConfigurationEdit(action: .bar, properties: $0)) },
                            unset: { editor.change(ConfigurationEdit(action: .unset, properties: ["bar": .object($0)])) })
                        bar.number("Delay", "hoverDelay", default: 400, in: 0...2000, step: 50, unit: "ms",
                                   hint: "Wait before tooltips, hover controls and hover popups open. Once one shows, the next widget's opens at once.")
                        bar.toggle("Open hover controls inline", "inlineHoverControls", default: false,
                                   hint: "Hovering a slider widget, such as Sound, widens it in the bar instead of opening a tooltip.")
                    }
                    .id(SettingsSearchResult.hover.id)
                    SettingsGroup("Workspaces") {
                        let source = store.configuration?.workspaceSource ?? .aerospace
                        let path = shellEnvironment.withLock { $0["PATH", default: ""] }
                        let missing = [WorkspaceSource.aerospace, .yabai, .omniwm, .rift].filter { $0.executable(path: path) == nil }
                        SettingRow(title: "Workspace manager", hint: missing.isEmpty ? nil : "Not installed: \(missing.map(\.title).joined(separator: ", ")).") {
                            SettingsSegments(selection: Binding(get: { source }, set: {
                                if $0 != source { editor.change(ConfigurationEdit(action: .workspaceSource, name: $0.rawValue)) }
                            }), options: [(WorkspaceSource.aerospace, "AeroSpace"), (.yabai, "yabai"), (.omniwm, "OmniWM"), (.rift, "Rift"), (.spaces, "Spaces")],
                               disabled: missing, stretches: false)
                            .fixedSize()
                        }
                        if missing.contains(source) {
                            Label("\(source.title) isn't installed, so workspace widgets can't show its workspaces. Install it, or choose Spaces.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(SettingsPalette.warning)
                                .groupRow()
                        }
                        connection
                    }
                    .id(SettingsSearchResult.workspaces.id)
                    SettingsGroup("Access") {
                        if SetupProgress.offersToFinish(skipped: setupSkipped, completed: setupCompleted) {
                            SettingRow(title: "Finish setting up",
                                       hint: "You skipped setup. It sets up your widgets, theme and placement, and asks for the access your bar needs.") {
                                Button("Open setup…") { NSApp.sendAction(#selector(AppDelegate.showSetup), to: NSApp.delegate, from: nil) }
                            }
                        }
                        let permissions = requiredPermissions
                        if permissions.isEmpty {
                            SettingRow(title: "Your current widgets don't need extra access") {}
                        } else {
                            VStack(spacing: 16) { SourcePermissionList(permissions: permissions) }.groupRow()
                        }
                        if store.configuration?.usesSpacesWorkspaces == true {
                            DesktopShortcutSettings(workspaces: store.workspaceStore).groupRow()
                        }
                    }
                    .id(SettingsSearchResult.access.id)
                    SettingsGroup("Configuration file") {
                        row {
                            Text(store.configurationURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        } control: {
                            Button("Open", action: store.openConfiguration)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.configurationURL]) }
                            Button("Reload", action: store.reloadConfiguration)
                        }
                    }
                    .id(SettingsSearchResult.configuration.id)
                    SettingsGroup("Command line") {
                        CommandLineToolSettings()
                    }
                    .id(SettingsSearchResult.commandLine.id)
                    SettingsGroup("Updates") {
                        AboutView(update: store.update).rows
                        SettingRow(title: "Notify about package updates", hint: "Show a dismissible button in the bar. Checks hourly.") {
                            Toggle("Notify about package updates", isOn: Binding(get: { store.packageLibrary.notifiesAboutUpdates },
                                                                                set: { store.packageLibrary.notifiesAboutUpdates = $0 }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                    }
                    .id(SettingsSearchResult.updates.id)
                    SettingsGroup("Help") {
                        SettingRow(title: "Run setup again") {
                            Button("Open setup…") { NSApp.sendAction(#selector(AppDelegate.showSetup), to: NSApp.delegate, from: nil) }
                        }
                        SettingRow(title: "User guide") {
                            Button("Open") { NSWorkspace.shared.open(URL(string: "https://github.com/Seb-GRAF/StableBar/blob/main/docs/README.md")!) }
                        }
                        SettingRow(title: "Star on GitHub", hint: "A star helps other people find StableBar.") {
                            Button("Open") {
                                if let request = store.update?.starRequest {
                                    request.star()
                                } else {
                                    NSWorkspace.shared.open(StarRequest.repository)
                                }
                            }
                        }
                    }
                    .id(SettingsSearchResult.help.id)
                    SettingsGroup("Uninstall") {
                        UninstallSettings(store: store)
                    }
                    .id(SettingsSearchResult.uninstall.id)
                }
                .font(.system(size: 13))
                .frame(maxWidth: 720)
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .task(id: editor.searchTarget) {
                if let target = editor.searchTarget {
                    await Task.yield()
                    if Task.isCancelled { return }
                    scroll.scrollTo(target, anchor: .top)
                    editor.searchTarget = nil
                }
            }
        }
    }

    private var connection: some View {
        let workspaces = store.workspaceStore
        let (status, color): (String, Color) = if let error = workspaces.error { (error, .red) }
            else if workspaces.isRunning { ("Connected", SettingsPalette.success) }
            else { ("Not in use", .secondary) }
        return row {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(status).textSelection(.enabled)
            }
        } control: {
            Button("Reconnect", action: workspaces.reconnect).disabled(!workspaces.isRunning)
        }
    }

    private func row<Label: View, Control: View>(@ViewBuilder label: () -> Label, @ViewBuilder control: () -> Control) -> some View {
        LabeledContent {
            HStack(spacing: 8) { control() }
        } label: {
            label()
        }
    }

    private var requiredPermissions: [SourcePermission] {
        var permissions = store.registry.permissions(for: store.configuration)
        if store.configuration?.bar.keepWindowsClear == true
            || (macOSVersion.supportsNotificationClearance && store.configuration?.bar.keepNotificationsClear == true)
            || (store.configuration?.bar.menuBarRevealDelay ?? 0) > 0 {
            permissions.removeAll { $0.privacyPane == SourcePermission.accessibility.privacyPane }
            permissions.append(SourcePermission(title: "Accessibility",
                detail: "StableBar needs access to move windows and notifications, show app menus, and delay the native menu bar.",
                symbol: "accessibility", privacyPane: "Privacy_Accessibility"))
        }
        return permissions
    }
}

/// Keeps a shared configuration's saved value visible even where notification clearance isn't available.
struct NotificationClearanceSettings: View {
    let bar: StyleFields
    let macOSVersion: MacOSVersion

    var hint: String { macOSVersion.supportsNotificationClearance ? "macOS 26 and later" : "Needs macOS 26 or later." }

    var body: some View {
        bar.toggle("Keep notifications clear of the bar", "keepNotificationsClear", default: false, hint: hint)
            .disabled(!macOSVersion.supportsNotificationClearance)
    }
}

struct SettingsSectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
    }
}
