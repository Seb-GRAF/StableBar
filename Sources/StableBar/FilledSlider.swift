import AppKit
import SwiftUI

/// Where a filled slider's fill ends and which stop a pointer picks. The fill is at least as wide as the bar is tall,
/// so a glyph at its leading end sits on it, and its trailing end, a cap as wide as the bar is tall, follows the
/// pointer, as a knob would. With an end stop, the steps end before a notch and the end stop, laid out as
/// `EndStopSliderTrack` lays them out with the cap as its knob, and the end stop fills the whole bar. A bar narrower
/// than `minimumWidth` narrows its cap instead, so its steps still move the fill.
struct FilledSliderTrack: Equatable {
    typealias Stop = EndStopSliderTrack.Stop

    let width: Double
    let height: Double
    let minimum: Double
    let maximum: Double
    let step: Double
    var endStop = false

    /// The narrowest bar whose cap is as wide as it is tall: with an end stop, room for the notch, the end stop and as
    /// much travel for the steps as the cap's width.
    static func minimumWidth(height: Double, endStop: Bool) -> Double {
        endStop ? height * 3 + EndStopSliderTrack.notch + EndStopSliderTrack.stopPadding : height * 2
    }

    /// As wide as the bar is tall, unless the steps would then get less travel than the cap's width, as below
    /// `minimumWidth`, which an explicit `width` can make it: then the cap narrows, so every step still moves the fill.
    var cap: Double {
        let room = endStop ? (width - EndStopSliderTrack.notch - EndStopSliderTrack.stopPadding) / 3 : width / 2
        return max(min(height, room), 0)
    }
    private var stops: EndStopSliderTrack {
        EndStopSliderTrack(width: width, knobWidth: cap, minimum: minimum, maximum: maximum, step: step)
    }

    /// Where the stepped part of the bar ends: its trailing edge, or the notch before the end stop.
    var rangeEnd: Double { endStop ? stops.rangeEnd : width }
    var notchCenter: Double { stops.notchCenter }
    /// The middle of the end stop's stretch, where its label sits.
    var stopCenter: Double { stops.center(of: .end) }

    func stepped(_ value: Double) -> Double { stops.stepped(value) }

    func fillWidth(for stop: Stop) -> Double {
        switch stop {
        case .end: width
        case let .value(value): cap + (stepped(value) - minimum) / (maximum - minimum) * max(rangeEnd - cap, 0)
        }
    }

    /// The stop whose fill ends with its cap centered under a pointer at `x`. Reaching or leaving the end stop takes
    /// most of the notch, as on the end-stop slider.
    func stop(at x: Double, from current: Stop) -> Stop {
        if endStop { return stops.stop(at: x, from: current) }
        let fraction = (x - cap / 2) / max(width - cap, 1)
        return .value(stepped(minimum + fraction * (maximum - minimum)))
    }

    /// The stop one step after or before `stop`, for the arrow keys and VoiceOver: the end stop follows `maximum`.
    func stop(after stop: Stop, forward: Bool) -> Stop {
        if endStop { return stops.stop(after: stop, forward: forward) }
        guard case let .value(value) = stop else { return stop }
        return .value(stepped(stepped(value) + (forward ? step : -step)))
    }
}

/// A slider drawn as a bar in the block's style rather than macOS's control: its background is the track, the
/// accent fills it from the leading edge, and an optional symbol sits on the fill in the accent's text color. An end
/// stop follows a notch at its trailing end and fills the whole bar. Clicking or dragging anywhere sets the value. It
/// sends its value when the drag ends, as the native slider does.
struct FilledSlider: View {
    let title: String
    let value: Double
    let minimum: Double
    let maximum: Double
    let step: Double
    let endStop: SliderEndStop?
    let icon: String?
    let height: Double
    /// Whether the block draws no track of its own, so the slider draws a faint one.
    let drawsTrack: Bool
    let appearance: WidgetAppearance
    let onChange: (Double) -> Void
    @State private var dragged: FilledSliderTrack.Stop?
    @State private var editing = false
    /// Resets however the drag ends, unlike `onEnded`, which a cancelled drag skips.
    @GestureState private var dragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stored: FilledSliderTrack.Stop {
        if let endStop, abs(value - endStop.value) < 1e-9 { return .end }
        return .value(value)
    }

    private var shown: FilledSliderTrack.Stop { dragged ?? stored }

    /// The stops in order, for the arrow keys and VoiceOver, which don't need the bar's size.
    private var steps: FilledSliderTrack {
        FilledSliderTrack(width: 0, height: 0, minimum: minimum, maximum: maximum, step: step, endStop: endStop != nil)
    }

    var body: some View {
        let radius = min(appearance.cornerRadius, height / 2)
        GeometryReader { geometry in
            let track = FilledSliderTrack(width: geometry.size.width, height: height, minimum: minimum, maximum: maximum,
                                          step: step, endStop: endStop != nil)
            ZStack(alignment: .topLeading) {
                if drawsTrack {
                    RoundedRectangle(cornerRadius: radius).fill(appearance.foreground.opacity(0.12))
                }
                RoundedRectangle(cornerRadius: radius)
                    .fill(appearance.accent)
                    .frame(width: track.fillWidth(for: shown))
                if let endStop {
                    let filled = shown == .end
                    Rectangle()
                        .fill(filled ? appearance.accentText.opacity(0.35) : appearance.foreground.opacity(0.3))
                        .frame(width: 1, height: height * 0.5)
                        .offset(x: track.notchCenter - 0.5, y: height * 0.25)
                    Text(endStop.label)
                        .font(appearance.font.weight(.semibold))
                        .foregroundStyle(filled ? appearance.accentText : appearance.foreground.opacity(0.5))
                        .fixedSize()
                        .frame(width: 0, height: height)
                        .offset(x: track.stopCenter)
                        .accessibilityHidden(true)
                }
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: appearance.iconSize))
                        .foregroundStyle(appearance.accentText)
                        .frame(width: track.cap, height: height)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: geometry.size.width, height: height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($dragging) { _, active, _ in active = true }
                .onChanged { drag in move(to: track.stop(at: drag.location.x, from: shown)) }
                .onEnded { _ in finish() })
        }
        // An ideal width rather than a minimum, which would clamp an explicit narrower width before the track sees it.
        .frame(idealWidth: FilledSliderTrack.minimumWidth(height: height, endStop: endStop != nil), maxWidth: .infinity)
        .frame(height: height)
        .focusable(interactions: .activate)
        .modifier(FocusHighlight(appearance: appearance))
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            commit(steps.stop(after: shown, forward: press.key == .rightArrow || press.key == .upArrow))
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(spoken(shown))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: commit(steps.stop(after: shown, forward: true))
            case .decrement: commit(steps.stop(after: shown, forward: false))
            @unknown default: break
            }
        }
        .onChange(of: value) { if !editing { dragged = nil } }
        // A drag that ended without `onEnded` was cancelled: drop its value rather than keep showing it.
        .onChange(of: dragging) { _, active in
            if !active, editing {
                editing = false
                dragged = nil
            }
        }
        .preference(key: ControlEditingPreference.self, value: editing)
    }

    private func spoken(_ stop: FilledSliderTrack.Stop) -> String {
        switch stop {
        case .end: endStop?.label ?? ""
        case let .value(value): steps.stepped(value).formatted()
        }
    }

    private func move(to stop: FilledSliderTrack.Stop) {
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
    private func commit(_ stop: FilledSliderTrack.Stop) {
        guard stop != shown else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { dragged = stop }
        onChange(sent(stop))
    }

    private func sent(_ stop: FilledSliderTrack.Stop) -> Double {
        switch stop {
        case .end: endStop?.value ?? maximum
        case let .value(value): steps.stepped(value)
        }
    }
}
