import Foundation
import Testing
@testable import StableBar

private func heightProfile(_ when: String) -> String {
    #"{"name":"tuned","when":\#(when),"configuration":{"bar":{"height":30}}}"#
}

private func loaded(_ fixture: ThemeGalleryFixture) throws -> Configuration {
    var loader = ConfigurationLoader()
    loader.themesDirectory = fixture.themes
    return try loader.load(fixture.url)
}

@Test func aThemeConditionMatchesTheSelectedThemeAtAnyVersion() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    _ = try fixture.theme(#"{"bar":{"margin":2}}"#)
    let second = fixture.directory.appending(path: "sources/test-theme-2")
    try fixture.write(#"{"id":"test-theme","name":"Test theme","version":"2","kind":"theme","entry":"config.json"}"#,
                      to: second.appending(path: "package.json"))
    try fixture.write(#"{"bar":{"margin":2}}"#, to: second.appending(path: "config.json"))
    _ = try fixture.packages.install(second)

    for version in ["1", "2"] {
        try fixture.write(#"""
        {"theme":{"id":"test-theme","version":"\#(version)"},"bar":{"height":40},"widgets":[],
         "profiles":[\#(heightProfile(#"{"theme":"test-theme"}"#))]}
        """#, to: fixture.url)
        #expect(try loaded(fixture).bar.height == 30)
    }
    try fixture.write(#"""
    {"theme":{"id":"test-theme","version":"1"},"bar":{"height":40},"widgets":[],
     "profiles":[\#(heightProfile(#"{"theme":"nord"}"#))]}
    """#, to: fixture.url)
    #expect(try loaded(fixture).bar.height == 40)
}

@Test func aThemeConditionMatchesBuiltInWithoutAThemeOrWithItTurnedOff() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    _ = try fixture.theme(#"{"bar":{"margin":2}}"#)
    try fixture.write(#"{"bar":{"height":40},"widgets":[],"profiles":[\#(heightProfile(#"{"theme":"built-in"}"#))]}"#,
                      to: fixture.url)
    #expect(try loaded(fixture).bar.height == 30)

    let off = #"{"id":"test-theme","version":"1","enabled":false}"#
    try fixture.write(#"{"theme":\#(off),"bar":{"height":40},"widgets":[],"profiles":[\#(heightProfile(#"{"theme":"built-in"}"#))]}"#,
                      to: fixture.url)
    #expect(try loaded(fixture).bar.height == 30)
    try fixture.write(#"{"theme":\#(off),"bar":{"height":40},"widgets":[],"profiles":[\#(heightProfile(#"{"theme":"test-theme"}"#))]}"#,
                      to: fixture.url)
    #expect(try loaded(fixture).bar.height == 40)
}

@Test func aThemeConditionFollowsAScreenSetupsOwnTheme() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    _ = try fixture.theme(#"{"bar":{"margin":2}}"#)
    try fixture.write(#"""
    {"theme":{"id":"test-theme","version":"1"},"screens":{"laptop":{"theme":{"id":"nord"}}},"bar":{"height":40},"widgets":[],
     "profiles":[\#(heightProfile(#"{"theme":"nord"}"#))]}
    """#, to: fixture.url)
    let configuration = try loaded(fixture)
    #expect(configuration.bar.height == 40)
    #expect(configuration.screenLooks["laptop"]?.bar.height == 30)
}

@Test func aThemeConditionReadsAThemeSelectedInAnInclude() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    _ = try fixture.theme(#"{"bar":{"margin":2}}"#)
    try fixture.write(#"{"theme":{"id":"test-theme","version":"1"}}"#, to: fixture.directory.appending(path: "look.json"))
    try fixture.write(#"""
    {"includes":["look.json"],"bar":{"height":40},"widgets":[],"profiles":[\#(heightProfile(#"{"theme":"test-theme"}"#))]}
    """#, to: fixture.url)
    #expect(try loaded(fixture).bar.height == 30)
}

@Test func aThemeConditionNamingAMissingThemeLoadsAndNeverMatches() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    try fixture.write(#"{"bar":{"height":40},"widgets":[],"profiles":[\#(heightProfile(#"{"theme":"not-installed"}"#))]}"#,
                      to: fixture.url)
    #expect(try loaded(fixture).bar.height == 40)
}

@Test func aThemesOwnProfileMatchesInItsPreview() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let choice = try fixture.theme(#"{"bar":{"height":40},"profiles":[\#(heightProfile(#"{"theme":"test-theme"}"#))]}"#)
    let preview = try ThemePreview(choice: choice, themesDirectory: fixture.themes)
    #expect(preview.light.bar.height == 30)
    #expect(preview.dark.bar.height == 30)
}

@MainActor @Test func aThemeConditionFollowsTheThemeBeingTried() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    let choice = try fixture.theme(#"{"bar":{"margin":2}}"#)
    try fixture.write(#"{"bar":{"height":40},"widgets":[],"profiles":[\#(heightProfile(#"{"theme":"test-theme"}"#))]}"#,
                      to: fixture.url)
    let store = BarStore(configurationURL: fixture.url, themesDirectory: fixture.themes, customizationSaveDelay: .zero)
    defer { store.stop() }
    store.reloadConfiguration()
    #expect(store.configurationError == nil)
    #expect(store.configuration?.bar.height == 40)

    try store.tryTheme(choice)
    #expect(store.configuration?.bar.height == 30)
    #expect(store.activeProfiles == ["tuned"])

    store.endThemeTrial()
    #expect(store.configuration?.bar.height == 40)
}
