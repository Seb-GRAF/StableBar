import Foundation
import Network

/// How the Mac is connected: the path macOS sends traffic through, from the Network framework's path
/// monitor, which needs no permission. One monitor serves every network provider and posts
/// `changedNotification` each time the path changes.
@MainActor
final class NetworkConnection {
    static let shared = NetworkConnection()
    nonisolated static let changedNotification = Notification.Name("NetworkConnectionChanged")

    /// `connection` and `connectionIcon`, empty until the monitor first reports the path.
    private(set) var fields: [String: String] = [:]
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [self] path in
            let (connection, icon) = if path.status != .satisfied { ("offline", "wifi.slash") }
                else if path.usesInterfaceType(.wifi) { ("wifi", "wifi") }
                else if path.usesInterfaceType(.wiredEthernet) { ("ethernet", "cable.connector") }
                else { ("other", "network") }
            MainActor.assumeIsolated {
                fields = ["connection": connection, "connectionIcon": icon]
                NotificationCenter.default.post(name: Self.changedNotification, object: nil)
            }
        }
        monitor.start(queue: .main)
    }
}
