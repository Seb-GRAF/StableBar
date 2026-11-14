import AppKit
import SwiftUI

/// Where a filled slider's fill ends and which value a pointer picks. The fill is at least as wide as the bar is tall,
/// so a glyph at its leading end always sits on it, and its trailing end, a cap as wide as the bar is tall, follows the
/// pointer, as a knob would.
struct FilledSliderTrack: Equatable {
    let width: Double
    let height: Double
    let minimum: Double
    let maximum: Double
    let step: Double

    /// The step nearest `value`, within `minimum`…`maximum`.
    func stepped(_ value: Double) -> Double {
        let clamped = min(max(value, minimum), maximum)
        return min(minimum + ((clamped - minimum) / step).rounded() * step, maximum)
    }

    func fillWidth(for value: Double) -> Double {
        let fraction = (stepped(value) - minimum) / (maximum - minimum)
        return min(height, width) + fraction * max(width - height, 0)
    }

    /// The value whose fill ends with its cap centered under a pointer at `x`.
    func value(at x: Double) -> Double {
        let fraction = (x - height / 2) / max(width - height, 1)
        return stepped(minimum + fraction * (maximum - minimum))
    }

    /// The value one step after or before `value`, for the arrow keys and VoiceOver.
    func value(after value: Double, forward: Bool) -> Double {
        stepped(stepped(value) + (forward ? step : -step))
    }
}

/// A slider drawn as a bar in the block's style rather than macOS's control: its background is the track, the
/// accent fills it from the leading edge, and an optional symbol sits on the fill in the accent's text color.
/// Clicking or dragging anywhere sets the value. It sends its value when the drag ends, as the native slider does.
struct FilledSlider: View {
    let title: String
    let value: Double
    let minimum: Double
    let maximum: Double
    let step: Double
    let icon: String?
    let height: Double
    /// Whether the block draws no track of its own, so the slider draws a faint one.
    let drawsTrack: Bool
    let appearance: WidgetAppearance
    let onChange: (Double) -> Void
    @State private var dragged: Double?
    @State private var editing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: Double { dragged ?? value }

    private var steps: FilledSliderTrack {
        FilledSliderTrack(width: 0, height: 0, minimum: minimum, maximum: maximum, step: step)
    }

    var body: some View {
        let radius = min(appearance.cornerRadius, height / 2)
        GeometryReader { geometry in
            let track = FilledSliderTrack(width: geometry.size.width, height: height, minimum: minimum, maximum: maximum, step: step)
            ZStack(alignment: .leading) {
                if drawsTrack {
                    RoundedRectangle(cornerRadius: radius).fill(appearance.foreground.opacity(0.12))
                }
                RoundedRectangle(cornerRadius: radius)
                    .fill(appearance.accent)
                    .frame(width: track.fillWidth(for: shown))
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: appearance.iconSize))
                        .foregroundStyle(appearance.accentText)
                        .frame(width: min(height, geometry.size.width), height: height)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: geometry.size.width, height: height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    editing = true
                    dragged = track.value(at: drag.location.x)
                }
                .onEnded { _ in
                    editing = false
                    if let dragged { onChange(dragged) }
                })
        }
        .frame(minWidth: height * 2, maxWidth: .infinity)
        .frame(height: height)
        .focusable(interactions: .activate)
        .modifier(FocusHighlight(appearance: appearance))
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            commit(steps.value(after: shown, forward: press.key == .rightArrow || press.key == .upArrow))
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(steps.stepped(shown).formatted())
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: commit(steps.value(after: shown, forward: true))
            case .decrement: commit(steps.value(after: shown, forward: false))
            @unknown default: break
            }
        }
        .onChange(of: value) { if !editing { dragged = nil } }
        .preference(key: ControlEditingPreference.self, value: editing)
    }

    /// A keyboard or VoiceOver step, which applies at once.
    private func commit(_ next: Double) {
        guard next != steps.stepped(shown) else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { dragged = next }
        onChange(next)
    }
}
