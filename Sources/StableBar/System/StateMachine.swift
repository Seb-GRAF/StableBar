/// A feature's decisions about its state. Its owner performs the effects `handle` returns, in order, after it returns;
/// its file imports no UI framework and starts no work, so a unit test covers every transition (AGENTS.md).
protocol StateMachine {
    associatedtype Event
    associatedtype Effect
    mutating func handle(_ event: Event) -> [Effect]
}
