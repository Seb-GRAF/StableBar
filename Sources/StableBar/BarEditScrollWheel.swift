import AppKit
import SwiftUI

/// Only wheel events are captured; clicks, drags and accessibility stay with the tiles.
/// Use measured sizes because SwiftUI's native scroll document can have empty bounds.
struct BarEditScrollWheel: NSViewRepresentable {
    let contentWidth: CGFloat
    let viewportWidth: CGFloat

    func makeNSView(context: Context) -> BarEditScrollWheelView { BarEditScrollWheelView() }
    func updateNSView(_ view: BarEditScrollWheelView, context: Context) {
        view.contentWidth = contentWidth
        view.viewportWidth = viewportWidth
    }
}

final class BarEditScrollWheelView: NSView {
    var contentWidth: CGFloat?
    var viewportWidth: CGFloat?

    override func hitTest(_ point: NSPoint) -> NSView? {
        NSApp?.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard let scroll = enclosingScrollView else {
            super.scrollWheel(with: event)
            return
        }
        let clip = scroll.contentView
        let x = BarEditOverflow.offset(from: clip.bounds.minX, deltaX: event.scrollingDeltaX,
                                       deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                                       contentWidth: contentWidth ?? scroll.documentView?.bounds.width ?? 0,
                                       viewportWidth: viewportWidth ?? clip.bounds.width)
        clip.scroll(to: CGPoint(x: x, y: clip.bounds.minY))
        scroll.reflectScrolledClipView(clip)
    }
}
