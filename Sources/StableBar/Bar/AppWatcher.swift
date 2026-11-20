import AppKit
import Observation

@MainActor @Observable
final class AppWatcher: NSObject {
    weak var store: BarStore?
    var activeApp = NSWorkspace.shared.frontmostApplication
    var activeDisplayID = 1
    /// The app whose menus the macOS menu bar shows, which App menus and the Apple menu follow, and how the bar
    /// hears that it changed: the returned object keeps the observation alive.
    @ObservationIgnored var menuBarApp: () -> NSRunningApplication? = { NSWorkspace.shared.menuBarOwningApplication }
    @ObservationIgnored var observeMenuBarApp: (@escaping @MainActor () -> Void) -> AnyObject = { changed in
        NSWorkspace.shared.observe(\.menuBarOwningApplication) { _, _ in MainActor.assumeIsolated { changed() } }
    }
    private var menuBarAppObservation: AnyObject?

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateActiveApp), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // The menus follow the menu bar rather than the front app: macOS hands the menu bar over a moment after it
        // announces an activation, and keeps it on the previous app while an agent without one is in front (#443).
        menuBarAppObservation = observeMenuBarApp { [weak self] in self?.readAppMenu() }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAppMenu), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(readLaunchedAppMenuBarItems), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(readMenuBarItems), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(refreshAppMenu), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    /// The app macOS shows its permission prompts from, such as the one for System Audio Recording.
    static let permissionPrompts = "com.apple.UserNotificationCenter"

    /// The active app while a permission prompt is in front of it.
    private var behindPrompt: NSRunningApplication?

    @objc private func updateActiveApp() {
        guard let store else { return }
        let front = NSWorkspace.shared.frontmostApplication
        // A permission prompt in front of the app, and the app coming back after it, leave the active app and an open
        // popup as they were, such as the Sound details that asked for the permission.
        if front?.bundleIdentifier == Self.permissionPrompts {
            behindPrompt = activeApp
            return
        }
        let returning = behindPrompt != nil && front == behindPrompt
        behindPrompt = nil
        activeApp = front
        guard !returning else { return }
        if let screen = NSScreen.main { activeDisplayID = BarDisplay(screen: screen).id }
        store.popup.close()
        store.configurationStore.refreshContext()
        store.widgetScripts.send(.frontApp, ["INFO": activeApp?.localizedName ?? "Desktop"])
    }

    func readAppMenu() {
        guard let store else { return }
        let shown = store.configuration?.widgets.contains { widget in
            switch widget.content {
            case .appMenu, .appleMenu(click: .menu): widget.enabled
            default: false
            }
        } == true
        store.appMenu.read(shown ? menuBarApp() : nil)
    }

    @objc private func refreshAppMenu() {
        activeApp = NSWorkspace.shared.frontmostApplication
        readAppMenu()
    }

    @objc func readMenuBarItems() {
        guard let store, store.configuration?.widgets.contains(where: { $0.enabled && $0.drawsMenuBarItems }) == true else { return }
        Task { _ = await store.appMenu.readMenuBarItems(requestingAccess: false) }
    }

    @objc private func readLaunchedAppMenuBarItems() {
        Task {
            for delay in [1, 5] {
                try? await Task.sleep(for: .seconds(delay))
                readMenuBarItems()
            }
        }
    }

    func stop() {
        menuBarAppObservation = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
