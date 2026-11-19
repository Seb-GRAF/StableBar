import Observation

/// One widget's resolved style and presence, observed per widget so one widget's update doesn't
/// invalidate the views of the others.
@MainActor @Observable
final class WidgetPresentation {
    private(set) var style = ResolvedWidgetStyle(base: WidgetStyle())
    private(set) var screenStyles: [String: ResolvedWidgetStyle] = [:]
    /// Displays where hovering expands the widget: an app menu with `expandOnHover`, or the Sound
    /// widget with its volume slider. The bar's measuring copy, which no pointer reaches, reads it.
    var expandedDisplays: Set<Int> = []
    /// Output `hidden`, unless the widget has an error to show.
    private(set) var hidden = false
    /// Output `display`, which replaces the configured one.
    private(set) var display: DisplaySelection?
    /// The view that anchors this widget's open popup: only that instance shows `open`.
    private(set) var popupAnchor: ObjectIdentifier?
    private(set) var innerPopupAnchor: ObjectIdentifier?
    /// Fields from the latest output's `temporary`, shown over the widget's own until they expire.
    private(set) var temporaryFields: [String: String]?
    /// The `temporary` that shows.
    @ObservationIgnored private var temporary: TemporaryOutput?
    /// The number of the last output `show` was given.
    @ObservationIgnored private var shownOutput = 0
    @ObservationIgnored private(set) var expiry: Task<Void, Never>?
    /// What a `temporary` output's duration runs on; tests set a clock they advance themselves.
    @ObservationIgnored var clock: any Clock<Duration> = ContinuousClock()

    /// Assigns only what changed: equal assignments must not invalidate the widget's views. With a
    /// `visibility` animation, a change of `hidden` animates the widget in or out.
    func update(style: ResolvedWidgetStyle, screenStyles: [String: ResolvedWidgetStyle] = [:], hidden: Bool, display: DisplaySelection?,
                visibility: WidgetAnimation? = nil) {
        if self.style != style { self.style = style }
        if self.screenStyles != screenStyles { self.screenStyles = screenStyles }
        if self.hidden != hidden {
            if let visibility { visibility.animate { self.hidden = hidden } } else { self.hidden = hidden }
        }
        if self.display != display { self.display = display }
    }

    func style(on kind: ScreenKind) -> ResolvedWidgetStyle {
        screenStyles[kind.rawValue] ?? style
    }

    /// Expands or collapses the widget on `display`, with `animation` when given.
    func setExpanded(_ expanded: Bool, on display: Int, animation: WidgetAnimation? = nil) {
        guard expandedDisplays.contains(display) != expanded else { return }
        var displays = expandedDisplays
        if expanded { displays.insert(display) } else { displays.remove(display) }
        if let animation { animation.animate { expandedDisplays = displays } } else { expandedDisplays = displays }
    }

    func setPopupAnchor(_ anchor: ObjectIdentifier?) {
        if popupAnchor != anchor { popupAnchor = anchor }
    }

    func setInnerPopupAnchor(_ anchor: ObjectIdentifier?) {
        if innerPopupAnchor != anchor { innerPopupAnchor = anchor }
    }

    /// Shows the `temporary` of a new output for its duration. `output` numbers the output, so the
    /// same output applied again changes nothing. An output without one, or with the same one while
    /// it shows, lets the current one run out. With an `animation`, the fields come and go with it.
    func show(_ next: TemporaryOutput?, output: Int, animation: WidgetAnimation? = nil) {
        guard output != shownOutput else { return }
        shownOutput = output
        guard let next, next != temporary else { return }
        temporary = next
        expiry?.cancel()
        if temporaryFields != next.fields { setTemporaryFields(next.fields, animation: animation) }
        let clock = clock
        expiry = Task { [weak self] in
            try? await clock.sleep(for: .seconds(next.duration))
            guard !Task.isCancelled, let self else { return }
            temporary = nil
            setTemporaryFields(nil, animation: animation)
        }
    }

    private func setTemporaryFields(_ fields: [String: String]?, animation: WidgetAnimation?) {
        if let animation { animation.animate { temporaryFields = fields } } else { temporaryFields = fields }
    }
}
