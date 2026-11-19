import AppKit
import SwiftUI

/// Four bars that bounce at their own pace while `playing`, as in a music player, and settle low
/// when it stops. Reduce Motion and the bar's measuring copy keep them still.
struct Equalizer: View {
    let playing: Bool
    let height: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.measuringBarWidths) private var measuring

    /// Each bar's period in seconds and its phase, so no two bars move together.
    static let bars: [(period: Double, phase: Double)] = [(1.56, 0.4), (2.1, 2.3), (1.32, 4.1), (1.84, 1.2)]
    /// The bars' heights, as fractions of `height`, while playing without motion.
    static let still: [Double] = [0.55, 1, 0.4, 0.75]
    /// Every bar's height, as a fraction of `height`, when not playing.
    static let settled = 0.22

    var body: some View {
        Group {
            if reduceMotion || measuring {
                HStack(alignment: .bottom, spacing: height / 6) {
                    ForEach(Self.bars.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: height / 12)
                            .fill(.foreground)
                            .frame(width: height / 6, height: height * fraction(index, at: .now, still: true))
                    }
                }
                .frame(height: height, alignment: .bottom)
            } else {
                EqualizerLayer(equalizer: self)
                    .frame(width: height * 7 / 6, height: height)
            }
        }
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

private struct EqualizerLayer: NSViewRepresentable {
    let equalizer: Equalizer

    func makeNSView(context: Context) -> EqualizerView {
        let view = EqualizerView(rootView: AnyView(EmptyView()))
        view.sizingOptions = []
        view.wantsLayer = true
        let mask = CALayer()
        for _ in Equalizer.bars {
            let bar = CALayer()
            bar.backgroundColor = .black
            bar.anchorPoint = CGPoint(x: 0, y: 1)
            bar.cornerCurve = .continuous
            mask.addSublayer(bar)
        }
        view.layer!.mask = mask
        return view
    }

    func updateNSView(_ view: EqualizerView, context: Context) {
        view.rootView = AnyView(Rectangle().fill(.foreground).environment(\.self, context.nestedEnvironment))
        guard view.playing != equalizer.playing || view.height != equalizer.height else { return }
        let toggled = view.playing != nil && view.playing != equalizer.playing
        view.playing = equalizer.playing
        let height = equalizer.height
        view.height = height
        let scale = context.environment.displayScale
        let mask = view.layer!.mask!
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = CGRect(x: 0, y: 0, width: height * 7 / 6, height: height)
        for (index, bar) in mask.sublayers!.enumerated() {
            let from = (bar.presentation() ?? bar).bounds.height
            bar.removeAllAnimations()
            let loop = Equalizer.bars[index].period * 10
            let frames = Int(loop * 30)
            let heights = (0...frames).map {
                let date = Date(timeIntervalSinceReferenceDate: loop * Double($0) / Double(frames))
                return (height * equalizer.fraction(index, at: date, still: false) * scale).rounded() / scale
            }
            bar.cornerRadius = height / 12
            bar.position = CGPoint(x: Double(index) * height / 3, y: height)
            bar.bounds = CGRect(x: 0, y: 0, width: height / 6, height: heights[0])
            if toggled {
                let settle = CABasicAnimation(keyPath: "bounds.size.height")
                settle.fromValue = from
                settle.duration = 0.35
                settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.add(settle, forKey: "settle")
            }
            if equalizer.playing {
                let bounce = CAKeyframeAnimation(keyPath: "bounds.size.height")
                bounce.values = heights
                bounce.duration = loop
                bounce.repeatCount = .infinity
                bounce.beginTime = CACurrentMediaTime() + (toggled ? 0.35 : 0)
                bar.add(bounce, forKey: "bounce")
            }
        }
        CATransaction.commit()
    }
}

private final class EqualizerView: NSHostingView<AnyView> {
    var playing: Bool?
    var height = 0.0
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
