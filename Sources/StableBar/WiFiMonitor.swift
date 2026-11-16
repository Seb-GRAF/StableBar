import CoreLocation
import CoreWLAN
import Foundation

/// The default Wi-Fi interface as CoreWLAN reports it.
struct WiFiState: Equatable, Sendable {
    var interface: String
    /// Nil without a network, or without Location access.
    var ssid: String?
    var power: Bool
    /// dBm; nil without a network.
    var rssi: Int?
}

/// The default Wi-Fi interface from CoreWLAN, whose client reports when the network, the link, its
/// quality or the power changes. Since macOS 14, CoreWLAN gives the network's name only to apps
/// allowed to use Location Services, so the first read asks for that access.
final class WiFiMonitor: NSObject, ChangeMonitor, CWEventDelegate, CLLocationManagerDelegate, @unchecked Sendable {
    // `read`, `start` and `stop` run on the main actor. CoreWLAN calls the delegate on its own
    // queue, and `relay` hops to the main queue.
    private let client = CWWiFiClient()
    private let relay = MainQueueRelay()
    private lazy var location: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
        return manager
    }()

    deinit { stop() }

    func read() throws -> ScriptOutput {
        guard let interface = client.interface(), let name = interface.interfaceName else {
            throw CommandFailure(message: "This Mac has no Wi-Fi interface.")
        }
        // CoreWLAN reports an RSSI of 0 while the interface isn't on a network.
        let rssi = interface.rssiValue()
        return Self.output(WiFiState(interface: name, ssid: interface.ssid(), power: interface.powerOn(), rssi: rssi == 0 ? nil : rssi),
                           access: location.authorizationStatus)
    }

    /// The output for `state` with Location access `access`. `values.signal` is 0 at -100 dBm and
    /// below, and 1 at -50 dBm and above.
    static func output(_ state: WiFiState, access: CLAuthorizationStatus) -> ScriptOutput {
        var fields = ["ssid": state.ssid ?? "", "interface": state.interface, "power": state.power ? "on" : "off",
                      "access": access == .authorizedAlways ? "granted" : access == .notDetermined ? "notDetermined" : "denied"]
        if let rssi = state.rssi { fields["rssi"] = String(rssi) }
        let signal = state.rssi.map { min(1, max(0, Double($0 + 100) / 50)) } ?? 0
        return ScriptOutput(text: state.ssid ?? "", icon: state.power ? "wifi" : "wifi.slash", fields: fields,
                            values: ["signal": signal, "power": state.power ? 1 : 0])
    }

    func start(changed: @escaping @Sendable () -> Void) throws {
        stop()
        relay.start(changed)
        client.delegate = self
        for event in [CWEventType.ssidDidChange, .linkDidChange, .linkQualityDidChange, .powerDidChange] {
            try client.startMonitoringEvent(with: event)
        }
    }

    func stop() {
        relay.stop()
        try? client.stopMonitoringAllEvents()
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { relay.notify() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { relay.notify() }
    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) { relay.notify() }
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { relay.notify() }
    /// Reads again once access is granted, to show the network's name.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { relay.notify() }
}
