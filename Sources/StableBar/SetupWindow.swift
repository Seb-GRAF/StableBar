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
        store.appMenu.hidesAccessWarning = true
        showTour(intro: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// The height the Dock takes at the bottom of a screen, 0 when it sits on a side or another screen.
    nonisolated static func dockHeight(frame: CGRect, visibleFrame: CGRect) -> Double {
        max(0, visibleFrame.minY - frame.minY)
    }

    private func showTour(intro: Bool) {
        let screen = NSScreen.main!
        // macOS hides the Dock only while StableBar is the active app. It shows over the tour whenever
        // another app is, such as System Settings after Allow…, so the tour keeps its buttons above it.
        // Measured before the Dock hides.
        let dock = Self.dockHeight(frame: screen.frame, visibleFrame: screen.visibleFrame)
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
        let host = NSHostingView(rootView: SetupTourView(session: session!, screen: screen, dock: dock, intro: intro,
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
        session?.store.appMenu.hidesAccessWarning = false
        session = nil
    }
}

private final class SetupTourPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// What setup reads from macOS and changes there; tests replace it so they never touch this Mac's settings.
@MainActor
struct SetupSystem {
    var automationAccess: (_ asking: Bool) async -> MenuBarAutoHide.Access = { await MenuBarAutoHide.access(asking: $0) }
    var setMenuBarHidden: (_ hidden: Bool) async throws -> Void = { try await MenuBarAutoHide.set($0) }
    var menuBarHides: () -> Bool = { MenuBarAutoHide.isOn() }
    var isTrusted: () -> Bool = { AXIsProcessTrusted() }
    var calendarAccess: () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) }
    var defaults = UserDefaults.standard
}

/// A macOS permission the bar that setup builds depends on. Setup asks for each one it needs before it finishes.
enum SetupPermission: CaseIterable, Hashable {
    case accessibility, automation, calendars

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .automation: "Automation"
        case .calendars: "Calendars"
        }
    }
}

@MainActor @Observable
final class SetupSession {
    let store: BarStore
    let themes: [ThemeChoice]
    let workspaceSource: WorkspaceSource
    let currentThemeKey: String
    var step = 0
    private(set) var finished = false
    var preset: SetupPreferences.Preset?
    var preferences = SetupPreferences() { didSet { preview() } }
    var openAtLogin: Bool?
    var loginStatus = SMAppService.mainApp.status
    var calendarAccess: EKAuthorizationStatus
    var menuBarHides: Bool
    private let menuBarHidAtStart: Bool
    private let stableBarHidMenuBarAtStart: Bool
    var accessibilityAccess: Bool
    /// StableBar's access to System Events, which hides and shows the menu bar; nil until setup checks it.
    private(set) var automationAccess: MenuBarAutoHide.Access?
    /// The placement that needs Automation access first; setup applies it once access is allowed.
    private(set) var placementAwaitingAccess: SetupPreferences.Placement?
    private var accessRequest: Task<MenuBarAutoHide.Access, Never>?
    @ObservationIgnored let system: SetupSystem
    private var placementRequest = 0
    /// macOS is asking whether StableBar may control System Events.
    var waitingForMenuBarAccess: Bool { accessRequest != nil }
    var error: String?
    private(set) var base: Configuration?
    private let sessionEdits: [ConfigurationEdit]

    init(store: BarStore, system: SetupSystem = SetupSystem()) {
        self.store = store
        self.system = system
        calendarAccess = system.calendarAccess()
        let menuBarHides = system.menuBarHides()
        self.menuBarHides = menuBarHides
        menuBarHidAtStart = menuBarHides
        stableBarHidMenuBarAtStart = MenuBarAutoHide.turnedOnByStableBar(in: system.defaults)
        accessibilityAccess = system.isTrusted()
        currentThemeKey = store.selectedThemeKey
        themes = ThemeCatalog(packages: store.configurationURL.deletingLastPathComponent().appending(path: "packages"),
                              themesDirectory: store.themesDirectory, selectedKey: currentThemeKey).choices
        workspaceSource = WorkspaceSource.detected(path: shellEnvironment.withLock { $0["PATH", default: ""] },
                                                   configured: store.namedWorkspaceSource)
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
        themes.first { $0.key == currentThemeKey }?.title ?? currentThemeKey
    }

    var placement: SetupPreferences.Placement {
        if preferences.placement != .current { return preferences.placement }
        let offset = base?.bar.offset
        return offset == 0 ? .top : offset == menuBarHeight ? .belowMenuBar : .current
    }

    var needsCalendarAccess: Bool {
        store.registry.permissions(for: store.configuration).contains(.calendars) || needsCalendarSetup && !preferences.deferMeetings
    }

    /// Whether the chosen placement means setup changes macOS's menu bar setting, or already did.
    var needsAutomation: Bool {
        if placementAwaitingAccess != nil || menuBarHides != menuBarHidAtStart { return true }
        return placementChangesMenuBar
    }

    /// The placement needs the menu bar hidden or shown, and it isn't yet.
    private var placementChangesMenuBar: Bool {
        switch placement {
        case .top: !menuBarHides
        case .belowMenuBar: menuBarHides
        default: false
        }
    }

    /// What macOS must allow for the bar setup builds, in the order setup asks. Every preset has
    /// app menus and Menu bar items, so Accessibility is always on the list.
    var neededPermissions: [SetupPermission] {
        [.accessibility] + (needsAutomation ? [.automation] : []) + (needsCalendarAccess ? [.calendars] : [])
    }

    /// Setup doesn't finish while any of these is missing.
    var missingPermissions: [SetupPermission] {
        neededPermissions.filter { !isAllowed($0) }
    }

    func isAllowed(_ permission: SetupPermission) -> Bool {
        switch permission {
        case .accessibility: accessibilityAccess
        case .automation: automationAccess == .allowed && placementAwaitingAccess == nil && !placementChangesMenuBar
        case .calendars: calendarAccess == .fullAccess
        }
    }

    /// Asks for Automation access and applies the placement that was waiting for it.
    func allowAutomation() async {
        if placementChangesMenuBar || placementAwaitingAccess != nil {
            await place(placementAwaitingAccess ?? placement)
        } else {
            _ = await menuBarAccess()
        }
    }

    /// macOS announces no Accessibility change, so setup checks it again while it shows.
    func pollAccessibility() {
        let trusted = system.isTrusted()
        if trusted != accessibilityAccess { accessibilityAccess = trusted }
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

    /// Hiding or showing the menu bar needs Automation access to System Events, so setup checks it first,
    /// lets macOS ask once, and otherwise waits for the person to allow it in System Settings.
    /// The latest choice wins: a placement chosen while macOS asks replaces the earlier one.
    func place(_ placement: SetupPreferences.Placement) async {
        placementRequest += 1
        let request = placementRequest
        placementAwaitingAccess = nil
        if placement == .belowMenuBar { preferences.placement = placement }
        let changes = (placement == .top) != menuBarHides
        if changes {
            let access = await menuBarAccess()
            guard request == placementRequest else { return }
            guard access == .allowed else {
                placementAwaitingAccess = placement
                error = nil
                return
            }
        }
        do {
            try await setMenuBarHidden(placement == .top)
            if changes { automationAccess = .allowed }
            preferences.placement = placement
            error = nil
        } catch {
            let detail = errorMessage(error).contains("-1743")
                ? MenuBarAutoHide.accessHint
                : errorMessage(error)
            self.error = "StableBar couldn’t \(placement == .top ? "hide" : "show") the macOS menu bar. \(detail)"
        }
    }

    /// Clicks while macOS asks share its one dialog.
    private func menuBarAccess() async -> MenuBarAutoHide.Access {
        if let accessRequest { return await accessRequest.value }
        var access = await system.automationAccess(false)
        if access == .undecided {
            let request = Task { [system] in await system.automationAccess(true) }
            accessRequest = request
            access = await request.value
            accessRequest = nil
        }
        automationAccess = access
        return access
    }

    private func setMenuBarHidden(_ hidden: Bool) async throws {
        guard hidden != menuBarHides else { return }
        try await system.setMenuBarHidden(hidden)
        menuBarHides = hidden
        MenuBarAutoHide.setTurnedOnByStableBar(MenuBarAutoHide.turnedOnByStableBar(
            after: hidden, wasOn: menuBarHidAtStart, wasStableBars: stableBarHidMenuBarAtStart), in: system.defaults)
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
        calendarAccess = system.calendarAccess()
        menuBarHides = system.menuBarHides()
        accessibilityAccess = system.isTrusted()
        guard !finished else { return }
        if calendarAccess == .fullAccess { preferences.deferMeetings = false } else { preview() }
        guard needsAutomation, accessRequest == nil else { return }
        Task {
            let access = await system.automationAccess(false)
            automationAccess = access
            guard access == .allowed, let placement = placementAwaitingAccess else { return }
            await place(placement)
        }
    }

    func cancel() {
        store.sessionEdits = sessionEdits
        store.reloadConfiguration()
        Task { try await setMenuBarHidden(menuBarHidAtStart) }
    }

    func finish() {
        calendarAccess = system.calendarAccess()
        accessibilityAccess = system.isTrusted()
        guard missingPermissions.isEmpty else {
            error = "Allow \(missingPermissions.map(\.title).formatted()) before you finish setup."
            return
        }
        var saved = false
        do {
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
