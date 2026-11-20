/// When an offscreen drawing's views have settled. An offscreen window has no display to pace its views, so they apply
/// what changed as they're drawn: they're drawn again and again, and the drawing is kept once it holds still.
struct StillDrawing: StateMachine {
    enum Event {
        /// The views were drawn, `at` after the first drawing: whether the drawing matches the previous one, whether
        /// they're ready, and whether a loading indicator shows.
        case drawn(matchesPrevious: Bool, ready: Bool, loading: Bool, at: Duration)
    }

    enum Effect: Equatable {
        /// Draws the views again after a moment.
        case drawAgain
        /// Keeps the latest drawing.
        case keep
        /// Gives up: the views never held still.
        case fail
    }

    /// Drawings in a row that match the previous one. One isn't enough: a change made as the views are drawn can show
    /// only in the drawing after next.
    static let matchesNeeded = 2
    /// How long a drawing with a loading indicator holds still before it's kept. A load waiting on the disk changes
    /// nothing until it ends, and some screens show their indicator for good.
    static let loadingHold: Duration = .seconds(2)
    /// Drawings before giving up.
    static let limit = 600

    private(set) var drawings = 0
    private var matches = 0
    private var stillSince: Duration?

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .drawn(matchesPrevious, ready, loading, now):
            drawings += 1
            if matchesPrevious && ready, let stillSince {
                matches += 1
                if matches >= Self.matchesNeeded && (!loading || now - stillSince >= Self.loadingHold) { return [.keep] }
            } else {
                matches = 0
                stillSince = now
            }
            return drawings < Self.limit ? [.drawAgain] : [.fail]
        }
    }
}
