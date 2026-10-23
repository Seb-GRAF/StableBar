import SwiftUI

struct NativeWidgetSettings: View {
    let editor: ConfigurationEditor
    let widget: WidgetConfiguration
    let provider: ProviderConfiguration

    var body: some View {
        Group {
            switch provider.type {
            case "system":
                SettingsGroup("Sampling") {
                    number("Refresh every", "interval", provider.interval, in: 1...60, unit: "s")
                    number("Apps to list", "processes", Double(provider.processes), in: 0...15, hint: "0 turns off app sampling")
                    SettingRow(title: "Sort apps by") {
                        Picker("Sort apps by", selection: Binding(get: { provider.sortBy }, set: {
                            editor.setProvider(["sortBy": .string($0.rawValue)], for: widget)
                        })) {
                            Text("Memory").tag(ProcessSort.memory)
                            Text("CPU").tag(ProcessSort.cpu)
                        }
                        .labelsHidden().frame(width: 160)
                    }
                }
                SettingsGroup("Warnings") {
                    number("CPU use", "cpuWarning", provider.cpuWarning, in: 0...101, unit: "%", scale: 100, hint: "101% turns off this warning")
                    number("Memory use", "memoryWarning", provider.memoryWarning, in: 0...101, unit: "%", scale: 100, hint: "Pressure and heat still warn")
                }
            case "network":
                SettingsGroup("Network activity") {
                    number("Refresh every", "interval", provider.interval, in: 1...60, unit: "s")
                    SettingRow(title: "Speed units") {
                        Picker("Speed units", selection: Binding(get: { provider.units }, set: {
                            editor.setProvider(["units": .string($0.rawValue)], for: widget)
                        })) {
                            Text("Bytes · KiB/s, MiB/s").tag(NetworkUnits.bytes)
                            Text("Bits · kbit/s, Mbit/s").tag(NetworkUnits.bits)
                        }
                        .labelsHidden().frame(width: 190)
                    }
                }
            case "calendar":
                SettingsGroup("Upcoming meetings") {
                    number("Look ahead", "lookahead", provider.lookahead, in: 1...168, unit: "h")
                    number("Upcoming warning", "soon", Double(provider.soon), in: 1...120, unit: "min")
                    number("Starting warning", "now", Double(provider.now), in: 0...60, unit: "min")
                }
            default: EmptyView()
            }
            if ["system", "network", "calendar"].contains(provider.type),
               editor.store.configuration!.widgets.filter({ $0.providerName == widget.providerName }).count > 1 {
                SettingsCallout(systemImage: "link", text: Text("These data settings apply to every widget using **\(widget.providerName!)**."))
                    .padding(.top, 12)
            }
        }
    }

    private func number(_ title: String, _ key: String, _ value: Double, in range: ClosedRange<Double>,
                        unit: String = "", scale: Double = 1, hint: String? = nil) -> some View {
        NumberDraft(value: Binding(get: { value * scale }, set: { editor.setProvider([key: .number($0 / scale)], for: widget) })) { value in
            SettingRow(title: title, scrub: Scrub(value: value, range: range), hint: hint) {
                NumberField(title: title, value: value, range: range, unit: unit)
            }
        }
    }
}
