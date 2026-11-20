import AppKit
import EventKit
import ServiceManagement
import SwiftUI

@MainActor
final class SetupWindow {
    private var session: SetupSession?
    private let launchResume: ApplicationMoveLaunchResume
    private var tour: SetupTourPanel?
    private var editBar: (() -> Void)?

    /// The intro dims the whole screen, the macOS menu bar included. On the stage the tour covers the bar, which waits
    /// at the top for its copy to fly there; afterwards the bar shows over the tour.
    private static let introLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
    private static let stageLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    private static let tourLevel = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)

    init(launchResume: ApplicationMoveLaunchResume = ApplicationMoveLaunchResume()) {
        self.launchResume = launchResume
    }

    func prepareSession(store: BarStore, system: SetupSystem = SetupSystem()) -> SetupSession {
        if let session { return session }
        let session = SetupSession(store: store, system: system, resume: launchResume.take(for: .setup))
        self.session = session
        return session
    }

    func show(store: BarStore, editBar: (() -> Void)? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        if let tour {
            tour.makeKeyAndOrderFront(nil)
            return
        }
        self.editBar = editBar
        store.barEditing.setupIsOpen = true
        _ = prepareSession(store: store)
        store.appMenu.hidesAccessWarning = true
        showTour()
    }

    /// The height the Dock takes at the bottom of a screen, 0 when it sits on a side or another screen.
    nonisolated static func dockHeight(frame: CGRect, visibleFrame: CGRect) -> Double {
        max(0, visibleFrame.minY - frame.minY)
    }

    private func showTour() {
        let screen = NSScreen.main!
        // macOS hides the Dock only while StableBar is the active app. It shows over the tour whenever
        // another app is, such as System Settings after Allow, so the tour keeps its buttons above it.
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
        panel.level = session!.step == .menuBar ? Self.introLevel : Self.tourLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        let display = BarDisplay(screen: screen)
        // The screen as it is now, found by its display number rather than its place among the screens, which can
        // change while setup is open: its menu bar shows or hides as setup changes it.
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let number = screen.deviceDescription[key] as? NSNumber
        let menuBarHeight = { (NSScreen.screens.first { $0.deviceDescription[key] as? NSNumber == number } ?? screen).menuBarHeight }
        let host = NSHostingView(rootView: SetupTourView(session: session!, display: display, menuBarHeight: menuBarHeight, dock: dock,
                                                         close: { [weak self] in self?.closeTour() },
                                                         raise: { [weak panel] in panel?.level = Self.stageLevel },
                                                         reveal: { [weak panel] in panel?.level = Self.tourLevel },
                                                         lower: { [weak panel] in panel?.level = .normal },
                                                         editBar: editBar))
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
        if session?.finished == false { session?.cancel() }
        session?.store.appMenu.hidesAccessWarning = false
        session?.store.barEditing.setupIsOpen = false
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
    var macOSVersion = MacOSVersion()
    var automationAccess: (_ asking: Bool) async -> MenuBarAutoHide.Access = { await MenuBarAutoHide.access(asking: $0) }
    var setMenuBarHidden: (_ hidden: Bool) async throws -> Void = { try await MenuBarAutoHide.set($0) }
    var menuBarHides: () -> Bool = { MenuBarAutoHide.isOn() }
    var isTrusted: () -> Bool = { AXIsProcessTrusted() }
    var calendarAccess: () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) }
    var hasBattery: () -> Bool = { PowerMonitor.hasInternalBattery() }
    /// Whether StableBar runs from an Applications folder, the only place it can open at login from.
    var isInApplications: () -> Bool = { appIsInApplications() }
    var loginStatus: () -> SMAppService.Status = { SMAppService.mainApp.status }
    var setOpenAtLogin: (_ enabled: Bool) throws -> Void = { try setLaunchAtLogin($0) }
    var defaults = UserDefaults.standard
    /// Whether setup previews its choices on the running bar, which starts the commands of the widgets they add. A scene
    /// turns it off, since it runs nothing: setup shows its choices, and the bar shows its configuration as it is.
    var previewsOnTheBar = true
    /// The workspace source setup uses, given the one the configuration names: see `WorkspaceSource.detected`.
    var workspaceSource: (_ configured: WorkspaceSource?) -> WorkspaceSource = { configured in
        WorkspaceSource.detected(path: shellEnvironment.withLock { $0["PATH", default: ""] }, configured: configured)
    }
    /// Whether a manager runs, even when Workspaces uses Spaces or the manager's command isn't on PATH.
    var windowManagerRuns: () -> Bool = {
        [WorkspaceSource.aerospace, .yabai, .omniwm, .rift].contains(where: \.isRunning)
    }
    /// The packages the sources suggest for the tools and apps on this Mac. Scenes replace it so drawing setup never
    /// downloads the Store's index.
    var suggestedPackages: @Sendable (PackageStoreClient) async -> [PackageIndex.Entry] = { client in
        let catalog = await client.catalog()
        let ids = catalog.suggestedIDs
        return catalog.widgets.filter { ids.contains($0.id) }
    }
    /// The Store's widgets presets can add on this Mac, or nil when the Store can't be reached. Scenes replace it so
    /// drawing setup never downloads the Store's index.
    var storePackages: @Sendable (PackageStoreClient) async -> [PackageIndex.Entry]? = { client in
        let catalog = await client.catalog()
        return catalog.errors[PackageSource.storeID] == nil ? catalog.storeWidgets(suggested: catalog.suggestedIDs) : nil
    }
}

/// A macOS permission the bar that setup builds depends on. Setup asks for each one it needs before it finishes.
enum SetupPermission: CaseIterable, Hashable {
    case accessibility, calendars

    enum Action {
        case allow, openSettings

        var title: String {
            switch self {
            case .allow: "Allow…"
            case .openSettings: "Open Settings…"
            }
        }

        func accessibilityLabel(for permission: SetupPermission, on macOSVersion: MacOSVersion) -> String {
            switch self {
            case .allow: "Allow \(permission.title(on: macOSVersion))"
            case .openSettings: "Open \(permission.title(on: macOSVersion)) Settings"
            }
        }
    }

    func title(on macOSVersion: MacOSVersion) -> String {
        switch self {
        case .accessibility: macOSVersion.accessibilityName
        case .calendars: "Calendars"
        }
    }
}

@MainActor @Observable
final class SetupSession {
    let store: BarStore
    /// Windows and banners follow the bar from before setup's previews, including earlier session edits.
    private let clearanceHold: ClearanceHold
    let themes: [ThemeChoice]
    let workspaceSource: WorkspaceSource
    /// Setup keeps windows clear when no manager runs and no configuration layer sets it.
    private let recommendsWindowClearance: Bool
    /// Whether this Mac has an internal battery, which presets add Battery for.
    let hasBattery: Bool
    let currentThemeKey: String
    let applicationMove: ApplicationMoveController
    var step = Step.menuBar
    private(set) var finished = false
    var preset: SetupPreferences.Preset?
    var preferences = SetupPreferences() { didSet { preview() } }
    /// Store packages for the tools and apps on this Mac, without those already on the bar unless this setup added them.
    /// Empty until the Store answers, and when it can't be reached.
    private(set) var suggestions: [PackageIndex.Entry] = []
    /// The key of the suggestion downloading for review.
    private(set) var downloading: String?
    /// A picked suggestion's download, or a preset's Store widget's, which setup shows for review before adding it, as
    /// Add here does.
    private(set) var review: (inspection: WidgetPackageInspection, sourceID: String, settings: [String: ConfigurationValue]?)?
    /// The Store widgets presets can add on this Mac; nil until the Store answers, and when it can't be reached.
    private(set) var storeEntries: [PackageIndex.Entry]?
    /// The Store couldn't be reached, so presets add only their built-in widgets.
    private(set) var storeUnreachable = false
    /// The chosen preset's Store widgets still to review, the one on screen first, with the settings it starts from.
    private var storeReviews: [(entry: PackageIndex.Entry, settings: [String: String])] = []
    /// The person's Open at login choice; nil until they make one.
    var openAtLogin: Bool?
    var loginStatus: SMAppService.Status
    /// Whether StableBar opened at login when setup opened, to tell a change made in System Settings meanwhile.
    private let opensAtLoginAtStart: Bool
    /// Whether StableBar opens at login once setup finishes, as its switch shows it. Setup turns it on: in the menu
    /// bar's place, macOS keeps the menu bar hidden even while StableBar isn't running.
    var opensAtLogin: Bool {
        let enabled = loginStatus == .enabled || loginStatus == .requiresApproval
        return openAtLogin ?? (enabled || recommendationApplies(enabled: enabled))
    }

    /// The recommendation applies in an Applications folder, while the login status is still the one setup opened with,
    /// so a change made in System Settings meanwhile wins over it.
    private func recommendationApplies(enabled: Bool) -> Bool {
        system.isInApplications() && enabled == opensAtLoginAtStart
    }
    var calendarAccess: EKAuthorizationStatus
    var menuBarHides: Bool
    private let menuBarHidAtStart: Bool
    private let stableBarHidMenuBarAtStart: Bool
    var accessibilityAccess: Bool
    private var placing = SetupPlacement()
    /// The placement Allow chose; nil until then.
    var placementChoice: SetupPreferences.Placement? { placing.choice }
    /// The placement that waits for Automation access, while the bar sits below the menu bar.
    var placementAwaitingAccess: SetupPreferences.Placement? { placing.awaitingAccess }
    private var accessRequest: Task<MenuBarAutoHide.Access, Never>?
    @ObservationIgnored let system: SetupSystem
    /// The menu bar change System Events is still making, if any.
    @ObservationIgnored private var menuBarChange: Task<Void, Error>?
    /// macOS is asking whether StableBar may control System Events.
    var waitingForMenuBarAccess: Bool { accessRequest != nil }
    var error: String?
    private(set) var base: Configuration?
    private let sessionEdits: [ConfigurationEdit]
    /// Later command-line edits append after the preview; the handoff keeps them without duplicating its choices.
    private var previewEditCount = 0
    /// The choices setup opened with, to tell whether skipping would lose any.
    @ObservationIgnored private var initialPreferences = SetupPreferences()

    init(store: BarStore, system: SetupSystem = SetupSystem(), resume: ApplicationMoveResume? = nil,
         applicationMove: ApplicationMoveController? = nil) {
        self.store = store
        clearanceHold = ClearanceHold(configuration: store.configurationStore.clearanceConfiguration)
        self.system = system
        self.applicationMove = applicationMove ?? ApplicationMoveController(error: resume?.failure)
        let loginStatus = system.loginStatus()
        self.loginStatus = loginStatus
        opensAtLoginAtStart = resume?.setup?.opensAtLoginAtStart ?? (loginStatus == .enabled || loginStatus == .requiresApproval)
        calendarAccess = system.calendarAccess()
        let menuBarHides = system.menuBarHides()
        self.menuBarHides = menuBarHides
        menuBarHidAtStart = resume?.setup?.menuBarHidAtStart ?? menuBarHides
        stableBarHidMenuBarAtStart = resume?.setup?.stableBarHidMenuBarAtStart ?? MenuBarAutoHide.turnedOnByStableBar(in: system.defaults)
        accessibilityAccess = system.isTrusted()
        hasBattery = system.hasBattery()
        currentThemeKey = store.configurationStore.selectedThemeKey
        themes = ThemeCatalog(packages: store.configurationStore.configurationURL.deletingLastPathComponent().appending(path: "packages"),
                              themesDirectory: store.configurationStore.themesDirectory, selectedKey: currentThemeKey).choices
            .onePerTheme(keeping: [currentThemeKey])
        // Until a setup finishes, Spaces on the first launch's starter stands in for a manager it didn't find, so setup
        // looks again.
        let document = try? JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: store.configurationStore.configurationURL))
        let provisional = !system.defaults.bool(forKey: SetupProgress.completedKey) && document.map(SetupPreferences.isFirstLaunchSpacesStarter) == true
        workspaceSource = system.workspaceSource(provisional ? nil : store.namedWorkspaceSource)
        let bar = try? store.effectiveDocument["bar"]?.decoded([String: ConfigurationValue].self)
        recommendsWindowClearance = workspaceSource == .spaces && !system.windowManagerRuns() && bar?["keepWindowsClear"] == nil
        sessionEdits = resume.map { $0.edits.map(\.restored) } ?? store.configurationStore.sessionEdits
        previewEditCount = sessionEdits.count
        // Restoring preferences can preview them immediately, so clearance must already be held.
        store.windowClearance.hold = clearanceHold
        // Setup builds the bar for the menu bar's place from the start, so the bar on the stage is the one that flies
        // there.
        preferences.placement = .top
        preferences.workspaces = workspaceSource
        initialPreferences = preferences
        if let saved = resume?.setup {
            step = Step(rawValue: saved.step)!
            preset = saved.preset
            placing = SetupPlacement(choice: saved.placementChoice, awaitingAccess: saved.placementAwaitingAccess)
            openAtLogin = system.isInApplications() ? saved.openAtLogin : nil
            preferences = saved.preferences
        }
        preview()
    }

    /// Moving is for Open at login, but registering it still waits for Done, just like the switch.
    func resumeAfterMoving() -> ApplicationMoveResume {
        ApplicationMoveResume(kind: .setup, configuration: store.configurationStore.sharedConfigurationURL.standardizedFileURL,
            barConfiguration: store.configurationStore.configurationURL.standardizedFileURL,
            setup: .init(step: step.rawValue, preferences: preferences, preset: preset, openAtLogin: true,
                         placementChoice: placementChoice, placementAwaitingAccess: placementAwaitingAccess,
                         menuBarHidAtStart: menuBarHidAtStart, stableBarHidMenuBarAtStart: stableBarHidMenuBarAtStart,
                         opensAtLoginAtStart: opensAtLoginAtStart),
            edits: (sessionEdits + store.configurationStore.sessionEdits.dropFirst(previewEditCount)).map(ApplicationMoveResume.Edit.init))
    }

    /// Chooses `preset`, as its row does, or the current bar again when it's the chosen one. Its Store widgets wait for
    /// `reviewStoreWidgets()`.
    func toggle(_ preset: SetupPreferences.Preset) {
        let selected = self.preset == preset
        self.preset = selected ? nil : preset
        preferences = preferences.replacingPresetChoices(with: selected ? SetupPreferences() : choices(for: preset, placement: preferences.placement))
    }

    /// What `preset` adds where the bar sits on this Mac: without Battery on a Mac without one, and with only the Store
    /// widgets the Store lists for it.
    private func choices(for preset: SetupPreferences.Preset, placement: SetupPreferences.Placement) -> SetupPreferences {
        var choices = preset.preferences(workspaces: workspaceSource, placement: placement, hasBattery: hasBattery)
        choices.widgetSets.removeAll { set in
            guard case let .store(id, _, _, _) = set else { return false }
            return storeEntries?.contains { $0.id == id } != true
        }
        return choices
    }

    /// The widget sets `preset` gives the bar, as its row draws them: the chosen preset's without those its review left out.
    func widgetSets(_ preset: SetupPreferences.Preset) -> [SetupPreferences.WidgetSet] {
        self.preset == preset ? preferences.widgetSets : choices(for: preset, placement: preferences.placement).widgetSets
    }

    /// `preset`'s widgets for a row to draw with a theme's `tokens`, a Store widget as its symbol in the Store.
    func sampleWidgets(_ preset: SetupPreferences.Preset, tokens: [String: ConfigurationValue]) -> [WidgetConfiguration] {
        widgetSets(preset).flatMap { set -> [[String: ConfigurationValue]] in
            guard case let .store(id, _, position, _) = set else { return set.widgets }
            return [["id": .string(id), "type": .string("text"), "text": .string(""), "position": .string(position.rawValue),
                     "icon": .string(storeEntries?.first { $0.id == id }?.symbol ?? "shippingbox")]]
        }.map { try! substituteConfigurationReferences(.object($0), prefix: "@token.", values: tokens).decoded(WidgetConfiguration.self) }
    }

    /// The Store widgets `preset` leaves out because the Store can't be reached.
    func leftOut(_ preset: SetupPreferences.Preset) -> [String] {
        guard storeUnreachable else { return [] }
        return preset.preferences(workspaces: workspaceSource, placement: preferences.placement).widgetSets.compactMap { set in
            if case let .store(_, name, _, _) = set { name } else { nil }
        }
    }

    /// Asks the Store once which widgets presets can add here.
    func loadStoreWidgets() async {
        guard storeEntries == nil, !storeUnreachable else { return }
        if let entries = await system.storePackages(store.packageStoreClient) { storeEntries = entries } else { storeUnreachable = true }
    }

    /// The chosen preset's Store widgets that Add reviews, with the settings each starts from. One whose ID a widget on
    /// the bar already has, from the Store or not, or picked under Found on your Mac, needs no review.
    var storeWidgetsToAdd: [(entry: PackageIndex.Entry, settings: [String: String])] {
        preferences.widgetSets.compactMap { set in
            guard case let .store(id, _, _, settings) = set, store.configuration?.widgets.contains(where: { $0.id == id }) != true,
                  !(preferences.packages + preferences.storeWidgets).contains(where: { $0.id == id }),
                  let entry = storeEntries?.first(where: { $0.id == id }) else { return nil }
            return (entry, settings)
        }
    }

    /// Reviews the chosen preset's Store widgets one at a time, as Found on your Mac does.
    func reviewStoreWidgets() async {
        storeReviews = storeWidgetsToAdd
        await reviewNextStoreWidget()
    }

    private func reviewNextStoreWidget() async {
        guard let (entry, settings) = storeReviews.first else { return }
        downloading = entry.key
        defer { downloading = nil }
        do {
            let inspection = try await store.packageStoreClient.packageForAdding(entry)
            // Settings saved for the package earlier win over the preset's.
            let saved = try WidgetSetup(store: store).savedSettings(for: inspection.manifest)
            review = (inspection, entry.sourceID, settings.mapValues(ConfigurationValue.string).merging(saved) { $1 })
            error = nil
        } catch {
            // Leaving the preset previews the bar again, which clears the error.
            await endReview()
            self.error = errorMessage(error)
        }
    }

    /// Closes the review, once Add has added its package or with Back. A preset's Store widget that wasn't added leaves
    /// the preset, whose built-in widgets stay, and its next Store widget comes up.
    func endReview() async {
        review = nil
        guard let entry = storeReviews.first?.entry else { return }
        storeReviews.removeFirst()
        if !preferences.storeWidgets.contains(where: { $0.id == entry.id }) {
            preferences.widgetSets.removeAll { if case let .store(id, _, _, _) = $0 { id == entry.id } else { false } }
        }
        await reviewNextStoreWidget()
    }

    func loadSuggestions() async {
        let entries = await system.suggestedPackages(store.packageStoreClient)
        let onBar = Set(store.widgetPackageIDs.values)
        suggestions = entries.filter { entry in !onBar.contains(entry.id) || preferences.packages.contains { $0.id == entry.id } }
    }

    /// Downloads `entry` for review, or takes back the suggestion when this setup added it.
    func pick(_ entry: PackageIndex.Entry) async {
        if preferences.packages.contains(where: { $0.id == entry.id }) {
            preferences.packages.removeAll { $0.id == entry.id }
            return
        }
        downloading = entry.key
        defer { downloading = nil }
        do {
            review = (try await store.packageStoreClient.packageForAdding(entry), entry.sourceID, nil)
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }

    /// Adds a suggestion, or the preset's Store widget, that its review installed, with the settings the review chose.
    /// Done saves it.
    func add(_ inspection: WidgetPackageInspection, settings: [String: ConfigurationValue]) {
        let package = SetupPreferences.Package(id: inspection.manifest.id, version: inspection.manifest.version, settings: settings)
        if storeReviews.first?.entry.id == package.id { preferences.storeWidgets.append(package) } else { preferences.packages.append(package) }
    }

    /// Whether the bar setup builds shows macOS Spaces in Workspaces, whose desktops switch through the Switch to
    /// Desktop shortcuts.
    var showsSpacesGuidance: Bool { store.configuration?.usesSpacesWorkspaces == true }

    var needsCalendarSetup: Bool {
        preferences.widgetSets.contains(.meetings) && calendarAccess != .fullAccess
    }

    /// What setup previews and saves: the choices, with window clearance when setup recommends it.
    private var applied: SetupPreferences {
        var applied = preferences
        if recommendsWindowClearance { applied.keepWindowsClear = true }
        return applied
    }

    var needsCalendarAccess: Bool {
        store.registry.permissions(for: store.configuration).contains(.calendars) || needsCalendarSetup && !preferences.deferMeetings
    }

    /// Setup's steps in order: the bar takes the menu bar's place, then gets its widgets and its look, then what's left,
    /// and the end.
    enum Step: Int, CaseIterable { case menuBar, widgets, look, tune, done }

    /// Whether the bar can leave the stage for its place: macOS answered for Automation, or the menu bar didn't need to
    /// change, and Accessibility is allowed.
    var readyToLand: Bool {
        guard accessibilityAccess else { return false }
        return switch placing.phase {
        case .placed, .awaitingAccess, .failed: true
        default: false
        }
    }

    /// What macOS must allow for the bar setup builds. Accessibility is always on the list: the app menus, the Apple
    /// menu, Menu bar items, Workspaces and window clearance all depend on it.
    var neededPermissions: [SetupPermission] {
        [.accessibility] + (needsCalendarAccess ? [.calendars] : [])
    }

    /// Setup doesn't finish while any of these is missing.
    var missingPermissions: [SetupPermission] {
        neededPermissions.filter { !isAllowed($0) }
    }

    func isAllowed(_ permission: SetupPermission) -> Bool {
        switch permission {
        case .accessibility: accessibilityAccess
        case .calendars: calendarAccess == .fullAccess
        }
    }

    /// macOS announces no Accessibility change, so setup checks it again while it shows.
    func pollAccessibility() {
        let trusted = system.isTrusted()
        if trusted != accessibilityAccess { accessibilityAccess = trusted }
    }

    func preview() {
        guard system.previewsOnTheBar else {
            base = store.configuration
            return
        }
        var shown = applied
        if needsCalendarSetup { shown.deferMeetings = true }
        do {
            var loader = ConfigurationLoader()
            let base = try loader.load(store.configurationStore.configurationURL, context: store.configurationStore.context)
            let document = try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: store.configurationStore.configurationURL))
            let edits = try sessionEdits + shown.edits(in: base, document: document)
            try store.configurationStore.setSessionEdits(edits)
            previewEditCount = edits.count
            self.base = base
            error = nil
        } catch {
            self.error = errorMessage(error)
        }
    }

    func place(_ placement: SetupPreferences.Placement) async {
        await send(.chose(placement, menuBarHides: menuBarHides))
    }

    private func send(_ event: SetupPlacement.Event) async {
        var next = placing
        let effects = next.handle(event)
        // Every write redraws the views that read `placing`, so a dropped answer writes nothing.
        if next != placing { placing = next }
        await perform(effects)
    }

    /// Carries out what `placing` decided, and sends it how each step went.
    private func perform(_ effects: [SetupPlacement.Effect]) async {
        for effect in effects {
            switch effect {
            case .move(let placement):
                var moved = preferences
                moved.placement = placement
                if let preset {
                    // The preset's bar for the new placement, still without the Store widgets its review left out.
                    moved.widgetSets = choices(for: preset, placement: placement).widgetSets.filter { set in
                        if case .store = set { preferences.widgetSets.contains(set) } else { true }
                    }
                }
                preferences = moved
            case .showError(let message):
                error = message
            case .checkAccess(let request):
                let access = await menuBarAccess()
                await send(.accessChecked(access, request: request))
            case .changeMenuBar(let hidden, let request):
                var failure: String?
                do {
                    try await setMenuBarHidden(hidden)
                } catch {
                    failure = errorMessage(error)
                }
                await send(.menuBarChanged(failure: failure, request: request))
            }
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
        return access
    }

    /// Each menu bar change waits for the one System Events is still making, so the restore after Skip setup lands
    /// after a hide or show that was still in flight.
    private func setMenuBarHidden(_ hidden: Bool) async throws {
        let previous = menuBarChange
        let change = Task {
            _ = try? await previous?.value
            guard hidden != menuBarHides else { return }
            do {
                try await system.setMenuBarHidden(hidden)
            } catch {
                // System Events can change the setting and still fail, as when it times out, so the next change, such
                // as the restore after Skip setup, starts from what macOS reports.
                recordMenuBar(hides: system.menuBarHides())
                throw error
            }
            recordMenuBar(hides: hidden)
        }
        menuBarChange = change
        try await change.value
    }

    /// Records whether the menu bar hides, and whether StableBar turned auto-hide on, which Uninstall turns off again.
    private func recordMenuBar(hides: Bool) {
        menuBarHides = hides
        MenuBarAutoHide.setTurnedOnByStableBar(MenuBarAutoHide.turnedOnByStableBar(
            after: hides, wasOn: menuBarHidAtStart, wasStableBars: stableBarHidMenuBarAtStart), in: system.defaults)
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
        store.workspaceStore.refreshDesktopShortcuts()
        loginStatus = system.loginStatus()
        calendarAccess = system.calendarAccess()
        menuBarHides = system.menuBarHides()
        accessibilityAccess = system.isTrusted()
        guard !finished else { return }
        if calendarAccess == .fullAccess { preferences.deferMeetings = false } else { preview() }
        // Automation allowed in System Settings meanwhile puts the bar in the menu bar's place after all.
        guard placementAwaitingAccess != nil, accessRequest == nil else { return }
        Task {
            guard await system.automationAccess(false) == .allowed else { return }
            await send(.accessAllowed(menuBarHides: menuBarHides))
        }
    }

    /// Whether setup changed macOS's menu bar setting, which skipping puts back.
    var changedMenuBar: Bool { menuBarHides != menuBarHidAtStart }

    /// Whether skipping would throw something away: a choice, Open at login, or the menu bar setting setup changed.
    var hasChanges: Bool {
        preferences != initialPreferences || openAtLogin != nil || menuBarHides != menuBarHidAtStart || placementAwaitingAccess != nil
    }

    func cancel() {
        // A placement still waiting on macOS, for Automation access or for its menu bar change, no longer applies, and
        // the restore below waits for that change.
        _ = placing.handle(.skipped)
        system.defaults.set(true, forKey: SetupProgress.skippedKey)
        store.configurationStore.sessionEdits = sessionEdits
        store.configurationStore.reloadConfiguration()
        releaseClearanceConfiguration()
        // Setup has closed by the time the restore could fail, so nothing shows the error. Settings → General shows
        // the menu bar setting as it is and changes it.
        Task { try? await setMenuBarHidden(menuBarHidAtStart) }
    }

    func finish() {
        calendarAccess = system.calendarAccess()
        accessibilityAccess = system.isTrusted()
        guard missingPermissions.isEmpty else {
            error = "Allow \(missingPermissions.map { $0.title(on: system.macOSVersion) }.formatted()) before you finish setup."
            return
        }
        var saved = false
        do {
            if needsCalendarSetup { preferences.deferMeetings = true }
            try applied.save(to: store.configurationStore.configurationURL, context: store.configurationStore.context)
            saved = true
            store.configurationStore.sessionEdits = sessionEdits
            store.configurationStore.reloadConfiguration()
            if let error = store.configurationError { throw CommandFailure(message: error) }
            // The file is saved and loads, so clearance follows it even if Open at login fails below.
            releaseClearanceConfiguration()
            // A choice changes it, and so does the recommendation while it applies.
            let status = system.loginStatus()
            let enabled = status == .enabled || status == .requiresApproval
            if system.isInApplications(), let wanted = openAtLogin ?? (recommendationApplies(enabled: enabled) ? true : nil), wanted != enabled {
                try system.setOpenAtLogin(wanted)
            }
            loginStatus = system.loginStatus()
            system.defaults.set(true, forKey: SetupProgress.completedKey)
            error = nil
            finished = true
        } catch {
            self.error = (saved ? "Your bar settings were saved. " : "") + errorMessage(error)
            loginStatus = system.loginStatus()
        }
    }

    private func releaseClearanceConfiguration() {
        guard store.windowClearance.hold === clearanceHold else { return }
        store.windowClearance.hold = nil
        // Saving can leave the displayed composition unchanged, so reloading alone may not update clearance.
        store.onConfigurationChange?()
    }
}

/// Whether setup was finished or skipped. StableBar opens setup by itself only until one of them happens;
/// after that, Getting Started… and Settings → General open it.
enum SetupProgress {
    static let completedKey = "setupCompleted"
    static let skippedKey = "setupSkipped"

    static func opensAtLaunch(in defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: completedKey) && !defaults.bool(forKey: skippedKey)
    }

    /// Setup was skipped and never finished, so Settings offers to finish it.
    static func wasSkipped(in defaults: UserDefaults) -> Bool {
        offersToFinish(skipped: defaults.bool(forKey: skippedKey), completed: defaults.bool(forKey: completedKey))
    }

    static func offersToFinish(skipped: Bool, completed: Bool) -> Bool {
        skipped && !completed
    }
}
