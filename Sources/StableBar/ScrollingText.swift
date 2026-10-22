import AppKit
import SwiftUI

struct ScrollingText: View {
    let text: String
    let font: Font
    let fontSize: Double
    let speed: Double
    @State private var textWidth = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.measuringBarWidths) private var measuring

    var body: some View {
        // As wide as the text, or as the offered width when the text is wider, so a short text
        // leaves no gap after it within a block's maxWidth.
        Text(text)
            .font(font)
            .fixedSize()
            .hidden()
            .background {
                GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.width, initial: true) { textWidth = geometry.size.width }
                }
            }
            .frame(minWidth: 0, alignment: .leading)
            .frame(height: fontSize * 1.3)
            .overlay {
                GeometryReader { geometry in
                    let distance = max(textWidth - geometry.size.width, 0)
                    if reduceMotion || measuring || distance == 0 {
                        Text(text).font(font).fixedSize()
                    } else {
                        ScrollingTextLayer(text: Text(text).font(font), distance: distance, speed: speed)
                            .frame(width: textWidth, height: fontSize * 1.3)
                    }
                }
            }
            .clipped()
    }
}

private struct ScrollingTextLayer: NSViewRepresentable {
    let text: Text
    let distance: Double
    let speed: Double

    func makeNSView(context: Context) -> ScrollingTextView {
        let view = ScrollingTextView(rootView: AnyView(EmptyView()))
        view.sizingOptions = []
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: ScrollingTextView, context: Context) {
        view.rootView = AnyView(text.fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .environment(\.self, context.environment))
        guard view.text != text || view.distance != distance || view.speed != speed else { return }
        view.text = text
        view.distance = distance
        view.speed = speed
        let travel = distance / speed
        let duration = travel * 2 + 2
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, -distance, -distance, 0]
        animation.keyTimes = [0, 1 / duration, (travel + 1) / duration, (travel + 2) / duration, 1].map { NSNumber(value: $0) }
        let easing = CAMediaTimingFunction(controlPoints: 1 / 3, 0, 2 / 3, 1)
        animation.timingFunctions = [CAMediaTimingFunction(name: .linear), easing, CAMediaTimingFunction(name: .linear), easing]
        animation.duration = duration
        animation.repeatCount = .infinity
        view.layer!.add(animation, forKey: "scroll")
    }
}

private final class ScrollingTextView: NSHostingView<AnyView> {
    var text: Text?
    var distance = 0.0
    var speed = 0.0
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
