import Dispatch

/// Runs work that blocks its thread, such as copying a bundle or a lookup that can stall on a network volume.
/// Swift's shared pool has one thread per core and never replaces a blocked one; GCD adds a thread instead.
enum BlockingWork {
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result(catching: work))
            }
        }
    }
}
