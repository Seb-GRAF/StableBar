import Foundation

/// The macOS version used for feature availability, replaceable in tests and offscreen scenes.
struct MacOSVersion: Sendable {
    var major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

    /// Notification clearance depends on the Accessibility structure introduced in macOS 26.
    var supportsNotificationClearance: Bool { major >= 26 }
}
