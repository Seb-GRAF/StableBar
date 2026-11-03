import Foundation
import Testing
@testable import StableBar

private let day: TimeInterval = 24 * 60 * 60
private let launch = Date(timeIntervalSinceReferenceDate: 815_000_000)

/// A preferences domain of its own, and the call that removes it.
private func preferences() -> (UserDefaults, () -> Void) {
    let suite = "star-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (defaults, { defaults.removePersistentDomain(forName: suite) })
}

@Test @MainActor func starRequestWaitsAWeekFromTheFirstLaunch() {
    let (defaults, remove) = preferences()
    defer { remove() }
    let request = StarRequest(defaults: defaults, now: launch)
    #expect(!request.isDue(at: launch))
    #expect(!request.isDue(at: launch + 7 * day - 1))
    #expect(request.isDue(at: launch + 7 * day))
}

@Test @MainActor func starRequestKeepsTheFirstLaunchAcrossLaunches() {
    let (defaults, remove) = preferences()
    defer { remove() }
    _ = StarRequest(defaults: defaults, now: launch)
    let relaunched = StarRequest(defaults: defaults, now: launch + 6 * day)
    #expect(relaunched.isDue(at: launch + 7 * day))
}

@Test @MainActor func starringOpensTheRepositoryAndStopsAsking() {
    let (defaults, remove) = preferences()
    defer { remove() }
    let request = StarRequest(defaults: defaults, now: launch)
    var opened: [URL] = []
    request.star { opened.append($0) }
    #expect(opened == [URL(string: "https://github.com/Seb-GRAF/StableBar")!])
    #expect(!request.isDue(at: launch + 30 * day))
    #expect(!StarRequest(defaults: defaults, now: launch).isDue(at: launch + 30 * day))
}

@Test @MainActor func dismissingTheStarRequestStopsAsking() {
    let (defaults, remove) = preferences()
    defer { remove() }
    let request = StarRequest(defaults: defaults, now: launch)
    request.dismiss()
    #expect(!request.isDue(at: launch + 30 * day))
    #expect(!StarRequest(defaults: defaults, now: launch).isDue(at: launch + 30 * day))
}

@Test @MainActor func sampleStarRequestIsDueAndSavesNothing() {
    let request = StarRequest(start: .distantPast)
    #expect(request.isDue(at: launch))
    request.dismiss()
    #expect(!request.isDue(at: launch))
    #expect(StarRequest(start: .distantPast).isDue(at: launch))
}
