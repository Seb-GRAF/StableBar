import Foundation
import IOKit
import IOKit.ps

/// The internal battery's charge and state from IOKit, and whether Low Power Mode is on. Its run
/// loop source fires when the power source, the charge or the time remaining changes, and macOS
/// posts a notification when Low Power Mode changes.
final class PowerMonitor: ChangeMonitor, @unchecked Sendable {
    // `start` and `stop` run on the main actor, and the run loop source calls back on the main run
    // loop, so `source`, `changed` and `lowPowerObserver` are only touched on the main thread. The
    // Low Power Mode notification can arrive on any thread, and `relay` hops to the main queue.
    private var source: CFRunLoopSource?
    private var changed: (@Sendable () -> Void)?
    private let relay = MainQueueRelay()
    private var lowPowerObserver: NSObjectProtocol?

    deinit { stop() }

    func read() throws -> ScriptOutput {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            throw CommandFailure(message: "Could not read power sources.")
        }
        var output = ScriptOutput(text: "AC", icon: "powerplug", fields: ["state": "ac", "present": "false"], values: [:])
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               let battery = Self.output(battery: description) {
                output = battery
                output.fields?.merge(Self.fields(smartBattery: Self.smartBatteryProperties())) { $1 }
                break
            }
        }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        output.fields?["lowPower"] = String(lowPower)
        output.values?["lowPower"] = lowPower ? 1 : 0
        return output
    }

    /// The cycle count and the maximum capacity that System Settings shows under Battery Health, from
    /// the `AppleSmartBattery` registry entry's `properties`. The capacity is the charge the battery
    /// holds when full as a whole percentage of its design capacity, rounded up as System Settings does.
    static func fields(smartBattery properties: [String: Any]) -> [String: String] {
        // Recent macOS releases keep the capacities only under `BatteryData`, earlier ones at the top level.
        func number(_ key: String) -> Int? {
            (properties["BatteryData"] as? [String: Any])?[key] as? Int ?? properties[key] as? Int
        }
        var fields: [String: String] = [:]
        if let cycles = number("CycleCount") { fields["cycles"] = String(cycles) }
        if let nominal = number("NominalChargeCapacity"), let design = number("DesignCapacity"), design > 0 {
            fields["capacity"] = String(Int((Double(nominal * 100) / Double(design)).rounded(.up)))
        }
        return fields
    }

    private static func smartBatteryProperties() -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0)
        return properties?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    /// Whether this Mac has an internal battery. A Mac mini, Mac Studio, iMac or Mac Pro has none, at most a UPS.
    static func hasInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return hasInternalBattery(in: sources.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] })
    }

    /// Whether one of these power source descriptions is an internal battery.
    static func hasInternalBattery(in descriptions: [[String: Any]]) -> Bool {
        descriptions.contains { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
    }

    /// The output for a power source's `description`, or nil when it isn't the internal battery.
    /// Its icon shows the charge in quarters, its tooltip the percentage and what the battery is
    /// doing, and its `health` field is `service` when macOS recommends servicing the battery.
    static func output(battery description: [String: Any]) -> ScriptOutput? {
        guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let current = description[kIOPSCurrentCapacityKey] as? Double,
              let maximum = description[kIOPSMaxCapacityKey] as? Double, maximum > 0 else { return nil }
        let percent = min(max(current / maximum, 0), 1)
        let whole = Int((percent * 100).rounded())
        let charging = description[kIOPSIsChargingKey] as? Bool == true
        let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        // macOS reports -1 minutes while it estimates, and 0 once there's nothing left to estimate.
        let minutes = description[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
        // macOS sets the condition when it recommends service, which System Settings shows as the
        // battery's condition. `BatteryHealth` can read "Check Battery" while that says Normal, so
        // only its documented Poor counts.
        let condition = description[kIOPSBatteryHealthConditionKey] as? String ?? ""
        let needsService = !condition.isEmpty || description[kIOPSBatteryHealthKey] as? String == kIOPSPoorValue
        let state = charging ? "charging" : (onAC ? "charged" : "battery")
        var fields = ["state": state, "present": "true", "percent": String(whole), "health": needsService ? "service" : "normal"]
        if let minutes, minutes >= 0 { fields["timeRemaining"] = String(minutes) }
        let estimate = minutes.flatMap { $0 > 0 ? duration($0) : nil }
        let quarter = Int((percent * 4).rounded()) * 25
        var tooltip = switch state {
        case "charging": estimate.map { "\(whole)%, charging, full in \($0)" } ?? "\(whole)%, charging"
        case "charged": description[kIOPSIsChargedKey] as? Bool == true || whole == 100 ? "\(whole)%, charged" : "\(whole)%, plugged in, not charging"
        default: estimate.map { "\(whole)%, \($0) left" } ?? "\(whole)%"
        }
        if needsService { tooltip += "\nService recommended" }
        return ScriptOutput(text: "\(whole)%", icon: charging ? "battery.100percent.bolt" : "battery.\(quarter)percent", tooltip: tooltip,
                            value: percent, fields: fields, values: ["percent": percent])
    }

    /// `minutes` as hours and minutes, such as 1:05.
    private static func duration(_ minutes: Int) -> String {
        "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }

    func start(changed: @escaping @Sendable () -> Void) throws {
        stop()
        self.changed = changed
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().changed?()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else {
            self.changed = nil
            throw CommandFailure(message: "Could not watch power sources.")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
        relay.start(changed)
        lowPowerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.relay.notify()
        }
    }

    /// Removes and invalidates the run loop source and stops watching Low Power Mode. Stopping a
    /// monitor that isn't listening does nothing, and `start` listens again with a new source.
    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        source = nil
        changed = nil
        relay.stop()
        if let lowPowerObserver { NotificationCenter.default.removeObserver(lowPowerObserver) }
        lowPowerObserver = nil
    }
}
