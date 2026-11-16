import Foundation
import Testing
@testable import StableBar

struct PackageLinkTests {
    @Test func packageLinksParseAnIDAndAnOptionalSource() throws {
        let store = try #require(PackageLink(url: URL(string: "stablebar://package/clock")!))
        #expect(store == PackageLink(id: "clock", sourceID: nil))
        let acme = try #require(PackageLink(url: URL(string: "STABLEBAR://Package/acme.clock-2_b/?source=acme&token=abc")!))
        #expect(acme == PackageLink(id: "acme.clock-2_b", sourceID: "acme"))
        #expect(PackageLink(url: URL(string: "stablebar://package/clock?source=stablebar")!)?.sourceID == "stablebar")
    }

    @Test func packageLinksRefuseAnythingButOnePackageID() {
        for bad in ["stablebar://package", "stablebar://package/", "stablebar://package/a/b", "stablebar://package/..",
                    "stablebar://package/a%20b", "stablebar://package/a%2Fb", "stablebar://packages/clock", "https://package/clock",
                    "stablebar://package/clock?source=a%20b", "stablebar://package/clock?source=", "stablebar://package/clock?source=local"] {
            #expect(PackageLink(url: URL(string: bad)!) == nil, "\(bad)")
        }
    }

    @Test func packageLinksNameTheirSourceOnlyWhenItIsPrivate() throws {
        #expect(PackageLink(id: "clock", sourceID: nil).link.absoluteString == "stablebar://package/clock")
        let acme = PackageLink(id: "clock", sourceID: "acme")
        #expect(acme.link.absoluteString == "stablebar://package/clock?source=acme")
        #expect(PackageLink(url: acme.link) == acme)
    }

    @MainActor @Test func barStoresKeepTheLastLinkTheyOpen() throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        #expect(store.receive([URL(string: "https://example.com")!, URL(string: "stablebar://other")!]) == nil)
        #expect(store.pendingLinks.package == nil && store.pendingLinks.source == nil)
        let join = PackageSourceLink(id: "acme", name: "Acme", url: URL(string: "https://a.example/index.json")!)
        #expect(store.receive([join.link, URL(string: "stablebar://package/clock")!, URL(string: "stablebar://package/..")!]) == .packages)
        #expect(store.pendingLinks.package == PackageLink(id: "clock", sourceID: nil))
        #expect(store.pendingLinks.source == nil)
        #expect(store.receive([join.link]) == .packages)
        #expect(store.pendingLinks.source == join)
    }
}
