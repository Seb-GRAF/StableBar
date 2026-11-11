import Foundation
import Testing
@testable import StableBar

/// A preferences domain of its own, and the call that removes it.
private func preferences() -> (UserDefaults, () -> Void) {
    let suite = "star-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (defaults, { defaults.removePersistentDomain(forName: suite) })
}

private let noCLI = GitHubStars(isInstalled: { false }, check: { nil }, star: { false })

/// A GitHub CLI signed in as octocat, whose star is `starred` and whose star request `accepts` or fails.
private func signedIn(starred: Bool = false, accepts: Bool = true) -> GitHubStars {
    GitHubStars(isInstalled: { true }, check: { ("octocat", starred) }, star: { accepts })
}

@Test @MainActor func starRequestShowsAtOnceWithoutTheGitHubCLI() async {
    let (defaults, remove) = preferences()
    defer { remove() }
    let request = StarRequest(defaults: defaults, gitHub: noCLI)
    await request.refresh()
    #expect(request.state == .repository)
    #expect(request.isShown)
}

@Test @MainActor func openingTheRepositoryKeepsAsking() async {
    let (defaults, remove) = preferences()
    defer { remove() }
    let request = StarRequest(defaults: defaults, gitHub: noCLI)
    await request.refresh()
    var opened: [URL] = []
    await request.star { opened.append($0) }
    #expect(opened == [URL(string: "https://github.com/Seb-GRAF/StableBar")!])
    #expect(request.isShown)
    let relaunched = StarRequest(defaults: defaults, gitHub: noCLI)
    await relaunched.refresh()
    #expect(relaunched.isShown)
}

@Test @MainActor func dismissingTheStarRequestStopsAsking() async {
    let (defaults, remove) = preferences()
    defer { remove() }
    let request = StarRequest(defaults: defaults, gitHub: noCLI)
    await request.refresh()
    request.dismiss()
    #expect(!request.isShown)
    let relaunched = StarRequest(defaults: defaults, gitHub: noCLI)
    await relaunched.refresh()
    #expect(!relaunched.isShown)
}

@Test @MainActor func starRequestWaitsForTheGitHubCLIsFirstAnswer() {
    let (defaults, remove) = preferences()
    defer { remove() }
    let request = StarRequest(defaults: defaults, gitHub: signedIn())
    #expect(request.state == .checking)
    #expect(!request.isShown)
}

@Test @MainActor func starringThroughTheGitHubCLIThanksThenStopsAsking() async {
    let (defaults, remove) = preferences()
    defer { remove() }
    let request = StarRequest(defaults: defaults, gitHub: signedIn())
    await request.refresh()
    #expect(request.state == .gitHubCLI(account: "octocat"))
    var opened: [URL] = []
    await request.star { opened.append($0) }
    #expect(opened.isEmpty)
    #expect(request.state == .thanked(account: "octocat"))
    #expect(request.isShown)
    await request.refresh()
    #expect(!request.isShown)
    #expect(StarRequest(defaults: defaults, gitHub: signedIn()).state == .answered)
}

@Test @MainActor func starRequestStopsWhenTheGitHubCLISeesAStar() async {
    let (defaults, remove) = preferences()
    defer { remove() }
    let request = StarRequest(defaults: defaults, gitHub: signedIn(starred: true))
    await request.refresh()
    #expect(!request.isShown)
    #expect(StarRequest(defaults: defaults, gitHub: noCLI).state == .answered)
}

@Test @MainActor func starRequestOpensTheRepositoryWhenTheGitHubCLIFails() async {
    let (defaults, remove) = preferences()
    defer { remove() }
    let signedOut = GitHubStars(isInstalled: { true }, check: { nil }, star: { false })
    let request = StarRequest(defaults: defaults, gitHub: signedOut)
    await request.refresh()
    #expect(request.state == .repository)

    let refused = StarRequest(defaults: defaults, gitHub: signedIn(accepts: false))
    await refused.refresh()
    var opened: [URL] = []
    await refused.star { opened.append($0) }
    #expect(opened == [StarRequest.repository])
    #expect(refused.state == .repository)
    #expect(StarRequest(defaults: defaults, gitHub: noCLI).state == .checking)
}

@Test @MainActor func dismissingWhileTheGitHubCLIAnswersStopsAsking() async {
    let (defaults, remove) = preferences()
    defer { remove() }
    let (entered, enter) = AsyncStream.makeStream(of: Void.self)
    let (released, release) = AsyncStream.makeStream(of: Void.self)
    let slow = GitHubStars(isInstalled: { true }, check: {
        enter.yield()
        for await _ in released { break }
        return ("octocat", false)
    }, star: { true })
    let request = StarRequest(defaults: defaults, gitHub: slow)
    let refreshing = Task { await request.refresh() }
    for await _ in entered { break }
    request.dismiss()
    release.yield()
    await refreshing.value
    #expect(request.state == .answered)
}

@Test @MainActor func sampleStarRequestRunsAndSavesNothing() async {
    let request = StarRequest(sample: .gitHubCLI(account: "octocat"))
    await request.refresh()
    #expect(request.state == .gitHubCLI(account: "octocat"))
    request.dismiss()
    #expect(!request.isShown)
    #expect(StarRequest(sample: .repository).isShown)
}
