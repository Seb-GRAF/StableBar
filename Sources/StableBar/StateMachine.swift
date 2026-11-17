/// What a feature decides about its state, kept apart from the windows, timers and scripts that carry the decision
/// out. Its owner sends it each event and performs the effects `handle` returns, in order, once it has returned, so
/// performing one never reaches back into a decision that is still being made. Its file imports no UI framework and
/// starts no work, so a plain unit test covers every transition (AGENTS.md).
protocol StateMachine {
    associatedtype Event
    associatedtype Effect
    mutating func handle(_ event: Event) -> [Effect]
}
