import CoreGraphics
import Testing
@testable import StableBar

// Window list entries as macOS 27.2 reports them for a MacBook display beside an external one.
private let laptop = CGRect(x: -1800, y: 0, width: 1800, height: 1169)
private let external = CGRect(x: 0, y: 0, width: 2560, height: 1440)
private let displays: [CGDirectDisplayID: CGRect] = [1: laptop, 2: external]

private func window(_ owner: String, layer: Int, _ bounds: CGRect) -> [String: Any] {
    [kCGWindowOwnerName as String: owner, kCGWindowLayer as String: layer,
     kCGWindowBounds as String: bounds.dictionaryRepresentation]
}

private var strip: [String: Any] { window("MenuBarAgent", layer: 25, CGRect(x: -1800, y: 0, width: 1800, height: 39)) }
private var bar: [String: Any] { window("StableBar", layer: 3, CGRect(x: -1800, y: 0, width: 1800, height: 38)) }

@Test func menuBarStripRaisesTheBarOnlyOnTheDisplayItCovers() {
    let state = MenuBarStripState(windows: [strip, bar, window("StableBar", layer: 3, CGRect(x: 0, y: 0, width: 2560, height: 38))],
                                  displays: displays)
    #expect(state.raisesBar(on: 1))
    #expect(!state.raisesBar(on: 2))
}

@Test func menuBarStripLowersTheBarWhileTheMenuBarShowsAndSlides() {
    let shown = MenuBarStripState(windows: [window("Window Server", layer: 24, CGRect(x: -1800, y: 0, width: 1800, height: 39)), strip],
                                  displays: displays)
    #expect(!shown.raisesBar(on: 1))
    #expect(shown.showsMenuBar(on: 1))
    let sliding = MenuBarStripState(windows: [window("MenuBarAgent", layer: 24, CGRect(x: -1800, y: -20, width: 1800, height: 39)), strip],
                                    displays: displays)
    #expect(!sliding.raisesBar(on: 1))
    #expect(sliding.showsMenuBar(on: 1))
    let hidden = MenuBarStripState(windows: [window("Window Server", layer: 24, CGRect(x: -1800, y: -39, width: 1800, height: 39)), strip],
                                   displays: displays)
    #expect(hidden.raisesBar(on: 1))
    #expect(!hidden.showsMenuBar(on: 1))
}

@Test func menuBarStripIgnoresOtherWindowsAtTheStatusLevel() {
    let state = MenuBarStripState(windows: [window("Some App", layer: 25, CGRect(x: -1800, y: 0, width: 1800, height: 39)),
                                            window("MenuBarAgent", layer: 25, CGRect(x: -1500, y: 40, width: 300, height: 400)),
                                            window("MenuBarAgent", layer: 25, CGRect(x: -1800, y: 0, width: 1800, height: 1169))],
                                  displays: displays)
    #expect(!state.raisesBar(on: 1))
}

@Test func menuBarStripRaisesTheBarAboveAFullScreenWindowAtTheMenuBarLevel() {
    // screencaptureui can leave a window covering the whole display at the main menu level.
    let state = MenuBarStripState(windows: [window("screencaptureui", layer: 24, laptop),
                                            window("Window Server", layer: 24, CGRect(x: -1800, y: -39, width: 1800, height: 39)), strip],
                                  displays: displays)
    #expect(state.raisesBar(on: 1))
    #expect(!state.showsMenuBar(on: 1))
}

@Test func menuBarStripKeepsCheckingABarOnANotchedDisplayBeforeTheStripShows() {
    // Right after a wake, an unlock or a display change, a check can run before MenuBarAgent puts its strip back.
    #expect(MenuBarStripState.checkInterval(strips: [], notched: [1], shownMenuBars: [], hovering: false) == 2)
    #expect(MenuBarStripState.checkInterval(strips: [], notched: [], shownMenuBars: [], hovering: false) == nil)
    #expect(MenuBarStripState.checkInterval(strips: [1], notched: [1], shownMenuBars: [], hovering: false) == 2)
    #expect(MenuBarStripState.checkInterval(strips: [1], notched: [1], shownMenuBars: [], hovering: true) == 1.0 / 30)
    #expect(MenuBarStripState.checkInterval(strips: [1], notched: [1], shownMenuBars: [1], hovering: false) == 1.0 / 30)
    #expect(MenuBarStripState.checkInterval(strips: [], notched: [1], shownMenuBars: [1], hovering: false) == 2)
}

@Test func menuBarStripWatchesThePointerOnlyWhereMacOSRevealsTheMenuBar() {
    #expect(MenuBarStripState.nearsTop(CGPoint(x: -900, y: 0), of: laptop))
    #expect(MenuBarStripState.nearsTop(CGPoint(x: -900, y: 5), of: laptop))
    #expect(!MenuBarStripState.nearsTop(CGPoint(x: -900, y: 6), of: laptop))
    #expect(!MenuBarStripState.nearsTop(CGPoint(x: 100, y: 0), of: laptop))
}
