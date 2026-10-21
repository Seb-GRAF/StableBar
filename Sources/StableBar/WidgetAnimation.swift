import SwiftUI
import QuartzCore

struct WidgetAnimation: Decodable, Equatable, Sendable {
    enum Curve: String, Decodable, Sendable {
        case linear, easeIn, easeOut, easeInOut, smooth, spring
    }

    var curve: Curve = .easeOut
    var duration: Double = 0.22

    enum CodingKeys: String, CodingKey, CaseIterable { case curve, duration }

    init(curve: Curve = .easeOut, duration: Double = 0.22) {
        self.curve = curve
        self.duration = duration
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        curve = try values.decodeIfPresent(Curve.self, forKey: .curve) ?? curve
        duration = try values.decodeIfPresent(Double.self, forKey: .duration) ?? duration
    }

    var value: Animation {
        switch curve {
        case .linear: .linear(duration: duration)
        case .easeIn: .easeIn(duration: duration)
        case .easeOut: .easeOut(duration: duration)
        case .easeInOut: .easeInOut(duration: duration)
        case .smooth: .smooth(duration: duration)
        case .spring: .spring(duration: duration)
        }
    }

    var timingFunction: CAMediaTimingFunction {
        switch curve {
        case .linear: CAMediaTimingFunction(name: .linear)
        case .easeIn: CAMediaTimingFunction(name: .easeIn)
        case .easeOut: CAMediaTimingFunction(name: .easeOut)
        case .easeInOut: CAMediaTimingFunction(name: .easeInEaseOut)
        case .smooth, .spring: CAMediaTimingFunction(controlPoints: 0.15, 0.05, 0.25, 1)
        }
    }
}

/// How a widget's text, field and symbol blocks show changed content.
enum WidgetTransition: String, Decodable, CaseIterable, Sendable {
    case none, fade, roll, numeric

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let transition = WidgetTransition(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Use none, fade, roll or numeric.")
        }
        self = transition
    }
}

extension WidgetTransition {
    /// How a widget enters and leaves the bar when its output's `hidden` changes.
    var visibility: AnyTransition {
        switch self {
        case .none: .identity
        case .fade, .numeric: .opacity
        case .roll: .push(from: .bottom)
        }
    }
}

/// The animation that shows or hides a widget when its output's `hidden` changes, or nil to change
/// it at once: without a transition, or with Reduce Motion.
func visibilityAnimation(_ transition: WidgetTransition?, animation: WidgetAnimation, reduceMotion: Bool) -> WidgetAnimation? {
    guard let transition, transition != .none, !reduceMotion else { return nil }
    return animation
}

func hoverAnimation(_ hovered: Bool, reduceMotion: Bool) -> Animation? {
    hovered || reduceMotion ? nil : .easeOut(duration: 0.1)
}

/// How a widget or unit enters and leaves the bar: with its transition, but not under Reduce Motion
/// or in the bar's measuring copy, which never moves.
func visibilityTransition(_ transition: WidgetTransition?, still: Bool) -> AnyTransition {
    still ? .identity : (transition ?? WidgetTransition.none).visibility
}

extension WidgetAnimation {
    /// Runs `changes` as one SwiftUI animation with this curve and duration.
    @MainActor func animate(_ changes: () -> Void) {
        withAnimation(value, changes)
    }
}

struct WorkspaceConfiguration: Decodable, Sendable {
    enum Indicator: String, Decodable, Sendable {
        case background, underline, none
    }

    var indicator: Indicator?
    var appGlyphs: [String: String]?
    var showEmpty: Bool?
    var showApps: Bool?
    var windows: Bool?
    var titleLength: Int?
    var style = WidgetStyle()
    var appStyle = WidgetStyle()
    var indicatorStyle = WidgetStyle()
    private var cells: [WorkspaceState?: WorkspaceCellStyle] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case indicator, indicatorStyle, style, focusedStyle, visibleStyle, emptyStyle, appStyle, focusedAppStyle, visibleAppStyle
        case appGlyphs, showEmpty, showApps, windows, titleLength
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        indicator = try values.decodeIfPresent(Indicator.self, forKey: .indicator)
        appGlyphs = try values.decodeIfPresent([String: String].self, forKey: .appGlyphs)
        showEmpty = try values.decodeIfPresent(Bool.self, forKey: .showEmpty)
        showApps = try values.decodeIfPresent(Bool.self, forKey: .showApps)
        windows = try values.decodeIfPresent(Bool.self, forKey: .windows)
        titleLength = try values.decodeIfPresent(Int.self, forKey: .titleLength)
        if let titleLength, titleLength < 0 {
            throw DecodingError.dataCorruptedError(forKey: .titleLength, in: values, debugDescription: "Window title length must be nonnegative.")
        }
        let focused = try values.decodeIfPresent(WidgetStyle.self, forKey: .focusedStyle)
        let visible = try values.decodeIfPresent(WidgetStyle.self, forKey: .visibleStyle)
        let empty = try values.decodeIfPresent(WidgetStyle.self, forKey: .emptyStyle)
        let focusedApp = try values.decodeIfPresent(WidgetStyle.self, forKey: .focusedAppStyle)
        let visibleApp = try values.decodeIfPresent(WidgetStyle.self, forKey: .visibleAppStyle)
        let cell = (try values.decodeIfPresent(WidgetStyle.self, forKey: .style) ?? WidgetStyle())
            .addingStates(["focused": focused, "visible": visible, "empty": empty].compactMapValues { $0 })
        let app = (try values.decodeIfPresent(WidgetStyle.self, forKey: .appStyle) ?? WidgetStyle())
            .addingStates(["focused": focusedApp, "visible": visibleApp].compactMapValues { $0 })
        let underline = try values.decodeIfPresent(WidgetStyle.self, forKey: .indicatorStyle) ?? WidgetStyle()
        style = cell
        appStyle = app
        indicatorStyle = underline
        let states: [WorkspaceState?] = [nil, .focused, .visible, .empty]
        for state in states {
            cells[state] = WorkspaceCellStyle(state: state, cell: cell, underline: underline, app: app)
        }
    }

    var usesModeStates: Bool { style.usesModeStates || appStyle.usesModeStates || indicatorStyle.usesModeStates }

    func cellStyle(_ state: WorkspaceState?, mode: ModePresentation = ModePresentation()) -> WorkspaceCellStyle {
        if mode.active && usesModeStates {
            return WorkspaceCellStyle(state: state, cell: style, underline: indicatorStyle, app: appStyle, mode: mode)
        }
        return cells[state] ?? WorkspaceCellStyle()
    }
}
