import Foundation
import CoreGraphics
import Testing
@testable import StableBar

@Test(arguments: [250.0, 1000, 2000, 3000])
func menuBarDelayReleasesAStationaryPointerAfterTheFullWait(milliseconds: Double) {
    var hover = MenuBarHover(milliseconds: milliseconds, menuBars: [CGRect(x: 0, y: 0, width: 1440, height: 30)])
    let edge = CGPoint(x: 100, y: 0)
    let held = CGPoint(x: 100, y: 4)
    let end = 1 + milliseconds / 1000
    #expect(hover.move(edge, now: 1) == held)
    #expect(hover.move(edge, now: end - 0.001) == held)
    #expect(hover.reveal(held, now: end - 0.001) == nil)
    #expect(hover.reveal(held, now: end) == edge)
    #expect(hover.move(CGPoint(x: 300, y: 20), now: end + 0.1) == CGPoint(x: 300, y: 20))
    #expect(hover.move(edge, now: end + 0.2) == edge)
}

@Test func menuBarDelayCancelsWhenThePointerLeavesAndStartsAFreshWait() {
    var hover = MenuBarHover(milliseconds: 2000, menuBars: [CGRect(x: 0, y: 0, width: 1440, height: 30)])
    let edge = CGPoint(x: 100, y: 0)
    let held = CGPoint(x: 100, y: 4)
    #expect(hover.move(edge, now: 1) == held)
    #expect(hover.move(CGPoint(x: 100, y: 10), now: 2).y == 10)
    #expect(hover.reveal(held, now: 3) == nil)
    #expect(hover.move(edge, now: 4) == held)
    #expect(hover.reveal(held, now: 5.999) == nil)
    #expect(hover.reveal(held, now: 6) == edge)
    _ = hover.move(CGPoint(x: 100, y: 100), now: 7)
    #expect(hover.move(edge, now: 8) == held)
    hover.cancel()
    #expect(hover.reveal(held, now: 10) == nil)
    #expect(hover.move(edge, now: 11) == held)
    #expect(hover.reveal(CGPoint(x: 100, y: 100), now: 13) == nil)
}

@Test func menuBarDelayStartsANewWaitOnEachDisplayAndUsesItsTopEdge() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 38)
    let other = CGRect(x: -1920, y: -200, width: 1920, height: 24)
    var hover = MenuBarHover(milliseconds: 1000, menuBars: [main, other])
    #expect(hover.move(CGPoint(x: 100, y: 0), now: 1) == CGPoint(x: 100, y: 4))
    #expect(hover.move(CGPoint(x: -100, y: -200), now: 1.5) == CGPoint(x: -100, y: -196))
    #expect(hover.reveal(CGPoint(x: -100, y: -196), now: 2) == nil)
    #expect(hover.reveal(CGPoint(x: -100, y: -196), now: 2.5) == CGPoint(x: -100, y: -200))
    #expect(hover.move(CGPoint(x: 100, y: 0), now: 3) == CGPoint(x: 100, y: 4))
    #expect(hover.reveal(CGPoint(x: 100, y: 4), now: 4) == CGPoint(x: 100, y: 0))
}

@Test func menuBarDelayZeroLeavesThePointerUnchanged() {
    var hover = MenuBarHover(milliseconds: 0, menuBars: [CGRect(x: 0, y: 0, width: 1440, height: 30)])
    let edge = CGPoint(x: 100, y: 0)
    #expect(hover.move(edge, now: 1) == edge)
    #expect(hover.deadline == nil)
}

@Test func windowClearanceMovesOnlyOverlappingWindowsAndShrinksToTheDock() {
    let display = WindowClearanceDisplay(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 60, width: 1440, height: 812),
        barFrame: CGRect(x: 0, y: 832, width: 1440, height: 40), desktopTop: 900)
    let small = CGRect(x: 150, y: 28, width: 600, height: 400)
    let moved = CGRect(x: 150, y: 68, width: 600, height: 400)
    #expect(frameBelowBar(small, displays: [display]) == moved)
    #expect(frameBelowBar(moved, displays: [display]) == nil)
    #expect(frameBelowBar(CGRect(x: 0, y: 28, width: 1440, height: 812), displays: [display])
            == CGRect(x: 0, y: 68, width: 1440, height: 772))
    #expect(frameBelowBar(CGRect(x: 100, y: 150, width: 700, height: 800), displays: [display]) == nil)
    #expect(frameBelowBar(CGRect(x: 1600, y: 0, width: 500, height: 400), displays: [display]) == nil)
}

@Test func windowClearanceUsesTheDisplayWithMostOfTheWindowAndKeepsItsHorizontalPosition() {
    let main = WindowClearanceDisplay(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 60, width: 1440, height: 802),
        barFrame: CGRect(x: 0, y: 822, width: 1440, height: 40), desktopTop: 900)
    let left = WindowClearanceDisplay(frame: CGRect(x: -1920, y: -180, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1870, y: -180, width: 1870, height: 1052),
        barFrame: CGRect(x: -1920, y: 812, width: 1920, height: 60), desktopTop: 900)
    #expect(frameBelowBar(CGRect(x: -500, y: 28, width: 800, height: 700), displays: [main, left])
            == CGRect(x: -500, y: 88, width: 800, height: 700))
    #expect(frameBelowBar(CGRect(x: -200, y: 38, width: 800, height: 802), displays: [main, left])
            == CGRect(x: -200, y: 78, width: 800, height: 762))
}

@Test func windowClearanceHandlesDisplaysAboveAndBelowThePrimaryDisplay() {
    let above = WindowClearanceDisplay(frame: CGRect(x: 0, y: 900, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 900, width: 1440, height: 872),
        barFrame: CGRect(x: 0, y: 1732, width: 1440, height: 40), desktopTop: 900)
    let below = WindowClearanceDisplay(frame: CGRect(x: 0, y: -900, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: -900, width: 1440, height: 872),
        barFrame: CGRect(x: 0, y: -68, width: 1440, height: 40), desktopTop: 900)
    #expect(frameBelowBar(CGRect(x: 100, y: -872, width: 800, height: 872), displays: [above, below])
            == CGRect(x: 100, y: -832, width: 800, height: 832))
    #expect(frameBelowBar(CGRect(x: 100, y: 928, width: 800, height: 872), displays: [above, below])
            == CGRect(x: 100, y: 968, width: 800, height: 832))
}

@Test func windowClearanceDoesNotMoveWindowsWhenTheBarIsOutsideTheUsableScreen() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = CGRect(x: 0, y: 60, width: 1440, height: 802)
    let window = CGRect(x: 100, y: 38, width: 800, height: 802)
    for bar in [CGRect(x: 0, y: 878, width: 1440, height: 22),
                CGRect(x: 0, y: -40, width: 1440, height: 40),
                CGRect(x: 0, y: 20, width: 1440, height: 40)] {
        #expect(frameBelowBar(window, displays: [WindowClearanceDisplay(frame: screen, visibleFrame: visible,
            barFrame: bar, desktopTop: 900)]) == nil)
    }
    #expect(frameBelowBar(window, displays: []) == nil)
}

@Test func notificationClearanceMovesBannerWindowsBelowTheBarOnce() {
    let display = WindowClearanceDisplay(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1131),
        barFrame: CGRect(x: 0, y: 1129, width: 1800, height: 40), desktopTop: 1169)
    let window = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    #expect(originBelowBar(window, bannerTop: 16, displays: [display]) == CGPoint(x: 0, y: 40))
    #expect(originBelowBar(window.offsetBy(dx: 0, dy: 40), bannerTop: 56, displays: [display]) == nil)
    #expect(originBelowBar(window.offsetBy(dx: 0, dy: 40), bannerTop: 52, displays: [display]) == nil)
    #expect(originBelowBar(window, bannerTop: 56, displays: [display]) == nil)
    let belowMenuBar = WindowClearanceDisplay(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169),
        visibleFrame: CGRect(x: 0, y: 0, width: 1800, height: 1131),
        barFrame: CGRect(x: 0, y: 1091, width: 1800, height: 40), desktopTop: 1169)
    #expect(originBelowBar(window, bannerTop: 54, displays: [belowMenuBar]) == CGPoint(x: 0, y: 40))
}

@Test func notificationClearanceUsesTheBarOfTheBannersDisplay() {
    let main = WindowClearanceDisplay(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 60, width: 1440, height: 802),
        barFrame: CGRect(x: 0, y: 822, width: 1440, height: 40), desktopTop: 900)
    let left = WindowClearanceDisplay(frame: CGRect(x: -1920, y: -180, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1870, y: -180, width: 1870, height: 1052),
        barFrame: CGRect(x: -1920, y: 840, width: 1920, height: 60), desktopTop: 900)
    #expect(originBelowBar(CGRect(x: -1920, y: 0, width: 1920, height: 1080), bannerTop: 16, displays: [main, left])
            == CGPoint(x: -1920, y: 60))
    #expect(originBelowBar(CGRect(x: 0, y: 0, width: 1440, height: 900), bannerTop: 16, displays: [main, left])
            == CGPoint(x: 0, y: 78))
}

@Test func notificationClearanceFindsTheNearestBannerOutsideTheNotificationList() {
    let window = [0: [1, 2], 1: [3], 2: [4], 4: [5]]
    let kinds: [Int: NotificationElement] = [4: .banner, 5: .banner]
    #expect(firstBanner(in: 0, kind: { kinds[$0] ?? .other }, children: { window[$0] ?? [] }) == 4)
    let panel = [0: [1, 2], 2: [3]]
    let panelKinds: [Int: NotificationElement] = [1: .list, 3: .banner]
    #expect(firstBanner(in: 0, kind: { panelKinds[$0] ?? .other }, children: { panel[$0] ?? [] }) == nil)
}

@Test func notificationClearanceLooksAtEachAccessibilityElementOnceAndStopsAnEndlessTree() {
    let cyclic = [0: [1, 2], 1: [0, 2], 2: [0, 1]]
    var looked: [Int] = []
    var expansions = 0
    let banner = firstBanner(in: 0, kind: { looked.append($0); return .other }, children: {
        expansions += 1
        return expansions > 1_000 ? [] : cyclic[$0] ?? []
    })
    #expect(banner == nil)
    #expect(looked == [0, 1, 2])
    var lookedInEndless = 0
    expansions = 0
    let endless = firstBanner(in: 0, limit: 50, kind: { _ in lookedInEndless += 1; return .other }, children: {
        expansions += 1
        return expansions > 1_000 ? [] : [$0 * 2 + 1, $0 * 2 + 2]
    })
    #expect(endless == nil)
    #expect(lookedInEndless == 50)
}

@Test func adaptiveLayoutKeepsHighPriorityWidgetsAndReservesOverflowSpace() {
    let planner = AdaptiveBarPlanner(inset: 10, spacing: 8, notchSpacing: 16, notch: nil)
    let plan = planner.plan(width: 300, items: [
        BarLayoutItem(id: "workspaces", position: .left, width: 150, priority: 10),
        BarLayoutItem(id: "weather", position: .right, width: 100),
        BarLayoutItem(id: "clock", position: .right, width: 80, priority: 20)
    ])
    #expect(plan.overflow == [BarOverflow(x: 260, atEnd: true, ids: ["weather"])])
    #expect(plan.placements["workspaces"] == BarPlacement(x: 10, width: 150))
    #expect(plan.placements["clock"] == BarPlacement(x: 172, width: 80))
}

@Test func adaptiveLayoutMovesTheCenterWithinFreeSpaceBeforeOverflowing() {
    let planner = AdaptiveBarPlanner(inset: 10, spacing: 8, notchSpacing: 16, notch: nil)
    let plan = planner.plan(width: 600, items: [
        BarLayoutItem(id: "left", position: .left, width: 290),
        BarLayoutItem(id: "center", position: .center, width: 150),
        BarLayoutItem(id: "right", position: .right, width: 90)
    ])
    #expect(plan.overflow.isEmpty)
    #expect(plan.placements["center"] == BarPlacement(x: 308, width: 150))
    #expect(plan.placements["right"] == BarPlacement(x: 500, width: 90))
}

@Test func adaptiveLayoutCollapsesOnlyTheCrowdedNotchSegment() {
    let planner = AdaptiveBarPlanner(inset: 10, spacing: 8, notchSpacing: 20, notch: 400...600)
    let plan = planner.plan(width: 1000, items: [
        BarLayoutItem(id: "left", position: .left, width: 200, priority: 10),
        BarLayoutItem(id: "music", position: .notchLeft, width: 250),
        BarLayoutItem(id: "center", position: .center, width: 120),
        BarLayoutItem(id: "clock", position: .right, width: 80)
    ])
    #expect(plan.overflow == [BarOverflow(x: 218, atEnd: true, ids: ["music"])])
    #expect(plan.placements["left"] == BarPlacement(x: 10, width: 200))
    #expect(plan.placements["center"]!.x >= 620)
    #expect(plan.placements["clock"]!.x + 80 == 990)
}

@Test func notchedSidesOverflowTheWidgetsNextToTheNotchIntoAButtonBesideTheRest() {
    let plan = AdaptiveBarPlanner(inset: 10, spacing: 8, notchSpacing: 20, notch: 400...600).plan(width: 1000, items: [
        BarLayoutItem(id: "music", position: .notchLeft, width: 100),
        BarLayoutItem(id: "apple", position: .left, width: 150),
        BarLayoutItem(id: "menus", position: .left, width: 150),
        BarLayoutItem(id: "weather", position: .notchRight, width: 150),
        BarLayoutItem(id: "cpu", position: .right, width: 150),
        BarLayoutItem(id: "clock", position: .right, width: 100)
    ])
    #expect(plan.overflow == [BarOverflow(x: 326, atEnd: true, ids: ["music"]), BarOverflow(x: 694, atEnd: false, ids: ["weather"])])
    #expect(plan.placements["menus"] == BarPlacement(x: 168, width: 150))
    #expect(plan.placements["cpu"] == BarPlacement(x: 732, width: 150))
}

@Test func namedGroupsCollapseAsAUnitAndKeepOriginalMemberOrder() throws {
    let config = try JSONDecoder().decode(Configuration.self, from: Data(#"""
    {"groups":{"stats":{"style":{}}},"widgets":[
      {"id":"cpu","type":"text","text":"CPU","position":"right","group":"stats"},
      {"id":"clock","type":"clock","position":"right","priority":10},
      {"id":"ram","type":"text","text":"RAM","position":"right","group":"stats"}
    ]}
    """#.utf8))
    let units = BarUnit.make(widgets: config.widgets, groups: config.groups)
    #expect(units.map(\.id) == ["group:stats", "widget:clock"])
    #expect(units[0].widgets.map(\.id) == ["cpu", "ram"])
    let plan = AdaptiveBarPlanner(inset: 10, spacing: 8, notchSpacing: 16, notch: nil).plan(width: 200, items: units.map {
        BarLayoutItem(id: $0.id, position: $0.position, width: 120, priority: $0.priority, canOverflow: $0.canOverflow)
    })
    #expect(plan.overflow.map(\.ids) == [["group:stats"]])
    #expect(plan.placements["widget:clock"] != nil)
}

@Test func neverOverflowWidgetsRemainReachableOnVeryNarrowDisplays() {
    let plan = AdaptiveBarPlanner(inset: 10, spacing: 8, notchSpacing: 16, notch: nil).plan(width: 100, items: [
        BarLayoutItem(id: "required", position: .left, width: 200, canOverflow: false),
        BarLayoutItem(id: "optional", position: .right, width: 50)
    ])
    #expect(plan.overflow == [BarOverflow(x: 60, atEnd: true, ids: ["optional"])])
    #expect(plan.placements["required"] == BarPlacement(x: 10, width: 42))
}

@Test func equalPriorityOverflowOrderIsDeterministicAndSpacersUseRemainingWidth() {
    let planner = AdaptiveBarPlanner(inset: 10, spacing: 8, notchSpacing: 16, notch: nil)
    let compact = planner.plan(width: 200, items: [
        BarLayoutItem(id: "first", position: .left, width: 100),
        BarLayoutItem(id: "last", position: .right, width: 100)
    ])
    #expect(compact.overflow.map(\.ids) == [["last"]])
    let roomy = planner.plan(width: 500, items: [
        BarLayoutItem(id: "first", position: .left, width: 100),
        BarLayoutItem(id: "space", position: .left, width: 10, isSpacer: true),
        BarLayoutItem(id: "last", position: .right, width: 100)
    ])
    #expect(roomy.placements["space"] == BarPlacement(x: 118, width: 264))
    #expect(roomy.placements["last"] == BarPlacement(x: 390, width: 100))
    #expect(roomy.overflow.isEmpty)
}

@Test func popupSearchMatchesTextWithoutSearchingUndeclaredActionFields() {
    let rows = [
        ["name": "Café player", "command": "open music"],
        ["name": "Terminal", "command": "echo cafe"],
        ["name": "Music", "command": "open player"]
    ]
    #expect(searchPopupRows(rows, query: "CAFE", fields: ["name"]) == [rows[0]])
    #expect(searchPopupRows(rows, query: "", fields: ["name"]) == rows)
    #expect(searchPopupRows(rows, query: "PLAYER", fields: nil) == [rows[0], rows[2]])
}

@Test func inheritedAndStateWidthConstraintsAreCheckedOverTheWidgetsOwnStyle() throws {
    func decode(defaults: String = "{}", style: String) throws -> Configuration {
        try JSONDecoder().decode(Configuration.self, from: Data(#"""
        {"defaults":\#(defaults),"widgets":[{"id":"title","type":"text","text":"Title","position":"left","style":\#(style)}]}
        """#.utf8))
    }
    let order = "minWidth must not exceed maxWidth."
    for (defaults, style, message) in [
        ("{}", #"{"maxWidth":40,"states":{"hover":{"minWidth":100}}}"#, order),
        ("{}", #"{"minWidth":100,"states":{"warning":{"maxWidth":40}}}"#, order),
        (#"{"states":{"hover":{"maxWidth":40}}}"#, #"{"minWidth":100}"#, order),
        ("{}", #"{"states":{"hover":{"minWidth":-5}}}"#, "minWidth must be nonnegative."),
        ("{}", #"{"states":{"open":{"maxWidth":-1}}}"#, "maxWidth must be nonnegative."),
        (#"{"minWidth":200}"#, #"{"maxWidth":100}"#, order),
        (#"{"maxWidth":-1}"#, "{}", "maxWidth must be nonnegative.")
    ] {
        let error = #expect(throws: CommandFailure.self) { try decode(defaults: defaults, style: style) }
        #expect(error?.message == message, "\(style)")
    }
    let valid = try decode(style: #"{"minWidth":50,"maxWidth":100,"states":{"hover":{"minWidth":60,"maxWidth":90},"warning":{"maxWidth":70}}}"#)
    #expect(valid.widgets[0].style.states?["hover"]?.minWidth == 60)
    let overridden = try decode(defaults: #"{"minWidth":200}"#, style: #"{"minWidth":80,"maxWidth":100}"#)
    #expect(overridden.widgets[0].style.inheriting(overridden.defaults).minWidth == 80)
}
