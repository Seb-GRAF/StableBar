import AppKit
import EventKit
import ServiceManagement
import SwiftUI

@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
    private var session: SetupSession?
    private var tour: SetupTourPanel?
    private var card: NSWindow?
    private var arrangeBar: (() -> Void)?
    private var customizeWidgets: (() -> Void)?
    private var showProfile: ((String) -> Void)?

    func show(store: BarStore, arrangeBar: (() -> Void)? = nil, customizeWidgets: (() -> Void)? = nil,
              showProfile: ((String) -> Void)? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = tour ?? card {
            window.makeKeyAndOrderFront(nil)
            return
        }
        self.arrangeBar = arrangeBar
        self.customizeWidgets = customizeWidgets
        self.showProfile = showProfile
        session = SetupSession(store: store)
        showTour(intro: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func showTour(intro: Bool) {
        let screen = NSScreen.main!
        let panel = SetupTourPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "Set up StableBar"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        let host = NSHostingView(rootView: SetupTourView(session: session!, screen: screen, intro: intro,
                                                         finish: { [weak self] in self?.showCard() },
                                                         skip: { [weak self] in self?.closeTour() }))
        host.sizingOptions = []
        panel.contentView = host
        panel.alphaValue = 0
        tour = panel
        NSApp.presentationOptions = [.autoHideDock]
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            panel.animator().alphaValue = 1
        }
    }

    private func closeTour() {
        guard let tour else { return }
        self.tour = nil
        NSApp.presentationOptions = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            tour.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in tour.close() }
        }
        if card == nil { end() }
    }

    private func showCard() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Set up StableBar"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.animationBehavior = .alertPanel
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: SetupCardView(
            session: session!, arrangeBar: arrangeBar, customizeWidgets: customizeWidgets, showProfile: showProfile,
            back: { [weak self] in
                guard let self else { return }
                showTour(intro: false)
                card?.close()
            },
            close: { [weak window] in window?.close() }))
        window.center()
        card = window
        window.makeKeyAndOrderFront(nil)
        closeTour()
    }

    func windowWillClose(_ notification: Notification) {
        card?.contentView = nil
        card = nil
        if tour == nil { end() }
    }

    private func end() {
        if session?.step != 5 { session?.cancel() }
        session = nil
    }
}

private final class SetupTourPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor @Observable
final class SetupSession {
    let store: BarStore
    let themes: [ThemeChoice]
    let sets: [SetupPreferences.WidgetSet]
    let currentThemeKey: String
    var step = 0
    var preferences = SetupPreferences() { didSet { preview() } }
    var openAtLogin: Bool?
    var loginStatus = SMAppService.mainApp.status
    var calendarAccess = EKEventStore.authorizationStatus(for: .event)
    var menuBarHides = UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
    var error: String?
    private(set) var base: Configuration?
    private let sessionEdits: [ConfigurationEdit]

    init(store: BarStore) {
        self.store = store
        currentThemeKey = store.selectedThemeKey
        themes = themeChoices(packages: store.configurationURL.deletingLastPathComponent().appending(path: "packages"),
                              selectedKey: currentThemeKey)
        let path = shellEnvironment.withLock { $0["PATH", default: ""] }.split(separator: ":")
        let source = [store.configuration?.workspaceSource ?? .aerospace, .aerospace, .yabai].first { source in
            path.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(source.rawValue)") }
        }
        sets = [.system, .meetings] + (source.map { [.workspaces($0)] } ?? [])
        sessionEdits = store.sessionEdits
        preview()
    }

    var menuBarHeight: Double {
        max(NSStatusBar.system.thickness, NSScreen.main?.safeAreaInsets.top ?? 0)
    }

    var needsCalendarSetup: Bool {
        preferences.widgetSets.contains(.meetings) && calendarAccess != .fullAccess
    }

    var currentTheme: String {
        themes.first { $0.key == currentThemeKey }?.title ?? (currentThemeKey == "built-in" ? "Built-in" : currentThemeKey)
    }

    var placement: SetupPreferences.Placement {
        if preferences.placement != .current { return preferences.placement }
        let offset = base?.bar.offset
        return offset == 0 ? .top : offset == menuBarHeight ? .belowMenuBar : .current
    }

    var permissions: [SourcePermission] {
        var permissions = store.registry.permissions(for: store.configuration)
        if needsCalendarSetup && !preferences.deferMeetings && !permissions.contains(.calendars) {
            permissions.append(.calendars)
        }
        if store.configuration?.bar.keepWindowsClear == true || store.configuration?.bar.keepNotificationsClear == true {
            permissions.removeAll { $0.privacyPane == "Privacy_Accessibility" }
            permissions.append(SourcePermission(title: "Accessibility",
                                                detail: "Keeps windows and notifications clear of the bar. Menu widgets also use this access.",
                                                symbol: "accessibility", privacyPane: "Privacy_Accessibility"))
        }
        return permissions
    }

    func preview() {
        var shown = preferences
        if needsCalendarSetup { shown.deferMeetings = true }
        do {
            var loader = ConfigurationLoader()
            let base = try loader.load(store.configurationURL, context: store.context)
            try store.setSessionEdits(sessionEdits + shown.edits(in: base, menuBarHeight: menuBarHeight))
            self.base = base
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }

    func refreshAccess() {
        loginStatus = SMAppService.mainApp.status
        calendarAccess = EKEventStore.authorizationStatus(for: .event)
        menuBarHides = UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
        guard step < 5 else { return }
        if calendarAccess == .fullAccess { preferences.deferMeetings = false } else { preview() }
    }

    func cancel() {
        store.sessionEdits = sessionEdits
        store.reloadConfiguration()
    }

    func finish() {
        var saved = false
        do {
            calendarAccess = EKEventStore.authorizationStatus(for: .event)
            if needsCalendarSetup { preferences.deferMeetings = true }
            try preferences.save(to: store.configurationURL, menuBarHeight: menuBarHeight, context: store.context)
            saved = true
            store.sessionEdits = sessionEdits
            store.reloadConfiguration()
            if let error = store.configurationError { throw CommandFailure(message: error) }
            let status = SMAppService.mainApp.status
            if let openAtLogin, openAtLogin != (status == .enabled || status == .requiresApproval) {
                try setLaunchAtLogin(openAtLogin)
            }
            loginStatus = SMAppService.mainApp.status
            UserDefaults.standard.set(true, forKey: "setupCompleted")
            error = nil
            step = 5
        } catch {
            self.error = (saved ? "Your bar settings were saved. " : "") + errorMessage(error)
            loginStatus = SMAppService.mainApp.status
        }
    }
}

struct SetupCardView: View {
    let session: SetupSession
    let arrangeBar: (() -> Void)?
    let customizeWidgets: (() -> Void)?
    let showProfile: ((String) -> Void)?
    let back: () -> Void
    let close: () -> Void

    private var store: BarStore { session.store }

    var body: some View {
        Group {
            if session.step == 5 { completion } else { finishing }
        }
        .frame(width: 460, height: 640)
        .background(SettingsPalette.background)
        .animation(.smooth(duration: 0.4), value: session.step)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.refreshAccess()
        }
    }

    private var finishing: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(spacing: 10) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                        Text("Almost done").font(.system(size: 26, weight: .semibold))
                        Text("Choose what StableBar may do. Permission buttons open macOS prompts right away.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    section("Access") {
                        if session.permissions.isEmpty {
                            Label("Your widgets need no extra access", systemImage: "checkmark.circle")
                                .foregroundStyle(SettingsPalette.success)
                        } else {
                            SourcePermissionList(permissions: session.permissions) { session.refreshAccess() }
                        }
                        if session.needsCalendarSetup {
                            if session.preferences.deferMeetings {
                                Text("Meetings will stay turned off. Turn it on in Settings → Bar when you are ready to allow Calendar access.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Set up Calendar access now") { session.preferences.deferMeetings = false }
                            } else {
                                Text("Without Calendar access, Meetings is saved turned off. Existing widgets stay unchanged.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Set up Meetings later") { session.preferences.deferMeetings = true }
                            }
                        }
                        Text("Widgets that control another app ask for Automation access when you use that action.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if session.placement == .top {
                        section("Menu bar") {
                            if session.menuBarHides {
                                Label("The macOS menu bar hides automatically", systemImage: "checkmark.circle")
                                    .foregroundStyle(SettingsPalette.success)
                            } else {
                                Text("On the top edge, the macOS menu bar covers StableBar until you set it to hide automatically.")
                                    .font(.callout).foregroundStyle(.secondary)
                                Button("Open Menu Bar Settings…") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!)
                                }
                                Text("Choose Always for “Automatically hide and show the menu bar”.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    section("Windows") {
                        switchRow("Keep windows clear of StableBar", isOn: Binding(
                            get: { session.preferences.keepWindowsClear ?? (session.base?.bar.keepWindowsClear == true) },
                            set: { session.preferences.keepWindowsClear = $0 }))
                        switchRow("Keep notifications clear of StableBar", isOn: Binding(
                            get: { session.preferences.keepNotificationsClear ?? (session.base?.bar.keepNotificationsClear == true) },
                            set: { session.preferences.keepNotificationsClear = $0 }))
                        Text("Requires Accessibility access. Window clearance moves and resizes ordinary windows; fullscreen windows stay unchanged. Notification clearance requires macOS 26.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let source = session.sets.compactMap({ set -> WorkspaceSource? in
                            if case let .workspaces(source) = set { return source }
                            return nil
                        }).first {
                            Text("\(source.title) detected. Leave window clearance off if it already manages your gaps. \(source == .aerospace ? "Set gaps.outer.top in AeroSpace to leave room for the bar." : "Use yabai’s external_bar setting to leave room for the bar.")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    section("Startup") {
                        switchRow("Open at login", isOn: Binding(
                            get: { session.openAtLogin ?? (session.loginStatus == .enabled || session.loginStatus == .requiresApproval) },
                            set: { session.openAtLogin = $0 }))
                            .disabled(!appIsInApplications())
                        if !appIsInApplications() {
                            Text("Drag StableBar to Applications and open it there to start it at login.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Show app in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                        }
                        if session.loginStatus == .requiresApproval {
                            Button("Allow StableBar in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                    section("Your changes") { changeSummary }
                    profileNotice
                    if let error = session.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 40)
                .padding(.bottom, 20)
            }
            VStack(spacing: 12) {
                Button { session.finish() } label: { Text("Finish setup").frame(maxWidth: .infinity) }
                    .buttonStyle(SetupButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Back to the tour", action: back)
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .transition(.blurFade)
    }

    private var completion: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white, SettingsPalette.success)
                }
            Text("You're all set").font(.system(size: 26, weight: .semibold))
            Text("Click a widget to use it. Edit Bar in Place moves widgets and opens their settings. Changes save automatically, and Undo restores the previous step.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if session.preferences.widgetSets.contains(.meetings) && session.preferences.deferMeetings {
                Label("Meetings is turned off. Turn it on in Settings → Bar when you are ready to allow Calendar access.", systemImage: "calendar")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if session.loginStatus == .requiresApproval {
                Text("Open at login still needs your approval in macOS.").font(.callout)
                Button("Allow StableBar in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
            Spacer()
            HStack(spacing: 10) {
                if let arrangeBar {
                    Button { close(); arrangeBar() } label: { Text("Edit Bar in Place").frame(maxWidth: .infinity) }
                        .buttonStyle(SetupButtonStyle(prominent: false))
                }
                if let customizeWidgets {
                    Button { close(); customizeWidgets() } label: { Text("Open Settings").frame(maxWidth: .infinity) }
                        .buttonStyle(SetupButtonStyle(prominent: false))
                }
            }
            Button { close() } label: { Text("Done").frame(maxWidth: .infinity) }
                .buttonStyle(SetupButtonStyle())
                .keyboardShortcut(.defaultAction)
            Text("Reopen this guide with Getting Started… in the menu-bar icon's menu.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .transition(.blurFade)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.groupBorder))
        }
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private func widgetSetStatus(_ set: SetupPreferences.WidgetSet, state: SetupPreferences.WidgetSet.State) -> String {
        if let configuration = store.configuration, set.state(in: configuration) == .disabled {
            return "Will stay turned off in this configuration"
        }
        return switch state {
        case .available: "Will be added"
        case .added: "Already added"
        case .disabled: "Will be turned on"
        case .conflict: "An existing widget uses this ID. Its settings will be kept."
        }
    }

    private var changeSummary: some View {
        let preferences = session.preferences
        return VStack(alignment: .leading, spacing: 8) {
            if preferences == SetupPreferences() && session.openAtLogin == nil {
                Text("Your current bar and login preference will be kept.").foregroundStyle(.secondary)
            }
            switch preferences.theme {
            case .current: EmptyView()
            case .builtIn: LabeledContent("Theme", value: "Built-in")
            case let .package(id, version):
                LabeledContent("Theme", value: session.themes.first { $0.manifest.id == id && ($0.isBundled || $0.manifest.version == version) }?.title ?? id)
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
                LabeledContent(set.title, value: set == .meetings && (session.needsCalendarSetup || preferences.deferMeetings)
                               ? "Save turned off · set up access later"
                               : widgetSetStatus(set, state: session.base.map { set.state(in: $0) } ?? .available))
            }
            if let openAtLogin = session.openAtLogin {
                LabeledContent("Open at login", value: openAtLogin ? "On" : "Off")
            }
        }
        .font(.callout)
    }

    private var profileSettings: [(String, ConfigurationOrigin)] {
        let settings = [("Appearance", "bar.appearance"), ("Placement", "bar.offset"),
                        ("Window clearance", "bar.keepWindowsClear"), ("Notification clearance", "bar.keepNotificationsClear")]
            + (store.configuration?.widgets.flatMap { widget -> [(String, String)] in
                var settings = [(widget.id, "widgets.\(widget.id).enabled")]
                if case .clock = widget.content { settings.append(("Clock \(widget.id)", "widgets.\(widget.id).format")) }
                return settings
            } ?? [])
        return settings.compactMap { title, path in
            guard let origin = store.origins[path], origin.profile != nil else { return nil }
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
                if let configuration = store.configuration {
                    Text("Effective placement: \(configuration.bar.offset.formatted()) pt from top.")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }
}
