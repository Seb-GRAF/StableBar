import Foundation

/// The connected Bluetooth devices with the battery macOS reports for each. `system_profiler` lists them
/// without the Bluetooth access that IOBluetooth needs.
enum Bluetooth {
    static func read() async throws -> ScriptOutput {
        try output(json: await runCommand("/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"]))
    }

    /// The output for `system_profiler`'s JSON. Apple doesn't document its keys, so a device without the
    /// expected ones is still listed, with no battery.
    static func output(json: Data) throws -> ScriptOutput {
        let report = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        let controllers = report?["SPBluetoothDataType"] as? [[String: Any]] ?? []
        var rows: [[String: String]] = []
        var summary: [String] = []
        var lowest: Int?
        for (name, properties) in controllers.flatMap({ $0["device_connected"] as? [[String: [String: Any]]] ?? [] }).flatMap({ $0 }) {
            let minorType = properties["device_minorType"] as? String ?? ""
            let (kind, icon) = [("keyboard", "keyboard"), ("mouse", "computermouse"), ("trackpad", "rectangle.and.hand.point.up.left"),
                                ("headphones", "airpodspro")].first { minorType.localizedCaseInsensitiveContains($0.0) }
                ?? ("other", "dot.radiowaves.left.and.right")
            let levels = ["Main", "Left", "Right", "Case"].compactMap { part in
                (properties["device_batteryLevel\(part)"] as? String).flatMap { Int($0.replacing("%", with: "")) }
            }
            let level = levels.min()
            rows.append(["name": name, "kind": kind, "icon": icon, "battery": levels.map { "\($0)%" }.joined(separator: " · "),
                         "level": level.map(String.init) ?? "", "fraction": level.map { String(Double($0) / 100) } ?? ""])
            if let level {
                summary.append("\(name) \(level)%")
                lowest = min(lowest ?? level, level)
            }
        }
        return ScriptOutput(text: rows.isEmpty ? "" : String(rows.count), fields: ["summary": summary.joined(separator: " · ")], lists: ["devices": rows],
                            values: lowest.map { ["lowestBattery": Double($0) / 100] })
    }
}
