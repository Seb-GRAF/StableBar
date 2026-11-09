import AppKit

/// The text a view shows, as its accessibility tree reports it: SwiftUI's `Text` and AppKit's text fields alike.
/// Collecting `NSTextField`s alone misses SwiftUI text that isn't drawn by one, as on macOS 27.
@MainActor func visibleText(_ view: NSView) -> [String] {
    var text: [String] = []
    var seen = Set<ObjectIdentifier>()
    // The getters are called by selector: the SDK imports some of them as methods and some as properties, and
    // SwiftUI's elements aren't all NSAccessibilityElements.
    func attribute(_ object: NSObject, _ getter: String) -> Any? {
        let selector = NSSelectorFromString(getter)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    func visit(_ object: Any, depth: Int) {
        guard depth < 80, let object = object as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
        if let field = object as? NSTextField {
            text.append(field.stringValue)
            if let placeholder = field.placeholderString { text.append(placeholder) }
        }
        for getter in ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"] {
            if let string = attribute(object, getter) as? String, !string.isEmpty { text.append(string) }
        }
        for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
        if let view = object as? NSView {
            for subview in view.subviews { visit(subview, depth: depth + 1) }
        }
    }
    visit(view, depth: 0)
    return text
}
