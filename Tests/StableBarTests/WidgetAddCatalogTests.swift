import XCTest
@testable import StableBar

final class WidgetAddCatalogTests: XCTestCase {
    func testEveryBuiltInHasUsefulMetadataAndValidDefaults() throws {
        let choices = WidgetAddCatalog.compose()
        XCTAssertEqual(choices.map(\.name), ["Clock", "Active app", "Apple menu", "App menus", "Battery", "Sound", "CPU", "Network", "Calendar", "Workspaces", "Text", "Spacer", "Script"])
        XCTAssertEqual(Set(choices.map(\.id)).count, choices.count)
        XCTAssertTrue(choices.last!.isScript)
        for choice in choices {
            XCTAssertFalse(choice.symbol.isEmpty)
            XCTAssertFalse(choice.description.isEmpty)
            let edit = try XCTUnwrap(choice.add(position: .right, id: "new"))
            let configuration = try ConfigurationValue.object(["widgets": .array([.object(edit.properties!)])]).decoded(Configuration.self)
            XCTAssertEqual(configuration.widgets[0].position, .right)
            if choice.id == "text" { XCTAssertEqual(configuration.widgets[0].content, .text("New widget")) }
            if ["battery", "audio", "system", "network", "calendar"].contains(choice.id) {
                XCTAssertEqual(configuration.providers[choice.id]?.type, choice.id)
            }
        }
        XCTAssertTrue(choices.first { $0.id == "calendar" }!.description.contains("Calendar access"))
        XCTAssertTrue(choices.first { $0.id == "workspaces" }!.description.contains("AeroSpace, yabai or macOS Spaces"))
        XCTAssertEqual(choices.filter { $0.matches("SOUND") }.map(\.id), ["audio"])
    }

    func testStorePackagesNeverReplaceBuiltInChoices() throws {
        let entries = try [entry("battery-plus"), entry("battery-other"), entry("date")]
        let choices = WidgetAddCatalog.compose(entries)
        XCTAssertEqual(choices.count, WidgetAddCatalog.builtIns.count + entries.count)
        let battery = try XCTUnwrap(choices.first { $0.id == "battery" })
        XCTAssertNil(battery.package)
        XCTAssertEqual(battery.properties, WidgetAddCatalog.builtIns.first { $0.id == "battery" }?.properties)
        XCTAssertEqual(choices.filter { $0.package != nil }.map(\.id), ["store/battery-other", "store/battery-plus", "store/date"])
        XCTAssertTrue(choices.contains { $0.id == "store/date" && $0.matches("Store") })
        XCTAssertTrue(choices.last!.isScript)
    }

    func testCatalogLoadsWithoutDownloadingArchivesAndSelectionReportsUnavailableArchive() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "battery", kind: "widgets", configuration: #"{"widgets":[{"id":"power","type":"battery","position":"left"}]}"#)
        try FileManager.default.removeItem(at: index.url.deletingLastPathComponent().appending(path: "battery.tar.gz"))
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        let entries = try await client.widgetChoices()
        XCTAssertEqual(entries.map(\.id), ["battery"])
        let choices = WidgetAddCatalog.compose(entries)
        XCTAssertNil(choices.first { $0.id == "battery" }?.package)
        XCTAssertEqual(choices.first { $0.id == "store/battery" }?.package?.id, "battery")
        do {
            _ = try await client.packageForAdding(entries[0])
            XCTFail("Selecting an unavailable archive must report the download failure")
        } catch {}
        XCTAssertTrue(try fixture.packages.list().isEmpty)
    }

    private func entry(_ id: String) throws -> PackageIndex.Entry {
        try JSONDecoder().decode(PackageIndex.Entry.self, from: Data(#"{"id":"\#(id)","name":"\#(id)","version":"1","archive":"x.tar.gz","sha256":"x","source":"https://example.com"}"#.utf8))
    }
}
