import SwiftUI

/// Four bars that bounce at their own pace while `playing`, as in a music player, and settle low
/// when it stops. Reduce Motion and the bar's measuring copy keep them still.
struct Equalizer: View {
    let playing: Bool
    let height: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.measuringBarWidths) private var measuring

    /// Each bar's period in seconds and its phase, so no two bars move together.
    private static let bars: [(period: Double, phase: Double)] = [(1.56, 0.4), (2.1, 2.3), (1.32, 4.1), (1.84, 1.2)]
    /// The bars' heights, as fractions of `height`, while playing without motion.
    static let still: [Double] = [0.55, 1, 0.4, 0.75]
    /// Every bar's height, as a fraction of `height`, when not playing.
    static let settled = 0.22

    var body: some View {
        let still = reduceMotion || measuring
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playing || still)) { context in
            HStack(alignment: .bottom, spacing: height / 6) {
                ForEach(Self.bars.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: height / 12)
                        .fill(.foreground)
                        .frame(width: height / 6, height: height * fraction(index, at: context.date, still: still))
                }
            }
            .frame(height: height, alignment: .bottom)
        }
        .animation(still ? nil : .easeOut(duration: 0.35), value: playing)
        .accessibilityLabel(playing ? "Playing" : "Paused")
    }

    /// Bar `index`'s height at `date`, as a fraction of `height`.
    func fraction(_ index: Int, at date: Date, still: Bool) -> Double {
        guard playing else { return Self.settled }
        guard !still else { return Self.still[index] }
        let bar = Self.bars[index]
        let angle = date.timeIntervalSinceReferenceDate / bar.period * 2 * .pi + bar.phase
        // Two waves at unrelated rates, so a bar doesn't repeat the same bounce.
        let wave = 0.65 * sin(angle) + 0.35 * sin(angle * 2.3 + bar.phase)
        return Self.settled + (1 - Self.settled) * (wave + 1) / 2
    }
}
