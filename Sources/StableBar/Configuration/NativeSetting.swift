import CoreWLAN

/// What a slider's or toggle's `set` changes without a command.
enum NativeSetting: String, Decodable, Sendable {
    case volume, muted, inputVolume, inputMuted, wifiPower

    /// Sets it to a control's `VALUE`: a slider's number, or a toggle's `true` or `false`. Blocking: CoreWLAN waits
    /// for the Wi-Fi hardware, so callers go through `BlockingWork.run`.
    func set(_ value: String) throws {
        switch self {
        case .volume: try AudioMonitor.setVolume(Double(value)!)
        case .muted: try AudioMonitor.setMuted(value == "true")
        case .inputVolume: try AudioMonitor.setVolume(Double(value)!, input: true)
        case .inputMuted: try AudioMonitor.setMuted(value == "true", input: true)
        case .wifiPower:
            guard let interface = CWWiFiClient.shared().interface() else { throw CommandFailure(message: "This Mac has no Wi-Fi.") }
            try interface.setPower(value == "true")
        }
    }
}
