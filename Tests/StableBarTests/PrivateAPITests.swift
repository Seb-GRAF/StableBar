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

/// Hiding the menu bar on a macOS that can't reveal it on one display would leave the app menus out of reach, so it
/// stays shown there; showing it always works.
@Test func theMenuBarStaysShownWhenMacOSCannotRevealIt() {
    var alphas: [Float] = []
    let record: (Int32, Double, Double, Float) -> CGError = { _, _, _, alpha in
        alphas.append(alpha)
        return .success
    }
    setMenuBarHidden(true, canReveal: false, setAlpha: record)
    setMenuBarHidden(false, canReveal: false, setAlpha: record)
    setMenuBarHidden(true, canReveal: true, setAlpha: record)
    #expect(alphas == [1, 0])
}

/// Without the call that lists the desktops, or when it lists none, the Spaces source says why instead of failing.
@Test func spacesSayWhyWhenMacOSCannotListTheDesktops() {
    let missing: ((Int32) -> Unmanaged<CFArray>?)? = nil
    for copy in [missing, { _ in nil }] {
        let error = #expect(throws: CommandFailure.self) { try currentSpaces(copyManagedDisplaySpaces: copy) }
        #expect(error?.message == "This version of macOS doesn't let StableBar read its Spaces.")
    }
}
