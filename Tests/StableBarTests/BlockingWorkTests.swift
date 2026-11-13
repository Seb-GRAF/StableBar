import Dispatch
import Testing
@testable import StableBar

/// A test that blocks a thread of Swift's shared pool can hang the whole run: CI's runner has only three.
func isOnSwiftPool() -> Bool {
    String(cString: __dispatch_queue_get_label(nil)).hasSuffix(".cooperative")
}

@Test func blockingWorkRunsOffSwiftsPool() async throws {
    #expect(isOnSwiftPool())
    #expect(try await BlockingWork.run { isOnSwiftPool() } == false)
}
