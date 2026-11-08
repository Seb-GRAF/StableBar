import CoreGraphics
import Testing
@testable import StableBar

/// Fails on the first macOS that drops one of these calls, so its feature's fallback gets looked at before people
/// update.
@Test func everyPrivateCallExistsOnThisMacOS() {
    #expect(PrivateAPI.mainConnectionID != nil)
    #expect(PrivateAPI.setMenuBarInsetAndAlpha != nil)
    #expect(PrivateAPI.setMenuBarVisibilityOverride != nil)
    #expect(PrivateAPI.getActiveSpace != nil)
    #expect(PrivateAPI.copyManagedDisplaySpaces != nil)
    #expect(PrivateAPI.copySpacesForWindows != nil)
    #expect(PrivateAPI.lockScreenImmediate != nil)
}

@Test func aCallThisMacOSDoesNotHaveIsNil() {
    #expect(PrivateAPI.symbol("StableBarNoSuchSymbol", as: (@convention(c) () -> Int32).self) == nil)
}

/// The Spaces calls read this Mac's desktops the way the Spaces source does, through the runtime lookups.
@Test func theSpacesCallsReadThisMacsDesktops() throws {
    let connection = try #require(PrivateAPI.mainConnectionID?())
    let displays = try #require(PrivateAPI.copyManagedDisplaySpaces?(connection)?.takeRetainedValue() as? [[String: Any]])
    #expect(!displays.isEmpty)
    #expect(PrivateAPI.getActiveSpace?(connection) != 0)
}
