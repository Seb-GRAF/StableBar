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
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + (intro ? 1 : -1))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        let host = NSHostingView(rootView: SetupTourView(session: session!, screen: screen, intro: intro,
                                                         finish: { [weak self] in self?.showCard() },
                                                         skip: { [weak self] in self?.closeTour() },
                                                         reveal: { [weak panel] in panel?.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1) },
                                                         lower: { [weak panel] in panel?.level = .normal },
                                                         showProfile: showProfile))
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
            session: session!, arrangeBar: arrangeBar, customizeWidgets: customizeWidgets,
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
        if session?.finished == false { session?.cancel() }
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
    private(set) var finished = false
    var preferences = SetupPreferences() { didSet { preview() } }
    var openAtLogin: Bool?
    var loginStatus = SMAppService.mainApp.status
    var calendarAccess = EKEventStore.authorizationStatus(for: .event)
    var menuBarHides = UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
    private let menuBarHidAtStart = UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
    var accessibilityAccess = AXIsProcessTrusted()
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

    var needsCalendarAccess: Bool {
        store.registry.permissions(for: store.configuration).contains(.calendars) || needsCalendarSetup && !preferences.deferMeetings
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

    func place(_ placement: SetupPreferences.Placement) async {
        if placement == .belowMenuBar { preferences.placement = placement }
        do {
            try await setMenuBarHidden(placement == .top)
            preferences.placement = placement
        } catch {
            self.error = "StableBar couldn’t \(placement == .top ? "hide" : "show") the macOS menu bar. \(errorMessage(error))"
        }
    }

    private func setMenuBarHidden(_ hidden: Bool) async throws {
        guard hidden != menuBarHides else { return }
        _ = try await runCommand("/usr/bin/osascript", arguments: [
            "-e", "tell application \"System Events\" to set autohide menu bar of dock preferences to \(hidden)"
        ], timeout: 120)
        menuBarHides = hidden
    }

    func requestCalendarAccess() async {
        do {
            _ = try await EKEventStore().requestFullAccessToEvents()
        } catch {
            self.error = errorMessage(error)
        }
        refreshAccess()
    }

    func refreshAccess() {
        loginStatus = SMAppService.mainApp.status
        calendarAccess = EKEventStore.authorizationStatus(for: .event)
        menuBarHides = UserDefaults.standard.bool(forKey: "_HIHideMenuBar")
        accessibilityAccess = AXIsProcessTrusted()
        guard !finished else { return }
        if calendarAccess == .fullAccess { preferences.deferMeetings = false } else { preview() }
    }

    func cancel() {
        store.sessionEdits = sessionEdits
        store.reloadConfiguration()
        Task { try await setMenuBarHidden(menuBarHidAtStart) }
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
            finished = true
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
    let close: () -> Void

    var body: some View {
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
        .frame(width: 460, height: 640)
        .background(SettingsPalette.background)
        .focusEffectDisabled()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            session.refreshAccess()
        }
    }
}
