import Foundation
import Testing
@testable import StableBar

struct WebsiteParityTests {
    @Test func packageSlugMatchesTheWebsitesFixture() throws {
        struct Pair: Decodable {
            let name: String
            let id: String
        }

        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/theme-link/slugs.json")
        let pairs = try JSONDecoder().decode([Pair].self, from: Data(contentsOf: fixture))
        for pair in pairs {
            #expect(packageSlug(pair.name) == pair.id)
        }
    }
}
