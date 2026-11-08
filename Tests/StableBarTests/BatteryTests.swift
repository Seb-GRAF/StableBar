import AppKit
import Foundation
import IOKit.ps
import SwiftUI
import Testing
@testable import StableBar

/// An internal battery's description as IOKit gives it, with `extra` keys over a battery at 62 %
/// on battery power with 3:20 left.
private func battery(_ extra: [String: Any] = [:]) -> [String: Any] {
    var description: [String: Any] = [
        kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: NSNumber(value: 62), kIOPSMaxCapacityKey: NSNumber(value: 100),
        kIOPSIsChargingKey: NSNumber(value: false), kIOPSIsChargedKey: NSNumber(value: false), kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
        kIOPSTimeToEmptyKey: NSNumber(value: 200), kIOPSTimeToFullChargeKey: NSNumber(value: 0),
        kIOPSBatteryHealthKey: kIOPSGoodValue, kIOPSBatteryHealthConditionKey: ""
    ]
    description.merge(extra) { $1 }
    return description
}

@Test func batteryOutputShowsTheChargeInItsIconAndTheRestInItsTooltip() throws {
    let discharging = try #require(PowerMonitor.output(battery: battery()))
    #expect(discharging.text == "62%" && discharging.icon == "battery.50percent" && discharging.tooltip == "62%, 3:20 left")
    #expect(discharging.fields == ["state": "battery", "present": "true", "percent": "62", "health": "normal", "timeRemaining": "200"])
    #expect(discharging.values == ["percent": 0.62] && discharging.value == 0.62)

    let charging = try #require(PowerMonitor.output(battery: battery([kIOPSIsChargingKey: NSNumber(value: true), kIOPSPowerSourceStateKey: kIOPSACPowerValue,
                                                                     kIOPSCurrentCapacityKey: NSNumber(value: 45), kIOPSTimeToFullChargeKey: NSNumber(value: 65)])))
    #expect(charging.icon == "battery.100percent.bolt" && charging.tooltip == "45%, charging, full in 1:05" && charging.fields?["state"] == "charging")

    let held = try #require(PowerMonitor.output(battery: battery([kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSCurrentCapacityKey: NSNumber(value: 80)])))
    #expect(held.icon == "battery.75percent" && held.tooltip == "80%, plugged in, not charging" && held.fields?["state"] == "charged")
    let full = try #require(PowerMonitor.output(battery: battery([kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSIsChargedKey: NSNumber(value: true),
                                                                 kIOPSCurrentCapacityKey: NSNumber(value: 100)])))
    #expect(full.icon == "battery.100percent" && full.tooltip == "100%, charged")

    let estimating = try #require(PowerMonitor.output(battery: battery([kIOPSTimeToEmptyKey: NSNumber(value: -1), kIOPSCurrentCapacityKey: NSNumber(value: 8)])))
    #expect(estimating.icon == "battery.0percent" && estimating.tooltip == "8%" && estimating.fields?["timeRemaining"] == nil)
    #expect(PowerMonitor.output(battery: battery([kIOPSTypeKey: kIOPSUPSType])) == nil)
}

@Test func batteryHealthFollowsTheConditionSystemSettingsShows() throws {
    // A Mac whose System Settings shows a Normal condition reads "Check Battery" here.
    let normal = try #require(PowerMonitor.output(battery: battery([kIOPSBatteryHealthKey: kIOPSCheckBatteryValue])))
    #expect(normal.fields?["health"] == "normal" && normal.tooltip == "62%, 3:20 left")
    for extra: [String: Any] in [[kIOPSBatteryHealthConditionKey: kIOPSCheckBatteryValue], [kIOPSBatteryHealthConditionKey: kIOPSPermanentFailureValue],
                                 [kIOPSBatteryHealthKey: kIOPSPoorValue]] {
        let worn = try #require(PowerMonitor.output(battery: battery(extra)))
        #expect(worn.fields?["health"] == "service", "\(extra)")
        #expect(worn.tooltip == "62%, 3:20 left\nService recommended", "\(extra)")
    }
}

@Test func batteryBlocksReadTheChargeFromTheirSource() throws {
    func source(_ json: String) throws -> String? {
        guard case let .battery(source) = try JSONDecoder().decode(PopupBlock.self, from: Data(json.utf8)).content else { return nil }
        return source
    }
    #expect(try source(#"{"type":"battery"}"#) == "percent")
    #expect(try source(#"{"type":"battery","source":"left"}"#) == "left")
    let url = FileManager.default.temporaryDirectory.appending(path: "battery.json")
    var loader = ConfigurationLoader()
    let json = #"{"widgets":[{"id":"power","type":"battery","position":"right","layout":{"type":"battery","transition":"fade"}}]}"#
    let error = #expect(throws: (any Error).self) { try loader.load(url, data: Data(json.utf8)) }
    #expect(error.map(errorMessage) == "widgets.power: layout.transition: Transitions apply to text, field and symbol blocks.")
}

@Test func batteryWidgetsDrawOnlyTheirBatteryUnlessTheMacHasNone() throws {
    for named in [false, true] {
        let provider = named ? #""type":"provider","provider":"power""# : #""type":"battery""#
        let widget = try JSONDecoder().decode(StableBar.WidgetConfiguration.self, from: Data(#"{"id":"w",\#(provider),"position":"right"}"#.utf8))
        let output = try #require(PowerMonitor.output(battery: battery()))
        let layout = widget.defaultLayout(widget.label(output: output, activeApp: nil, date: .now), output: output, appIcon: false,
                                          providerType: named ? "battery" : nil)
        guard case let .row(children)? = layout?.content, children.count == 1, case .battery("percent") = children[0].content else {
            Issue.record("Expected only a battery, named: \(named)")
            continue
        }
        #expect(layout?.keepsLineHeight == true)

        let desktop = ScriptOutput(text: "AC", icon: "powerplug", fields: ["state": "ac", "present": "false"])
        let plug = widget.defaultLayout(widget.label(output: desktop, activeApp: nil, date: .now), output: desktop, appIcon: false,
                                        providerType: named ? "battery" : nil)
        guard case let .row(parts)? = plug?.content, case .row(let label) = parts.last?.content, label.count == 2,
              case .symbol = label[0].content, case .field("text") = label[1].content else {
            Issue.record("Expected the plug and AC, named: \(named)")
            continue
        }
    }
}

@Test func batteryDisplayStartsWithTheBatteryAloneAndUsesItAsTheIcon() {
    #expect(WidgetMetricDisplay.choices(for: "percent") == [.icon, .standard, .value, .meter, .graph, .custom])
    #expect(WidgetMetricDisplay.icon.layout(for: "percent") == .null)
    #expect(WidgetMetricDisplay.current(nil, source: "percent") == .icon)
    let battery: ConfigurationValue = .object(["type": .string("battery")])
    let text: ConfigurationValue = .object(["type": .string("field"), "field": .string("text")])
    #expect(WidgetMetricDisplay.standard.layout(for: "percent") == .object(["type": .string("row"), "children": .array([battery, text])]))
    for choice in WidgetMetricDisplay.choices(for: "percent") where choice != .custom {
        #expect(WidgetMetricDisplay.current(choice.layout(for: "percent"), source: "percent") == choice)
    }
}

/// The colors `glyph` draws at 2×, as RGBA bytes.
@MainActor private func pixels(_ glyph: BatteryGlyph) throws -> [(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)] {
    let renderer = ImageRenderer(content: glyph.foregroundStyle(.white))
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = UnsafeRawBufferPointer(start: try #require(context.data), count: image.width * image.height * 4)
    return stride(from: 0, to: bytes.count, by: 4).map { (bytes[$0], bytes[$0 + 1], bytes[$0 + 2], bytes[$0 + 3]) }
}

@Test @MainActor func batteryGlyphsFillWithTheChargeAndMarkPowerLowChargeAndService() throws {
    func lit(_ glyph: BatteryGlyph) throws -> Int { try pixels(glyph).filter { $0.alpha > 200 }.count }
    func red(_ glyph: BatteryGlyph) throws -> Int { try pixels(glyph).filter { $0.alpha > 200 && $0.red > 200 && $0.green < 120 && $0.blue < 120 }.count }
    func orange(_ glyph: BatteryGlyph) throws -> Int {
        try pixels(glyph).filter { $0.alpha > 200 && $0.red > 200 && (120...200).contains($0.green) && $0.blue < 100 }.count
    }
    let glyph = { (level: Double, power: BatteryGlyph.Power, service: Bool) in BatteryGlyph(level: level, power: power, needsService: service, iconSize: 13) }

    #expect(try lit(glyph(0.2, .battery, false)) < lit(glyph(0.6, .battery, false)))
    #expect(try lit(glyph(0.6, .battery, false)) < lit(glyph(1, .battery, false)))
    #expect(try red(glyph(0.08, .battery, false)) > 0, "A low battery fills red")
    #expect(try red(glyph(0.08, .charging, false)) == 0 && red(glyph(0.08, .plugged, false)) == 0, "Not while it has power")
    #expect(try red(glyph(0.5, .battery, false)) == 0)
    #expect(try orange(glyph(0.5, .battery, true)) > 0 && orange(glyph(0.5, .battery, false)) == 0, "Only a battery that needs service has a badge")

    let plain = try pixels(glyph(1, .battery, false)).map(\.alpha)
    let charging = try pixels(glyph(1, .charging, false)).map(\.alpha)
    let plugged = try pixels(glyph(1, .plugged, false)).map(\.alpha)
    #expect(plain.count == charging.count && plain.count == plugged.count, "Power doesn't change the glyph's size")
    #expect(plain != charging && plain != plugged && charging != plugged)
    #expect(glyph(1, .battery, true).size == glyph(1, .battery, false).size)

    let fields = BatteryGlyph(level: 0.4, fields: ["state": "charging", "health": "service"], iconSize: 13)
    #expect(fields.power == .charging && fields.needsService)
    #expect(fields.accessibilityLabel == "Battery 40 percent, charging, service recommended")
    #expect(BatteryGlyph(level: 0.4, fields: ["state": "charged"], iconSize: 13).power == .plugged)
    #expect(BatteryGlyph(level: 2, fields: [:], iconSize: 13).level == 1)
}

/// A Mac mini, Mac Studio, iMac or Mac Pro has no internal battery, at most a UPS, so Battery would only show "AC".
@Test func onlyAnInternalBatteryCountsAsTheMacsBattery() {
    #expect(PowerMonitor.hasInternalBattery(in: [[kIOPSTypeKey: kIOPSInternalBatteryType]]))
    #expect(!PowerMonitor.hasInternalBattery(in: [[kIOPSTypeKey: kIOPSUPSType]]))
    #expect(!PowerMonitor.hasInternalBattery(in: []))
}
