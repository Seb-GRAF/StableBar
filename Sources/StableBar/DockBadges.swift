import AppKit
import ApplicationServices
import SwiftUI

/// How a workspace's app icons show an app's Dock badge.
enum DockBadgeStyle: String, Decodable, Sendable {
    case dot, count

    /// The text beside a small icon for the Dock's label: none in a dot, and a long label cut to three characters.
    func text(for label: String) -> String? {
        guard self == .count else { return nil }
        if let number = Int(label) { return number > 99 ? "99+" : label }
        return label.count > 3 ? label.prefix(2) + "…" : label
    }
}

/// The Dock's badges for the workspace app icons, by bundle identifier.
@MainActor @Observable
final class DockBadges {
    var labels: [String: String] = [:]
    /// Whether a bar that someone can see shows badges. The Dock posts nothing when a badge changes, so they're read
    /// again every few seconds.
    @ObservationIgnored var isWatching = false {
        didSet {
            guard isWatching != oldValue else { return }
            task?.cancel()
            task = isWatching ? Task { [weak self] in
                while !Task.isCancelled {
                    let labels = await Task.detached(priority: .utility) { readDockBadges() }.value
                    guard !Task.isCancelled, let self else { return }
                    if let labels, labels != self.labels { self.labels = labels }
                    try? await Task.sleep(for: .seconds(5))
                }
            } : nil
        }
    }
    @ObservationIgnored private var task: Task<Void, Never>?
}

/// Reads each app's badge from the Dock's own tiles through Accessibility: macOS has no API for another app's badge.
/// Nil when the Dock can't be read right now, which says nothing about its badges; without Accessibility access
/// there are none to show.
private func readDockBadges() -> [String: String]? {
    struct Unreadable: Error {}
    /// An element's attribute, nil when it has none. Throws when the Dock doesn't answer.
    func value(_ name: String, of element: AXUIElement) throws -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
        case .success: return value
        case .noValue, .attributeUnsupported: return nil
        default: throw Unreadable()
        }
    }
    func children(of element: AXUIElement) throws -> [AXUIElement] {
        guard let children = try value(kAXChildrenAttribute, of: element) as? [AXUIElement] else { throw Unreadable() }
        return children
    }
    guard AXIsProcessTrusted() else { return [:] }
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
    do {
        var labels: [String: String] = [:]
        for list in try children(of: AXUIElementCreateApplication(dock.processIdentifier))
        where try value(kAXRoleAttribute, of: list) as? String == kAXListRole {
            for tile in try children(of: list) where try value(kAXSubroleAttribute, of: tile) as? String == "AXApplicationDockItem" {
                guard let label = try value("AXStatusLabel", of: tile) as? String, !label.isEmpty,
                      let url = try value(kAXURLAttribute, of: tile) as? URL, let id = Bundle(url: url)?.bundleIdentifier else { continue }
                labels[id] = label
            }
        }
        return labels
    } catch {
        return nil
    }
}

/// The badge at an app icon's top trailing corner, sized to the icon: a dot, or the Dock's label in a capsule.
struct DockBadge: View {
    let style: DockBadgeStyle
    let label: String
    /// The icon's height, 14 points by default.
    let iconHeight: CGFloat

    var body: some View {
        let scale = iconHeight / 14
        Group {
            if let text = style.text(for: label) {
                Text(text)
                    .font(.system(size: 7 * scale, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 2 * scale)
                    .frame(minWidth: 9 * scale, minHeight: 9 * scale, maxHeight: 9 * scale)
                    .background(Color(nsColor: .systemRed), in: Capsule())
            } else {
                Circle().fill(Color(nsColor: .systemRed))
                    .frame(width: 6 * scale, height: 6 * scale)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
