import CoreGraphics
import Foundation
@testable import StableBar
import Testing

private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 33)
private let item = CGPoint(x: 1190, y: 16)
private let start = Date(timeIntervalSinceReferenceDate: 0)

@Test func theFirstRefreshListsTheWindowsThenCapturesTheOneHoldingTheItem() {
    var listing = MenuBarWindowListing()
    #expect(listing.handle(.refresh(point: item, current: [:], at: start)) == [.list])
    #expect(listing.handle(.listed([.init(id: 1, frame: builtIn), .init(id: 2, frame: builtIn.offsetBy(dx: 1512, dy: 0))]))
            == [.capture([1])])
    #expect(listing.handle(.refresh(point: item, current: [1: builtIn], at: start)) == [.capture([1])])
}

@Test func aWindowResizedSinceItWasListedIsListedAgainBeforeItsCaptured() {
    var listing = MenuBarWindowListing()
    _ = listing.handle(.refresh(point: item, current: [:], at: start))
    // Listed on an ultrawide display, which then went away.
    _ = listing.handle(.listed([.init(id: 1, frame: CGRect(x: 0, y: 0, width: 3440, height: 30))]))
    let later = start.addingTimeInterval(MenuBarWindowListing.listingInterval)
    #expect(listing.handle(.refresh(point: item, current: [1: builtIn], at: later)) == [.list])
    #expect(listing.handle(.listed([.init(id: 1, frame: builtIn)])) == [.capture([1])])
}

@Test func aStaleWindowIsNotCapturedWhileListingWaits() {
    var listing = MenuBarWindowListing()
    _ = listing.handle(.refresh(point: item, current: [:], at: start))
    _ = listing.handle(.listed([.init(id: 1, frame: CGRect(x: 0, y: 0, width: 3440, height: 30))]))
    #expect(listing.handle(.refresh(point: item, current: [1: builtIn], at: start.addingTimeInterval(1))) == [])
}

@Test func aWindowThatCantBeCapturedIsListedAgain() {
    var listing = MenuBarWindowListing()
    _ = listing.handle(.refresh(point: item, current: [:], at: start))
    _ = listing.handle(.listed([.init(id: 1, frame: builtIn)]))
    #expect(listing.handle(.captureFailed) == [])
    let later = start.addingTimeInterval(MenuBarWindowListing.listingInterval)
    #expect(listing.handle(.refresh(point: item, current: [1: builtIn], at: later)) == [.list])
}

@Test func aResizedWindowIsListedAgainEvenWhenAnUnchangedOneAlsoHoldsTheItem() {
    var listing = MenuBarWindowListing()
    _ = listing.handle(.refresh(point: item, current: [:], at: start))
    _ = listing.handle(.listed([.init(id: 1, frame: builtIn), .init(id: 2, frame: CGRect(x: 0, y: 0, width: 3440, height: 30))]))
    let later = start.addingTimeInterval(MenuBarWindowListing.listingInterval)
    #expect(listing.handle(.refresh(point: item, current: [1: builtIn, 2: builtIn], at: later)) == [.list])
    #expect(listing.handle(.refresh(point: item, current: [1: builtIn, 2: builtIn], at: later.addingTimeInterval(1))) == [.capture([1])])
}
