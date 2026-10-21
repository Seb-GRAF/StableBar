import SwiftUI

struct ScrollingText: View {
    let text: String
    let font: Font
    let fontSize: Double
    let speed: Double
    @State private var textWidth = 0.0
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.measuringBarWidths) private var measuring

    var body: some View {
        // As wide as the text, or as the offered width when the text is wider, so a short text
        // leaves no gap after it within a block's maxWidth.
        Text(text)
            .font(font)
            .fixedSize()
            .hidden()
            .frame(minWidth: 0, alignment: .leading)
            .frame(height: fontSize * 1.3)
            .overlay {
                GeometryReader { geometry in
                    TimelineView(.animation(paused: reduceMotion || measuring || textWidth <= geometry.size.width)) { context in
                        let distance = max(textWidth - geometry.size.width, 0)
                        let travel = distance / speed
                        let elapsed = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: travel * 2 + 2)
                        let progress = distance == 0 ? 0 : min(max(elapsed - 1, 0) / travel, 1) - min(max(elapsed - travel - 2, 0) / travel, 1)
                        let offset = distance * progress * progress * (3 - 2 * progress)
                        Text(text)
                            .font(font)
                            .fixedSize()
                            .background {
                                GeometryReader { textGeometry in
                                    Color.clear.onChange(of: textGeometry.size.width, initial: true) { textWidth = textGeometry.size.width }
                                }
                            }
                            .offset(x: reduceMotion ? 0 : -offset)
                    }
                }
            }
            .clipped()
            .onChange(of: text) { start = Date() }
    }
}
