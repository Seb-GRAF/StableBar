import Foundation
import Testing

/// A clock that moves only when a test advances it, so code that waits on it runs at exact points however busy the
/// main actor is. Pass it where the code under test takes a clock.
final class TestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    /// Sleeps cancelled before they were registered.
    private var cancelled: Set<UUID> = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }
    /// How many tasks wait on this clock, so a test can advance once the code under test has started waiting.
    var sleeping: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = lock.withLock {
                    if cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline <= current { return .success(()) }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
                    cancelled.insert(id)
                    return nil
                }
                return sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock and wakes every sleep whose deadline it reached, earliest first. Their tasks run once the test
    /// lets them, such as with `await Task.yield()`.
    func advance(by duration: Duration) {
        let woken: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let reached = sleepers.filter { $0.deadline <= current }.sorted { $0.deadline < $1.deadline }
            sleepers.removeAll { $0.deadline <= current }
            return reached
        }
        for sleeper in woken { sleeper.continuation.resume() }
    }

    /// Lets the main actor run what it queued, such as tasks a test just woke, without waiting on real time.
    @MainActor static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@Test func aTestClockSleepEndsOnlyWhenTheClockReachesIt() async throws {
    let clock = TestClock()
    let sleep = Task { try await clock.sleep(for: .milliseconds(200)) }
    while clock.sleeping == 0 { await Task.yield() }
    clock.advance(by: .milliseconds(199))
    #expect(clock.sleeping == 1)
    clock.advance(by: .milliseconds(1))
    #expect(clock.sleeping == 0)
    try await sleep.value
    #expect(clock.now.offset == .milliseconds(200))
}

@Test func aTestClockSleepThatIsCancelledThrows() async {
    let clock = TestClock()
    let sleep = Task { try await clock.sleep(for: .seconds(1)) }
    while clock.sleeping == 0 { await Task.yield() }
    sleep.cancel()
    await #expect(throws: CancellationError.self) { try await sleep.value }
    #expect(clock.sleeping == 0)
}

@Test func aTestClockSleepCancelledBeforeItStartsThrowsAtOnce() async {
    let clock = TestClock()
    let sleep = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await clock.sleep(for: .seconds(1))
    }
    await #expect(throws: CancellationError.self) { try await sleep.value }
    #expect(clock.sleeping == 0)
}

@Test func aTestClockSleepWithNothingLeftToWaitEndsAtOnce() async throws {
    let clock = TestClock()
    try await clock.sleep(for: .zero)
    clock.advance(by: .seconds(1))
    try await clock.sleep(until: clock.now)
}
