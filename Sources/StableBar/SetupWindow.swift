import AppKit
import EventKit
import ServiceManagement
import SwiftUI

@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(store: BarStore, arrangeBar: (() -> Void)? = nil, customizeWidgets: (() -> Void)? = nil,
              showProfile: ((String) -> Void)? = nil) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Set up StableBar"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SetupView(store: store, arrangeBar: arrangeBar,
                                                              customizeWidgets: customizeWidgets, showProfile: showProfile) { [weak window] in window?.close() })
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
    }
}

struct SetupView: View {
    let store: BarStore
    let arrangeBar: (() -> Void)?
    let customizeWidgets: (() -> Void)?
    let showProfile: ((String) -> Void)?
    let close: () -> Void
    @State private var step = 0
    @State private var preferences = SetupPreferences()
    @State private var preview = BarStore()
    @State private var sources: [String: ScriptWidget] = [:]
    @State private var error: String?
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var openAtLogin: Bool?
    @State private var calendarAccess = EKEventStore.authorizationStatus(for: .event)
    @State private var wallpaper = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }.flatMap(NSImage.init(contentsOf:))
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var themes: [ThemeChoice] {
        themeChoices(packages: store.configurationURL.deletingLastPathComponent().appending(path: "packages"), selectedKey: store.selectedThemeKey)
    }

    private var menuBarHeight: Double {
        max(NSStatusBar.system.thickness, NSScreen.main?.safeAreaInsets.top ?? 0)
    }

    private var currentTheme: String {
        let key = store.selectedThemeKey
        return themes.first { $0.key == key }?.title ?? (key == "built-in" ? "Built-in" : key)
    }

    private var currentPlacement: String {
        let offset = store.configuration?.bar.offset ?? 0
        if offset == 0 { return "Top edge" }
        if offset == menuBarHeight { return "Below menu bar" }
        return "\(offset.formatted()) pt from top"
    }

    private var currentClocks: String {
        let formats = store.configuration?.widgets.compactMap { widget -> String? in
            if case let .clock(format) = widget.content {
                let formatter = DateFormatter()
                formatter.dateFormat = format
                return formatter.string(from: Date())
            }
            return nil
        } ?? []
        if formats.isEmpty { return "No clock on your bar" }
        return formats.joined(separator: ", ")
    }

    private var needsCalendarSetup: Bool {
        preferences.widgetSets.contains(.meetings) && calendarAccess != .fullAccess
    }

    private var permissions: [SourcePermission] {
        var permissions = store.registry.permissions(for: preview.configuration)
        if preview.configuration?.bar.keepWindowsClear == true || preview.configuration?.bar.keepNotificationsClear == true {
            permissions.removeAll { $0.privacyPane == "Privacy_Accessibility" }
            permissions.append(SourcePermission(title: "Accessibility",
                                                detail: "Keeps windows and notifications clear of the bar. Menu widgets also use this access.",
                                                symbol: "accessibility", privacyPane: "Privacy_Accessibility"))
        }
        return permissions
    }

    private var sets: [SetupPreferences.WidgetSet] {
        let path = shellEnvironment.withLock { $0["PATH", default: ""] }.split(separator: ":")
        let source = [store.configuration?.workspaceSource ?? .aerospace, .aerospace, .yabai].first { source in
            path.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(source.rawValue)") }
        }
        return [.system, .meetings] + (source.map { [.workspaces($0)] } ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.topthird.inset.filled")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("StableBar").font(.headline)
                Spacer()
                Text(step == 3 ? "Ready" : "\(step + 1) of 3")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 36)
            .padding(.top, 24)
            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Capsule().fill(index <= step ? Color.accentColor : Color.primary.opacity(0.08)).frame(height: 3)
                }
            }
            .accessibilityLabel(step == 3 ? "Setup complete" : "Setup step \(step + 1) of 3")
            .padding(.horizontal, 36)
            .padding(.top, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch step {
                    case 0: welcome
                    case 1: customization
                    case 2: access
                    default: completion
                    }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(36)
            }
            Divider()
            HStack {
                if step > 0 && step < 3 {
                    Button("Back") { step -= 1 }
                } else if step == 0 {
                    Button("Set up later", action: close)
                }
                Spacer()
                Text(step == 3 ? "You can reopen setup from Settings → General." : "Bar settings and Open at login apply when you finish.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(step == 3 ? "Done" : step == 2 ? "Apply setup" : "Continue") {
                    if step == 3 { close() }
                    else if step == 2 { finish() }
                    else { step += 1 }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: 720, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: step)
        .onAppear(perform: refreshPreview)
        .onChange(of: preferences) { refreshPreview() }
        .onDisappear { for source in sources.values { source.stop() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
            calendarAccess = EKEventStore.authorizationStatus(for: .event)
            if step < 3 { refreshPreview() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if step < 3 { refreshPreview() }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Make the bar yours.", detail: "Widgets are the items on your bar. Click one to use it; use Edit Bar in Place to move it or open its settings.")
            barPreview
            VStack(alignment: .leading, spacing: 10) {
                Text("Start from a preset").font(.headline)
                HStack(spacing: 10) {
                    ForEach(SetupPreferences.Preset.allCases, id: \.self) { preset in
                        presetCard(preset)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Text("A preset picks a style, which you can change on the next step, and adds its widgets. Click it again to keep your current bar.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2).frame(width: 28)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your existing setup stays in place").font(.headline)
                    Text("Only the choices you change here are saved. The starter bar works without extra permissions, accounts, or downloads.")
                        .foregroundStyle(.secondary)
                }
            }
            Label("Reopen Settings from the macOS menu-bar icon or by right-clicking the bar. Changes there save automatically, with Undo available.",
                  systemImage: "cursorarrow.click")
                .font(.callout).foregroundStyle(.secondary)
            if !appIsInApplications() {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "folder").foregroundStyle(.secondary).font(.title2).frame(width: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Give StableBar a home").font(.headline)
                        Text("Drag the app to Applications, then open it there. You can try the setup here first.")
                            .foregroundStyle(.secondary)
                        Button("Show app in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                    }
                }
            }
        }
    }

    private var customization: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Place and style your bar.", detail: "The preview shows the effective result, including your active profiles. Keep current leaves each setting untouched.")
            barPreview
            Form {
                Picker("Theme", selection: $preferences.theme) {
                    Text("Keep current: \(currentTheme)").tag(SetupPreferences.Theme.current)
                    Text("Built-in").tag(SetupPreferences.Theme.builtIn)
                    ForEach(themes, id: \.key) {
                        Text($0.title).tag(SetupPreferences.Theme.package(id: $0.manifest.id, version: $0.isBundled ? nil : $0.manifest.version))
                    }
                }
                .pickerStyle(.menu)
                Picker("Appearance", selection: $preferences.appearance) {
                    ForEach(SetupPreferences.Appearance.allCases, id: \.self) {
                        Text($0 == .current ? "Keep current: \(store.configuration?.bar.appearance?.rawValue.capitalized ?? "Automatic")" : $0.rawValue).tag($0)
                    }
                }
                Picker("Placement", selection: $preferences.placement) {
                    ForEach(SetupPreferences.Placement.allCases, id: \.self) {
                        Text($0 == .current ? "Keep current: \(currentPlacement)" : $0.rawValue).tag($0)
                    }
                }
                Picker("Clock", selection: $preferences.clock) {
                    ForEach(SetupPreferences.Clock.allCases, id: \.self) {
                        Text($0 == .current ? "Keep current: \(currentClocks)" : $0.rawValue).tag($0)
                    }
                }
                .disabled(store.configuration?.widgets.contains { if case .clock = $0.content { true } else { false } } != true)
            }
            .formStyle(.columns)
            .pickerStyle(.menu)
            .controlSize(.large)
            Text("Below menu bar keeps the macOS menu bar visible. Top edge works best with an automatically hidden menu bar. Placement alone does not stop windows extending under the bar.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Keep windows clear of StableBar", isOn: Binding(
                get: { preferences.keepWindowsClear ?? (store.configuration?.bar.keepWindowsClear == true) },
                set: { preferences.keepWindowsClear = $0 }))
            Toggle("Keep notifications clear of StableBar", isOn: Binding(
                get: { preferences.keepNotificationsClear ?? (store.configuration?.bar.keepNotificationsClear == true) },
                set: { preferences.keepNotificationsClear = $0 }))
            Text("Requires Accessibility access. Window clearance moves and resizes ordinary windows; fullscreen windows stay unchanged. Notification clearance requires macOS 26.")
                .font(.caption).foregroundStyle(.secondary)
            if let source = sets.compactMap({ set -> WorkspaceSource? in
                if case let .workspaces(source) = set { return source }
                return nil
            }).first {
                Text("\(source.title) detected. Leave window clearance off if it already manages your gaps. \(source == .aerospace ? "Set gaps.outer.top in AeroSpace to leave room for the bar." : "Use yabai’s external_bar setting to leave room for the bar.")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            profileNotice
        }
    }

    private func presetCard(_ preset: SetupPreferences.Preset) -> some View {
        let selected = preferences == preset.preferences(sets: sets)
        return Button {
            preferences = selected ? SetupPreferences() : preset.preferences(sets: sets)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: preset.symbol)
                    .font(.title2)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(height: 28)
                HStack(spacing: 4) {
                    Text(preset.title).font(.headline)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }
                Text(preset.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Review and finish.", detail: "Allow access for the features you chose, or set them up later. Permission buttons open macOS prompts immediately.")
            VStack(alignment: .leading, spacing: 18) {
                if permissions.isEmpty {
                    Label("Enabled widgets need no extra access", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    SourcePermissionList(permissions: permissions) {
                        calendarAccess = EKEventStore.authorizationStatus(for: .event)
                        if calendarAccess == .fullAccess { preferences.deferMeetings = false }
                    }
                }
                if needsCalendarSetup {
                    if preferences.deferMeetings {
                        Text("Meetings will stay turned off. Enable it later in Your bar when you are ready to allow Calendar access.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Set up Calendar access now") { preferences.deferMeetings = false }
                    } else {
                        Text("Without Calendar access, your chosen Meetings widget will be saved turned off. Existing widgets stay unchanged.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Set up Meetings later") { preferences.deferMeetings = true }
                    }
                }
                Text("Widgets that control another app ask for Automation access when you use that action.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            Toggle(isOn: Binding(get: { openAtLogin ?? (loginStatus == .enabled || loginStatus == .requiresApproval) },
                                set: { openAtLogin = $0 })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open at login").font(.headline)
                    Text(appIsInApplications() ? "Have your bar ready when you sign in. Saved when you finish." : "Move the app to Applications to enable this.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .accessibilityLabel("Open at login")
            .disabled(!appIsInApplications())
            if loginStatus == .requiresApproval {
                Button("Allow StableBar in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
            changeSummary
            profileNotice
        }
    }

    private func widgetSetStatus(_ set: SetupPreferences.WidgetSet, state: SetupPreferences.WidgetSet.State) -> String {
        if let configuration = preview.configuration, set.state(in: configuration) == .disabled {
            return "Will stay turned off in this configuration"
        }
        return switch state {
        case .available: "Will be added"
        case .added: "Already added"
        case .disabled: "Will be turned on"
        case .conflict: "An existing widget uses this ID. Its settings will be kept."
        }
    }

    private var profileSettings: [(String, ConfigurationOrigin)] {
        let settings = [("Appearance", "bar.appearance"), ("Placement", "bar.offset"),
                        ("Window clearance", "bar.keepWindowsClear"), ("Notification clearance", "bar.keepNotificationsClear")]
            + (preview.configuration?.widgets.flatMap { widget -> [(String, String)] in
                var settings = [(widget.id, "widgets.\(widget.id).enabled")]
                if case .clock = widget.content { settings.append(("Clock \(widget.id)", "widgets.\(widget.id).format")) }
                return settings
            } ?? [])
        return settings.compactMap { title, path in
            guard let origin = preview.origins[path], origin.profile != nil else { return nil }
            return (title, origin)
        }
    }

    @ViewBuilder private var profileNotice: some View {
        if !profileSettings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("Active profiles control some settings", systemImage: "info.circle").font(.headline)
                ForEach(profileSettings, id: \.0) { title, origin in
                    Text("\(title): \(store.sourceText(origin)).")
                    if let showProfile {
                        Button("Edit \(origin.profile!) profile…") { showProfile(origin.profile!) }
                    }
                }
                Text("Setup saves your defaults. These profiles still take priority, so a saved change may not change the bar now. Review the controlling settings in Profiles.")
                if let configuration = preview.configuration {
                    Text("Effective placement: \(configuration.bar.offset.formatted()) pt from top.")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var changeSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Changes to apply").font(.headline)
            if preferences == SetupPreferences() && openAtLogin == nil {
                Text("Your current bar and login preference will be kept.")
            }
            switch preferences.theme {
            case .current: EmptyView()
            case .builtIn: LabeledContent("Theme", value: "Built-in")
            case let .package(id, version):
                LabeledContent("Theme", value: themes.first { $0.manifest.id == id && ($0.isBundled || $0.manifest.version == version) }?.title ?? id)
            }
            if preferences.appearance != .current {
                LabeledContent("Appearance", value: preferences.appearance.rawValue)
            }
            if preferences.placement != .current {
                LabeledContent("Placement", value: preferences.placement.rawValue)
            }
            if preferences.clock != .current {
                LabeledContent("Clock", value: preferences.clock.rawValue)
            }
            if let enabled = preferences.keepWindowsClear {
                LabeledContent("Keep windows clear", value: enabled ? "On · needs Accessibility" : "Off")
            }
            if let enabled = preferences.keepNotificationsClear {
                LabeledContent("Keep notifications clear", value: enabled ? "On · needs Accessibility" : "Off")
            }
            ForEach(preferences.widgetSets, id: \.self) { set in
                LabeledContent(set.title, value: set == .meetings && (needsCalendarSetup || preferences.deferMeetings)
                               ? "Save turned off · set up access later"
                               : widgetSetStatus(set, state: store.configuration.map { set.state(in: $0) } ?? .available))
            }
            if let openAtLogin {
                LabeledContent("Open at login", value: openAtLogin ? "On" : "Off")
            }
        }
        .font(.callout)
    }

    private var completion: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("Your bar is ready.", detail: "Click a widget to use it. Edit Bar in Place lets you move widgets, add more and open their settings. Changes save automatically, and Undo restores the previous step.")
            barPreview
            if preferences.widgetSets.contains(.meetings) && preferences.deferMeetings {
                Label("Meetings is turned off. Enable it in Your bar when you are ready to allow Calendar access.", systemImage: "calendar")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if loginStatus == .requiresApproval {
                Text("Open at login still needs your approval in macOS.")
                Button("Allow StableBar in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
            HStack {
                if let arrangeBar {
                    Button("Edit Bar in Place") { close(); arrangeBar() }
                        .buttonStyle(.borderedProminent)
                }
                if let customizeWidgets {
                    Button("Open Settings") { close(); customizeWidgets() }
                }
            }
            Text("Use the macOS menu-bar icon or right-click the bar to reopen Settings. Your bar contains your widgets, Library adds more, and General contains login and access preferences.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var barPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("YOUR BAR").font(.system(size: 10, weight: .semibold)).tracking(1.4)
                Spacer()
                Text("Preview").font(.caption)
            }
            .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                if let configuration = preview.configuration, configuration.bar.offset >= menuBarHeight {
                    HStack(spacing: 16) {
                        Image(systemName: "apple.logo")
                        Text("Finder").bold()
                        Text("File")
                        Text("Edit")
                        Spacer()
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 24)
                    .background(.bar)
                }
                let height = preview.configuration?.barGeometry(for: BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: nil)).panelHeight ?? 40
                GeometryReader { proxy in
                    BarView(store: preview, display: BarDisplay(id: 1, isBuiltIn: true, isMain: true, notch: nil))
                        .frame(width: proxy.size.width / 0.7, height: height)
                        .scaleEffect(0.7, anchor: .topLeading)
                }
                    .frame(height: height * 0.7)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Preview of your bar")
                Spacer(minLength: 24)
            }
            .frame(height: 100)
            .background { backdrop }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var backdrop: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let wallpaper { Image(nsImage: wallpaper).resizable().scaledToFill() }
        }
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 30, weight: .semibold)).tracking(-0.7)
            Text(detail).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshPreview() {
        do {
            try load(preview, preferences)
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }

    private func load(_ bar: BarStore, _ preferences: SetupPreferences) throws {
        let data = try preferences.applying(to: Data(contentsOf: store.configurationURL), menuBarHeight: menuBarHeight,
                                            configurationURL: store.configurationURL, context: store.context)
        var loader = ConfigurationLoader()
        let configuration = try loader.load(store.configurationURL, data: data, context: store.context)
        bar.configuration = configuration
        bar.origins = loader.origins
        bar.scripts = store.scripts
        for widget in configuration.widgets where widget.enabled && bar.scripts[widget.id] == nil {
            guard case let .provider(name) = widget.content, let provider = configuration.providers[name],
                  let type = store.registry[provider.type], type.isNative else { continue }
            if type.permission != nil {
                let script = ScriptWidget()
                script.output = previewMeeting
                bar.scripts[widget.id] = script
                continue
            }
            if sources[name] == nil {
                let source = ScriptWidget()
                source.start(provider: provider, registry: store.registry)
                sources[name] = source
            }
            bar.scripts[widget.id] = sources[name]
        }
        bar.preparePresentations()
        bar.workspaceStore.workspaces = store.workspaceStore.workspaces.isEmpty ? previewWorkspaces : store.workspaceStore.workspaces
    }

    private func finish() {
        var saved = false
        do {
            calendarAccess = EKEventStore.authorizationStatus(for: .event)
            if needsCalendarSetup { preferences.deferMeetings = true }
            try preferences.save(to: store.configurationURL, menuBarHeight: menuBarHeight, context: store.context)
            saved = true
            store.reloadConfiguration()
            if let error = store.configurationError { throw CommandFailure(message: error) }
            let status = SMAppService.mainApp.status
            if let openAtLogin, openAtLogin != (status == .enabled || status == .requiresApproval) {
                try setLaunchAtLogin(openAtLogin)
            }
            loginStatus = SMAppService.mainApp.status
            UserDefaults.standard.set(true, forKey: "setupCompleted")
            error = nil
            refreshPreview()
            step = 3
        } catch {
            self.error = (saved ? "Your bar settings were saved. " : "") + errorMessage(error)
            loginStatus = SMAppService.mainApp.status
        }
    }
}

private let previewMeeting = ScriptOutput(text: "Design review", icon: "calendar", fields: ["start": "10:30"])

private let previewWorkspaces = [
    Workspace(name: "1", isFocused: true, isVisible: true, monitor: 1,
              apps: [WorkspaceApp(workspace: "1", name: "Safari", bundleID: "com.apple.Safari")]),
    Workspace(name: "2", isFocused: false, isVisible: false, monitor: 1,
              apps: [WorkspaceApp(workspace: "2", name: "Mail", bundleID: "com.apple.mail")]),
    Workspace(name: "3", isFocused: false, isVisible: false, monitor: 1,
              apps: [WorkspaceApp(workspace: "3", name: "Notes", bundleID: "com.apple.Notes")])
]
