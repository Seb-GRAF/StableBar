import SwiftUI

/// A slider's steps, and whether a tick under each would stay apart from the next.
struct SliderSteps: Equatable {
    /// About as wide as the native knob, whose center stops half of it short of each end of the track.
    static let knobWidth = 20.0

    let range: ClosedRange<Double>
    let step: Double

    /// Whether a tick under every step stays at least `EndStopSliderTrack.minimumTickSpacing` from the next on a
    /// slider `width` points wide.
    func ticksFit(width: Double) -> Bool {
        let gaps = ((range.upperBound - range.lowerBound) / step + 1e-9).rounded(.down)
        guard gaps > 1 else { return true }
        return (width - Self.knobWidth) / gaps >= EndStopSliderTrack.minimumTickSpacing
    }

    /// The step nearest `value`, within the range.
    func stepped(_ value: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return min(range.lowerBound + ((clamped - range.lowerBound) / step).rounded() * step, range.upperBound)
    }
}

/// A native slider that moves in steps of `step`. macOS 26 and later draw a tick under every step of a native slider,
/// so when the ticks would run together into a dotted line, the slider is given no step and its binding rounds to
/// the nearest step instead. Its arrow keys then move it by a twentieth of its range rather than one step.
struct SteppedSlider<Label: View>: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: Label
    let onEditingChanged: (Bool) -> Void
    @State private var width: Double?
    @State private var labelWidth = 0.0

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double, @ViewBuilder label: () -> Label,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value
        self.range = range
        self.step = step
        self.label = label()
        self.onEditingChanged = onEditingChanged
    }

    private var steps: SliderSteps { SliderSteps(range: range, step: step) }

    var body: some View {
        Group {
            // Until it's measured, assume the ticks don't fit, as they don't for most of its steps.
            if let width, steps.ticksFit(width: width - labelWidth) {
                Slider(value: $value, in: range, step: step) { measuredLabel } onEditingChanged: { onEditingChanged($0) }
            } else {
                Slider(value: Binding(get: { value }, set: { value = steps.stepped($0) }), in: range) {
                    measuredLabel
                } onEditingChanged: { onEditingChanged($0) }
            }
        }
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
    }

    /// The label beside the track, which takes its width from the track. Hidden labels aren't laid out.
    private var measuredLabel: some View {
        label.onGeometryChange(for: Double.self) { $0.size.width } action: { labelWidth = $0 }
    }
}

extension SteppedSlider where Label == EmptyView {
    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double) {
        self.init(value: value, in: range, step: step) { EmptyView() }
    }
}
