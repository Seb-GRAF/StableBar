/// The events StableBar knows. Widgets and providers subscribe to them with `events`, beside
/// distributed notification names. docs/create-a-widget.md lists the same events, in the same order,
/// in the table under "Script events"; `builtInEventsMatchTheGuideTable` checks it.
enum BuiltInEvent: String, CaseIterable, Sendable {
    case frontApp, workspace, aerospaceMode, wake, yabai, powerSourceChange, volumeChange, outputDeviceChange, microphoneChange,
         inputDeviceChange, privacyChange

    /// When StableBar sends the event: the table's "Sent when" column.
    var trigger: String {
        switch self {
        case .frontApp: "The frontmost app changes"
        case .workspace: "The focused workspace changes"
        case .aerospaceMode: "Initial connection, binding-mode change or disconnect"
        case .wake: "The Mac wakes from sleep"
        case .yabai: "`StableBar --trigger yabai` runs, usually from a yabai signal; StableBar also refreshes its workspaces"
        case .powerSourceChange: "The Mac switches between its power adapter and battery"
        case .volumeChange: "The default output device's volume or mute state changes"
        case .outputDeviceChange: "The default output device changes"
        case .microphoneChange: "The default input device's volume or mute state changes, or an app starts or stops recording from it"
        case .inputDeviceChange: "The default input device changes"
        case .privacyChange: "An app starts or stops using the microphone or a camera, or the microphone's mute state changes"
        }
    }

    /// What `INFO` holds: the table's `INFO` column.
    var info: String {
        switch self {
        case .frontApp: "The app's name, or `Desktop`"
        case .workspace: "The workspace's name; `SID` is its display number"
        case .aerospaceMode: "The mode's name; empty on disconnect, stop or a source switch"
        case .wake: "Not set"
        case .yabai: "The trigger's `INFO`, if any"
        case .powerSourceChange: "`ac` or `battery`"
        case .volumeChange: "The volume as a whole percentage, empty without a volume control; `MUTED` is `true` or `false`"
        case .outputDeviceChange, .inputDeviceChange: "The device's name, empty when there is none"
        case .microphoneChange: "The volume as a whole percentage, empty without a volume control; `MUTED` and `IN_USE` are `true` or `false`"
        case .privacyChange: "`true` while the microphone or a camera is in use, else `false`; `MICROPHONE`, `CAMERA` and `MUTED` are `true` or `false`"
        }
    }

    /// For an event a data source sends: the event's variables when that source's output changes
    /// from `previous` to `output`, or `nil` when the change doesn't send it.
    func variables(from previous: ScriptOutput, to output: ScriptOutput) -> [String: String]? {
        switch self {
        case .powerSourceChange:
            func source(_ output: ScriptOutput) -> String { output.fields?["state"] == "battery" ? "battery" : "ac" }
            return source(previous) == source(output) ? nil : ["INFO": source(output)]
        case .volumeChange:
            guard previous.values?["volume"] != output.values?["volume"] || previous.fields?["muted"] != output.fields?["muted"] else {
                return nil
            }
            return ["INFO": output.values?["volume"].map { String(Int(($0 * 100).rounded())) } ?? "",
                    "MUTED": output.fields?["muted"] ?? "false"]
        case .microphoneChange:
            guard previous.values?["volume"] != output.values?["volume"] || previous.fields?["muted"] != output.fields?["muted"]
                    || previous.fields?["inUse"] != output.fields?["inUse"] else { return nil }
            return ["INFO": output.values?["volume"].map { String(Int(($0 * 100).rounded())) } ?? "",
                    "MUTED": output.fields?["muted"] ?? "false", "IN_USE": output.fields?["inUse"] ?? "false"]
        case .outputDeviceChange, .inputDeviceChange:
            return previous.fields?["deviceID"] == output.fields?["deviceID"] ? nil : ["INFO": output.fields?["device"] ?? ""]
        case .privacyChange:
            guard ["microphone", "camera", "muted"].contains(where: { previous.fields?[$0] != output.fields?[$0] }) else { return nil }
            return ["INFO": String(output.fields?["microphone"] == "true" || output.fields?["camera"] == "true"),
                    "MICROPHONE": output.fields?["microphone"] ?? "false", "CAMERA": output.fields?["camera"] ?? "false",
                    "MUTED": output.fields?["muted"] ?? "false"]
        default:
            return nil
        }
    }
}
