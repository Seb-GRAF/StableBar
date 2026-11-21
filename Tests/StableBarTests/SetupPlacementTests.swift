@testable import StableBar
import Testing

@Test func replacingTheMenuBarAsksForAccessThenHidesItThenMovesTheBar() {
    var placing = SetupPlacement()
    #expect(placing.handle(.chose(.top, menuBarHides: false)) == [.checkAccess(request: 1)])
    #expect(placing.handle(.accessChecked(.allowed, request: 1))
            == [.changeMenuBar(hidden: true, request: 1)])
    #expect(placing.handle(.menuBarChanged(failure: nil, request: 1)) == [.move(.top), .showError(nil)])
    #expect(placing.phase == .placed(.top))
}

@Test func refusedAccessPutsTheBarBelowTheMenuBarAndAppliesOnceAllowedInSystemSettings() {
    var placing = SetupPlacement()
    _ = placing.handle(.chose(.top, menuBarHides: false))
    #expect(placing.handle(.accessChecked(.denied, request: 1)) == [.move(.belowMenuBar), .showError(nil)])
    #expect(placing.awaitingAccess == .top)
    #expect(placing.handle(.accessAllowed(menuBarHides: false)) == [.checkAccess(request: 2)])
    #expect(placing.awaitingAccess == nil)
    _ = placing.handle(.accessChecked(.allowed, request: 2))
    #expect(placing.handle(.menuBarChanged(failure: nil, request: 2)) == [.move(.top), .showError(nil)])
    #expect(placing.phase == .placed(.top))
}

@Test func allowedAccessChangesNothingUnlessAChoiceWaitsForIt() {
    var placing = SetupPlacement()
    #expect(placing.handle(.accessAllowed(menuBarHides: false)).isEmpty)
    _ = placing.handle(.chose(.top, menuBarHides: false))
    #expect(placing.handle(.accessAllowed(menuBarHides: false)).isEmpty)
    #expect(placing.phase == .checkingAccess(.top))
}

@Test func theLatestChoiceWinsOverAnAnswerForAnEarlierOne() {
    var placing = SetupPlacement()
    _ = placing.handle(.chose(.top, menuBarHides: false))
    _ = placing.handle(.chose(.top, menuBarHides: false))
    #expect(placing.handle(.accessChecked(.denied, request: 1)).isEmpty)
    #expect(placing.phase == .checkingAccess(.top))
    #expect(placing.handle(.accessChecked(.allowed, request: 2))
            == [.changeMenuBar(hidden: true, request: 2)])
}

@Test func aChangeFinishingForAnEarlierChoiceLeavesTheLatestOne() {
    var placing = SetupPlacement()
    _ = placing.handle(.chose(.top, menuBarHides: true))
    _ = placing.handle(.chose(.belowMenuBar, menuBarHides: false))
    #expect(placing.handle(.menuBarChanged(failure: nil, request: 1)).isEmpty)
    #expect(placing.phase == .changingMenuBar(.belowMenuBar))
}

@Test func skippingSetupDropsTheResultOfAChangeStillRunning() {
    var placing = SetupPlacement()
    _ = placing.handle(.chose(.top, menuBarHides: false))
    _ = placing.handle(.accessChecked(.allowed, request: 1))
    _ = placing.handle(.skipped)
    #expect(placing.handle(.menuBarChanged(failure: "timed out", request: 1)).isEmpty)
}

@Test func skippingSetupDropsAChoiceWaitingForAccess() {
    var placing = SetupPlacement()
    _ = placing.handle(.chose(.top, menuBarHides: false))
    _ = placing.handle(.accessChecked(.denied, request: 1))
    _ = placing.handle(.skipped)
    #expect(placing.awaitingAccess == nil)
    #expect(placing.handle(.accessAllowed(menuBarHides: false)).isEmpty)
}

@Test func aRefusedChangeExplainsAutomationAccessAndPutsTheBarBelowTheMenuBar() {
    var placing = SetupPlacement()
    _ = placing.handle(.chose(.top, menuBarHides: false))
    _ = placing.handle(.accessChecked(.allowed, request: 1))
    let effects = placing.handle(.menuBarChanged(failure: "error -1743", request: 1))
    #expect(effects == [.move(.belowMenuBar), .showError("StableBar couldn’t hide the macOS menu bar. \(MenuBarAutoHide.accessHint)")])
    #expect(placing.phase == .failed(.top))
}

@Test func aRestoredChoiceWaitingForAccessKeepsWaiting() {
    #expect(SetupPlacement(choice: .top, awaitingAccess: .top).phase == .awaitingAccess(.top))
    #expect(SetupPlacement(choice: .top, awaitingAccess: nil).phase == .placed(.top))
    #expect(SetupPlacement(choice: nil, awaitingAccess: nil).phase == .unchosen)
}
