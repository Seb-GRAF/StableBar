import Foundation
import IOKit.ps

/// The internal battery's charge and state from IOKit. Its run loop source fires when the power
/// source, the charge or the time remaining changes.
final class PowerMonitor: ChangeMonitor, @unchecked Sendable {
    // `start` and `stop` run on the main actor, and the run loop source calls back on the main run
    // loop, so `source` and `changed` are only touched on the main thread.
    private var source: CFRunLoopSource?
    private var changed: (@Sendable () -> Void)?

    deinit { stop() }

    func read() throws -> ScriptOutput {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            throw CommandFailure(message: "Could not read power sources.")
        }
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               let output = Self.output(battery: description) {
                return output
            }
        }
        return ScriptOutput(text: "AC", icon: "powerplug", fields: ["state": "ac", "present": "false"])
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
    }

    /// Removes and invalidates the run loop source. Stopping a monitor that isn't listening does
    /// nothing, and `start` listens again with a new source.
    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        source = nil
        changed = nil
    }
}
