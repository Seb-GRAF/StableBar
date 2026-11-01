import AppKit
import SwiftUI

/// A slider block's last stop past `max`, set apart by a notch, such as ∞ after a range of minutes.
struct SliderEndStop: Decodable, Sendable, Equatable {
    /// What the slider sends as `VALUE` on the end stop, and the value of `source` that puts the knob there.
    let value: Double
    /// Drawn under the end stop, where the steps have dots, while the knob is elsewhere, and read by VoiceOver.
    let label: String

    enum CodingKeys: String, CodingKey, CaseIterable { case value, label }

    init(value: Double, label: String) {
        self.value = value
        self.label = label
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        value = try values.decode(Double.self, forKey: .value)
        label = try values.decode(String.self, forKey: .label)
        guard value.isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: values, debugDescription: "An end stop needs a finite value.")
        }
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .label, in: values, debugDescription: "An end stop needs a label, such as ∞.")
        }
    }
}

/// Where a slider with an end stop draws its steps, its notch and its end stop, and which stop a pointer picks.
/// Positions are knob centers in points from the slider's leading edge.
struct EndStopSliderTrack: Equatable {
    enum Stop: Equatable {
        case value(Double)
        case end
    }

    /// The gap between the last step and the end stop, with a hairline in its middle.
    static let notch = 8.0
    /// Dots closer than this would run together, so the slider leaves them out.
    static let minimumTickSpacing = 3.0

    let width: Double
    let knobWidth: Double
    let minimum: Double
    let maximum: Double
    let step: Double

    /// The end stop's stretch of track, a little wider than the knob that rests on it.
    var stopWidth: Double { knobWidth + 6 }
    /// Where the stepped track ends and the notch begins.
    var rangeEnd: Double { max(width - Self.notch - stopWidth, knobWidth) }
    var notchCenter: Double { rangeEnd + Self.notch / 2 }
    var stopStart: Double { rangeEnd + Self.notch }

    /// The step nearest `value`, within `minimum`…`maximum`.
    func stepped(_ value: Double) -> Double {
        let clamped = min(max(value, minimum), maximum)
        return min(minimum + ((clamped - minimum) / step).rounded() * step, maximum)
    }

    func center(of stop: Stop) -> Double {
        switch stop {
        case .end: width - stopWidth / 2
        case let .value(value): knobWidth / 2 + (stepped(value) - minimum) / (maximum - minimum) * (rangeEnd - knobWidth)
        }
    }

    /// The stop under a pointer at `x`. Reaching the end stop takes most of the notch, and so does leaving it, so the
    /// knob holds at `maximum` before it snaps over and doesn't flicker between the two at the notch.
    func stop(at x: Double, from current: Stop) -> Stop {
        if x >= rangeEnd + Self.notch * (current == .end ? 0.25 : 0.75) { return .end }
        let fraction = (x - knobWidth / 2) / max(rangeEnd - knobWidth, 1)
        return .value(stepped(minimum + fraction * (maximum - minimum)))
    }

    /// The stop one step after or before `stop`: the end stop follows `maximum`.
    func stop(after stop: Stop, forward: Bool) -> Stop {
        switch stop {
        case .end: forward ? .end : .value(stepped(maximum))
        case let .value(value):
            if forward, stepped(value) + step > maximum + step / 1000 { .end } else { .value(stepped(value + (forward ? step : -step))) }
        }
    }

    /// The knob centers of the steps, where the slider draws a dot under each, as the native slider does. Empty when
    /// the dots would run together.
    var ticks: [Double] {
        let count = Int(((maximum - minimum) / step + 1e-9).rounded(.down)) + 1
        guard count > 1, (rangeEnd - knobWidth) / Double(count - 1) >= Self.minimumTickSpacing else { return [] }
        return (0..<count).map { center(of: .value(minimum + Double($0) * step)) }
    }
}

/// A slider whose steps run from `minimum` to `maximum`, then past a notch to one more stop, such as ∞, drawn like
/// macOS's own slider. Dragging past `maximum` holds the knob there until the pointer is well into the notch, then
/// snaps it onto the end stop with a haptic tick. It sends its value when the drag ends, as the native slider does.
struct EndStopSlider: View {
    let title: String
    let value: Double
    let minimum: Double
    let maximum: Double
    let step: Double
    let endStop: SliderEndStop
    let onChange: (Double) -> Void
    @State private var dragged: EndStopSliderTrack.Stop?
    @State private var editing = false
    @Environment(\.controlSize) private var controlSize
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The native slider's measures on macOS 26 and later, per control size.
    private struct Metrics {
        let height: Double, track: Double, knob: CGSize, tickOffset: Double, labelSize: Double
    }

    private var metrics: Metrics {
        switch controlSize {
        case .mini: Metrics(height: 18, track: 4, knob: CGSize(width: 8, height: 16), tickOffset: 5, labelSize: 8)
        case .small: Metrics(height: 20, track: 4, knob: CGSize(width: 10, height: 18), tickOffset: 6, labelSize: 9)
        default: Metrics(height: 18, track: 6, knob: CGSize(width: 20, height: 16), tickOffset: 7, labelSize: 10)
        }
    }

    private var stored: EndStopSliderTrack.Stop {
        abs(value - endStop.value) < 1e-9 ? .end : .value(value)
    }

    private var shown: EndStopSliderTrack.Stop { dragged ?? stored }

    /// The stops in order, for the arrow keys and VoiceOver, which don't need the track's size.
    private var steps: EndStopSliderTrack {
        EndStopSliderTrack(width: 0, knobWidth: 0, minimum: minimum, maximum: maximum, step: step)
    }

    /// Its title beside it, as the native slider shows its label, unless labels are hidden, as in hover controls.
    var body: some View {
        LabeledContent {
            slider
        } label: {
            Text(title).accessibilityHidden(true)
        }
    }

    private var slider: some View {
        let metrics = metrics
        return GeometryReader { geometry in
            let track = EndStopSliderTrack(width: geometry.size.width, knobWidth: metrics.knob.width,
                                           minimum: minimum, maximum: maximum, step: step)
            let middle = geometry.size.height / 2
            let knob = track.center(of: shown)
            ZStack(alignment: .topLeading) {
                bar(from: 0, to: track.rangeEnd, middle: middle, fill: .primary.opacity(0.1))
                bar(from: 0, to: shown == .end ? track.rangeEnd : knob, middle: middle, fill: fill)
                Rectangle().fill(.primary.opacity(0.4))
                    .frame(width: 1, height: metrics.knob.height * 0.6)
                    .offset(x: track.notchCenter - 0.5, y: middle - metrics.knob.height * 0.3)
                bar(from: track.stopStart, to: track.width, middle: middle, fill: shown == .end ? fill : AnyShapeStyle(.primary.opacity(0.1)))
                ForEach(Array(track.ticks.enumerated()), id: \.offset) { _, x in
                    Circle().fill(.primary.opacity(0.25)).frame(width: 2, height: 2)
                        .offset(x: x - 1, y: middle + metrics.tickOffset - 1)
                }
                Text(endStop.label)
                    .font(.system(size: metrics.labelSize, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.5))
                    .fixedSize()
                    .frame(width: 0)
                    .offset(x: track.center(of: .end), y: middle + metrics.tickOffset - metrics.labelSize * 0.62)
                    // Under the knob, like the dots of the other steps, rather than peeking out below a wide one.
                    .opacity(shown == .end ? 0 : 1)
                    .accessibilityHidden(true)
                RoundedRectangle(cornerRadius: min(metrics.knob.width, metrics.knob.height) / 2)
                    .fill(.white)
                    .overlay {
                        RoundedRectangle(cornerRadius: min(metrics.knob.width, metrics.knob.height) / 2)
                            .strokeBorder(.black.opacity(colorScheme == .dark ? 0 : 0.08), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                    .frame(width: metrics.knob.width, height: metrics.knob.height)
                    .offset(x: knob - metrics.knob.width / 2, y: middle - metrics.knob.height / 2)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in move(to: track.stop(at: drag.location.x, from: shown)) }
                .onEnded { _ in finish() })
        }
        .frame(minWidth: metrics.knob.width * 3 + EndStopSliderTrack.notch, maxWidth: .infinity)
        .frame(height: metrics.height)
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            commit(steps.stop(after: shown, forward: press.key == .rightArrow || press.key == .upArrow))
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(shown == .end ? endStop.label : number(shown))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: commit(steps.stop(after: shown, forward: true))
            case .decrement: commit(steps.stop(after: shown, forward: false))
            @unknown default: break
            }
        }
        .onChange(of: value) { if !editing { dragged = nil } }
        .preference(key: ControlEditingPreference.self, value: editing)
    }

    /// The fill of the track up to the knob: the tint in an active window, gray in an inactive one, as macOS draws it.
    private var fill: AnyShapeStyle {
        activeState == .inactive ? AnyShapeStyle(.primary.opacity(0.22)) : AnyShapeStyle(.tint)
    }

    private func bar(from start: Double, to end: Double, middle: Double, fill: some ShapeStyle) -> some View {
        Capsule().fill(fill)
            .frame(width: max(end - start, 0), height: metrics.track)
            .offset(x: start, y: middle - metrics.track / 2)
    }

    private func number(_ stop: EndStopSliderTrack.Stop) -> String {
        if case let .value(value) = stop { return min(max(value, minimum), maximum).formatted() }
        return endStop.label
    }

    private func move(to stop: EndStopSliderTrack.Stop) {
        editing = true
        let previous = shown
        guard stop != previous else { return }
        if (stop == .end) != (previous == .end) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { dragged = stop }
        } else {
            dragged = stop
        }
    }

    private func finish() {
        editing = false
        if let dragged { onChange(sent(dragged)) }
    }

    /// A keyboard or VoiceOver step, which applies at once.
    private func commit(_ stop: EndStopSliderTrack.Stop) {
        guard stop != shown else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { dragged = stop }
        onChange(sent(stop))
    }

    private func sent(_ stop: EndStopSliderTrack.Stop) -> Double {
        switch stop {
        case .end: endStop.value
        case let .value(value): value
        }
    }
}
