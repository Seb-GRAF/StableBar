import AppKit
import SwiftUI

/// A widget whose click opens a popup, as VoiceOver reads it: a button that tells whether its popup is open. SwiftUI
/// can't set that state, so an AppKit element stands in for the widget's button.
struct PopupButtonAccessibility: NSViewRepresentable {
    let label: String
    let value: () -> String
    let expanded: Bool
    let press: () -> Void

    func makeNSView(context: Context) -> PopupButtonAccessibilityView { PopupButtonAccessibilityView() }

    func updateNSView(_ view: PopupButtonAccessibilityView, context: Context) {
        view.label = label
        view.value = value
        view.expanded = expanded
        view.press = press
    }
}

final class PopupButtonAccessibilityView: NSView {
    var label = ""
    /// Read when VoiceOver asks, so a clock reads the current time.
    var value: () -> String = { "" }
    var expanded = false
    var press: () -> Void = {}

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityValue() -> Any? { value() }
    override func isAccessibilityExpanded() -> Bool { expanded }

    override func accessibilityPerformPress() -> Bool {
        press()
        return true
    }
}
