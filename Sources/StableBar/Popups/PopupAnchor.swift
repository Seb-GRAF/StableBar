import AppKit
import SwiftUI

struct PopupAnchor: NSViewRepresentable {
    let view: NSView
    let popup: WidgetPopup
    var id: String?

    func makeNSView(context: Context) -> NSView {
        view.identifier = id.map { NSUserInterfaceItemIdentifier($0) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> WidgetPopup { popup }

    static func dismantleNSView(_ nsView: NSView, coordinator: WidgetPopup) {
        coordinator.removeAnchor(nsView)
    }
}
