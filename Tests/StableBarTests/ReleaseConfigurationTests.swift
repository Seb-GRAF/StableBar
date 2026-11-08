import Foundation
import Testing
@testable import StableBar

/// The starter configuration as each release that changed it first wrote it (`git show <tag>:Resources/config.json`).
/// People keep those files, so every one has to keep loading: the configuration file is public API (AGENTS.md).
/// When a release ships a new starter configuration, add it here under that release's name.
private let starters = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/StarterConfigurations")

private let starterFiles = ((try? FileManager.default.contentsOfDirectory(atPath: starters.path(percentEncoded: false))) ?? [])
    .filter { $0.hasSuffix(".json") }.sorted()

@Test func everyReleasedStarterConfigurationIsKept() {
    #expect(starterFiles.count >= 6)
}

/// A build with no release of its own loads strictly, so a property the starter had and this build no longer knows
/// fails instead of being skipped. `start()` runs the migrations the app runs at launch.
@Test(arguments: starterFiles) @MainActor
func everyReleasedStarterConfigurationStillLoads(_ name: String) throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    try Data(contentsOf: starters.appending(path: name)).write(to: fixture.url)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes)
    defer { store.stop() }
    store.start()
    #expect(store.configurationError == nil)
    #expect(store.configurationWarning == nil)
    #expect(store.configuration?.widgets.isEmpty == false)
}
