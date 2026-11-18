import AppKit
import CoreWLAN
import IOKit.ps

@MainActor
final class SystemContext {
    private var powerSource: CFRunLoopSource?
    private var appearanceObserver: NSObjectProtocol?
    private let wifi = WiFiMonitor()
    private let privacy = PrivacyMonitor()
    private var watchesWiFi = false
    private var watchesPrivacy = false
    let changed: () -> Void

    init(changed: @escaping () -> Void) { self.changed = changed }

    /// The Mac's state. The Wi-Fi network, camera and microphone are read only when a profile in `profiles` checks
    /// them. Without Location access, macOS gives no network name, so a Wi-Fi condition never matches.
    static func current(checking profiles: [ConfigurationProfile] = []) -> ConfigurationContext {
        let power = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        var context = ConfigurationContext(
            appearance: NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light",
            onBattery: IOPSGetProvidingPowerSourceType(power).takeUnretainedValue() as String == kIOPSBatteryPowerValue,
            displayCount: NSScreen.screens.count,
            externalDisplay: NSScreen.screens.contains { !BarDisplay(screen: $0).isBuiltIn },
            displays: NSScreen.screens.map(\.localizedName),
            app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        let checks = checks(profiles)
        if checks.wifi { context.wifi = wifiNetwork() ?? "" }
        if checks.privacy, let fields = try? PrivacyMonitor().read().fields {
            context.camera = fields["camera"] == "true"
            context.microphone = fields["microphone"] == "true"
        }
        return context
    }

    /// The Wi-Fi network's name, as the `wifi` provider reads it, without asking for Location access.
    static func wifiNetwork() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    private static func checks(_ profiles: [ConfigurationProfile]) -> (wifi: Bool, privacy: Bool) {
        let conditions = profiles.compactMap(\.when)
        return (conditions.contains { $0.wifi != nil }, conditions.contains { $0.camera != nil || $0.microphone != nil })
    }

    func start() {
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            }
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            MainActor.assumeIsolated {
                Unmanaged<SystemContext>.fromOpaque(context!).takeUnretainedValue().changed()
            }
        }, Unmanaged.passUnretained(self).toOpaque()).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes)
    }

    /// Watches the Wi-Fi network, camera and microphone while `profiles` check them. A watch that starts reads them
    /// once the reload that called this is done.
    func watch(_ profiles: [ConfigurationProfile]) {
        let checks = Self.checks(profiles)
        let starts = (checks.wifi && !watchesWiFi) || (checks.privacy && !watchesPrivacy)
        let changed: @Sendable () -> Void = { [weak self] in MainActor.assumeIsolated { self?.changed() } }
        if checks.wifi != watchesWiFi {
            if checks.wifi { try? wifi.start(changed: changed) } else { wifi.stop() }
            watchesWiFi = checks.wifi
        }
        if checks.privacy != watchesPrivacy {
            if checks.privacy { try? privacy.start(changed: changed) } else { privacy.stop() }
            watchesPrivacy = checks.privacy
        }
        if starts { DispatchQueue.main.async(execute: changed) }
    }

    func stop() {
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        if let appearanceObserver { DistributedNotificationCenter.default().removeObserver(appearanceObserver) }
        powerSource = nil
        appearanceObserver = nil
        wifi.stop()
        privacy.stop()
        watchesWiFi = false
        watchesPrivacy = false
    }
}
