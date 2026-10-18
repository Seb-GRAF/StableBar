import XCTest
@testable import StableBar

final class WidgetAddCatalogTests: XCTestCase {
    func testEveryBuiltInHasUsefulMetadataAndValidDefaults() throws {
        let choices = WidgetAddCatalog.compose()
        XCTAssertEqual(choices.map(\.name), ["Clock", "Active app", "Battery", "Sound", "CPU", "Network", "Calendar", "Workspaces", "Text", "Spacer", "Script"])
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
        XCTAssertTrue(choices.first { $0.id == "workspaces" }!.description.contains("AeroSpace or yabai"))
        XCTAssertEqual(choices.filter { $0.matches("SOUND") }.map(\.id), ["audio"])
    }

    func testNativePackageFoldsIntoItsBuiltInAndOtherPackagesRemainSeparateBeforeScript() throws {
        let battery = try entry("battery-plus")
        let commands = try entry("battery-commands")
        let date = try entry("date")
        let choices = WidgetAddCatalog.compose([
            .init(entry: battery, nativeSource: "battery"),
            .init(entry: commands, nativeSource: nil),
            .init(entry: date, nativeSource: nil)
        ])
        XCTAssertEqual(choices.count, WidgetAddCatalog.builtIns.count + 2)
        let folded = try XCTUnwrap(choices.first { $0.id == "battery" })
        XCTAssertEqual(folded.package?.id, "battery-plus")
        XCTAssertEqual(folded.name, "Battery")
        XCTAssertNotNil(folded.properties)
        XCTAssertTrue(choices.contains { $0.id == "store/battery-commands" })
        XCTAssertTrue(choices.contains { $0.id == "store/date" && $0.matches("Store") })
        XCTAssertTrue(choices.last!.isScript)
    }

    func testMultipleNativePackagesStillProduceOneNativeEntry() throws {
        let choices = WidgetAddCatalog.compose([
            .init(entry: try entry("battery-one"), nativeSource: "battery"),
            .init(entry: try entry("battery-two"), nativeSource: "battery")
        ])
        XCTAssertEqual(choices.count, WidgetAddCatalog.builtIns.count)
        XCTAssertEqual(choices.first { $0.id == "battery" }?.package?.id, "battery-one")
        XCTAssertEqual(choices.filter { $0.package != nil }.count, 1)
    }

    func testInspectedPackagesFoldOnlyWhenAllWidgetsUseOneNativeSourceAndThereAreNoCommands() async throws {
        let examples: [(String, String?)] = [
            (#"{"widgets":[{"id":"one","type":"battery","position":"left"},{"id":"two","type":"battery","position":"left"}]}"#, "battery"),
            (#"{"providers":{"power":{"type":"battery"}},"templates":{"native":{"type":"provider","provider":"power","position":"left"}},"widgets":[{"id":"one","template":"native"}]}"#, "battery"),
            (#"{"widgets":[{"id":"one","type":"battery","position":"left","onClick":"echo review"}]}"#, nil),
            (#"{"widgets":[{"id":"one","type":"battery","position":"left"},{"id":"two","type":"clock","position":"left"}]}"#, nil),
            (#"{"widgets":[{"id":"one","type":"battery","position":"left"}],"profiles":[{"name":"extra","configuration":{"widgets":[{"id":"two","type":"network","position":"left"}]}}]}"#, nil),
            (#"{"widgets":[{"id":"date","type":"clock","position":"left"}]}"#, nil)
        ]
        for (configuration, expected) in examples {
            let fixture = try ThemeGalleryFixture()
            defer { fixture.close() }
            let index = LocalPackageIndex(fixture: fixture)
            _ = try await index.add(id: "widget", kind: nil, configuration: configuration)
            let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
            let choices = try await client.widgetChoices()
            XCTAssertEqual(choices.count, 1, configuration)
            XCTAssertEqual(choices.first?.nativeSource, expected, configuration)
            XCTAssertTrue(try fixture.packages.list().isEmpty)
        }
    }

    func testAnUnavailableArchiveLeavesBuiltInFallbackWithoutDuplicate() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "battery", kind: "widgets", configuration: #"{"widgets":[{"id":"power","type":"battery","position":"left"}]}"#)
        try FileManager.default.removeItem(at: index.url.deletingLastPathComponent().appending(path: "battery.tar.gz"))
        let packages = try await PackageStoreClient(packages: fixture.packages, indexURL: index.url).widgetChoices()
        XCTAssertTrue(packages.isEmpty)
        XCTAssertEqual(WidgetAddCatalog.compose(packages).map(\.id), WidgetAddCatalog.builtIns.map(\.id))
        XCTAssertNil(WidgetAddCatalog.compose(packages).first { $0.id == "battery" }?.package)
    }

    private func entry(_ id: String) throws -> PackageIndex.Entry {
        try JSONDecoder().decode(PackageIndex.Entry.self, from: Data(#"{"id":"\#(id)","name":"\#(id)","version":"1","archive":"x.tar.gz","sha256":"x","source":"https://example.com"}"#.utf8))
    }
}
