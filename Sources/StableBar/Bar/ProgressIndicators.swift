import SwiftUI

struct ProgressRule: View {
    let value: Double
    let target: Double?
    let animation: WidgetAnimation
    let color: Color
    let track: AnyShapeStyle
    let cornerRadius: Double
    @State private var fraction = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.measuringBarWidths) private var measuring

    var body: some View {
        let still = reduceMotion || measuring
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius).fill(track)
                RoundedRectangle(cornerRadius: cornerRadius).fill(color)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .task(id: ProgressUpdate(value: value, target: target, animation: animation, reduceMotion: still)) {
            if let target, !still {
                withAnimation(nil) { fraction = progressFraction(value) }
                await Task.yield()
                if !Task.isCancelled { withAnimation(animation.value) { fraction = progressFraction(target) } }
            } else {
                withAnimation(still ? nil : animation.value) { fraction = progressFraction(value) }
            }
        }
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(progressFraction(value) * 100)) percent")
    }
}

struct ProgressRing: View {
    let value: Double
    let animation: WidgetAnimation
    let color: Color
    let track: AnyShapeStyle
    let lineWidth: Double
    let gap: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fraction = progressFraction(value)
        let arc = 1 - gap / 360
        ZStack {
            Circle().inset(by: lineWidth / 2).trim(from: 0, to: arc)
                .stroke(track, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle().inset(by: lineWidth / 2).trim(from: 0, to: fraction * arc)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .animation(reduceMotion ? nil : animation.value, value: fraction)
        }
        // A circle's path starts at three o'clock: turn its start to the top, or to the gap's left end.
        .rotationEffect(.degrees(gap > 0 ? 90 + gap / 2 : -90))
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

struct ProgressSegments: View {
    let value: Double
    let count: Int
    let color: Color
    let track: AnyShapeStyle
    let spacing: Double
    let cornerRadius: Double

    var body: some View {
        let lit = litSegments(value, of: count)
        HStack(spacing: spacing) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: cornerRadius).fill(index < lit ? AnyShapeStyle(color) : track)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(progressFraction(value) * 100)) percent")
    }
}

/// `ceil(value × count)`, compared piece by piece so that 0.3 of 10 lights 3 pieces: 0.3 × 10 is just over 3 in floating point.
func litSegments(_ value: Double, of count: Int) -> Int {
    let fraction = progressFraction(value)
    return (0..<count).count { fraction > Double($0) / Double(count) }
}

func progressFraction(_ value: Double) -> Double {
    value.isFinite ? min(max(value, 0), 1) : 0
}

private struct ProgressUpdate: Equatable {
    let value: Double
    let target: Double?
    let animation: WidgetAnimation
    let reduceMotion: Bool
}
