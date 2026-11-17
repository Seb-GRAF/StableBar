@testable import StableBar
import Testing

@Test func replacingTheMenuBarAsksForAccessThenHidesItThenMovesTheBar() {
    var placing = SetupPlacement()
    #expect(placing.handle(.chose(.top, menuBarHides: false)) == [.checkAccess(request: 1)])
    #expect(placing.handle(.accessChecked(.allowed, request: 1))
            == [.changeMenuBar(hidden: true, provesAccess: true, request: 1)])
    #expect(placing.handle(.menuBarChanged(failure: nil, request: 1)) == [.move(.top), .showError(nil)])
    #expect(placing.phase == .placed(.top))
}

@Test func leavingTheTopEdgeMovesTheBarAtOnce() {
    var placing = SetupPlacement()
    #expect(placing.handle(.chose(.bottom, menuBarHides: false))
            == [.move(.bottom), .changeMenuBar(hidden: false, provesAccess: false, request: 1)])
}

@Test func refusedAccessWaitsAndAppliesOnceAllowedInSystemSettings() {
    var placing = SetupPlacement()
    _ = placing.handle(.chose(.top, menuBarHides: false))
    #expect(placing.handle(.accessChecked(.denied, request: 1)) == [.showError(nil)])
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
            == [.changeMenuBar(hidden: true, provesAccess: true, request: 2)])
}

@Test func aChangeFinishingForAnEarlierChoiceLeavesTheLatestOne() {
    var placing = SetupPlacement()
    _ = placing.handle(.chose(.bottom, menuBarHides: false))
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

@Test func aRefusedChangeExplainsAutomationAccess() {
    var placing = SetupPlacement()
    _ = placing.handle(.chose(.belowMenuBar, menuBarHides: true))
    _ = placing.handle(.accessChecked(.allowed, request: 1))
    let effects = placing.handle(.menuBarChanged(failure: "error -1743", request: 1))
    #expect(effects == [.showError("StableBar couldn’t show the macOS menu bar. \(MenuBarAutoHide.accessHint)")])
    #expect(placing.phase == .failed(.belowMenuBar))
}

@Test func aRestoredChoiceWaitingForAccessKeepsWaiting() {
    #expect(SetupPlacement(choice: .top, awaitingAccess: .top).phase == .awaitingAccess(.top))
    #expect(SetupPlacement(choice: .bottom, awaitingAccess: nil).phase == .placed(.bottom))
    #expect(SetupPlacement(choice: nil, awaitingAccess: nil).phase == .unchosen)
}
