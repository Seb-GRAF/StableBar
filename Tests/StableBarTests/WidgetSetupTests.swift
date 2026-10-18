import XCTest
@testable import StableBar

final class WidgetSetupTests: XCTestCase {
    @MainActor func testOfflineBuiltInAddsToSelectedPositionOrRightAndOneUndoRestoresTheFile() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"left","type":"clock","position":"left"},{"id":"right","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: fixture.directory.appending(path: "missing.json")))
        await setup.load()
        XCTAssertTrue(setup.storeUnavailable)
        XCTAssertEqual(setup.choices.count, 11)
        let before = try Data(contentsOf: fixture.url)
        let text = try XCTUnwrap(setup.choices.first { $0.id == "text" })
        let addedLeft = await setup.add(text, to: WidgetPlacement.destination(selectedID: "left", widgets: store.configuration!.widgets))
        let id = try XCTUnwrap(addedLeft)
        XCTAssertEqual(store.configuration?.widgets.filter { $0.position == .left }.map(\.id), ["left", id])
        XCTAssertEqual(store.configuration?.widgets.first { $0.id == id }?.content, .text("New widget"))
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        let addedRight = await setup.add(text, to: WidgetPlacement.destination(selectedID: nil, widgets: store.configuration!.widgets))
        let right = try XCTUnwrap(addedRight)
        XCTAssertEqual(store.configuration?.widgets.filter { $0.position == .right }.map(\.id), ["right", right])
    }

    @MainActor func testCommandFreeFoldedPackageInstallsEnablesAndPlacesAllItsWidgetsInOneStep() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"existing","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "power", kind: "widgets", configuration: #"{"groups":{"power":{}},"widgets":[{"id":"battery","type":"battery","position":"left","group":"power"},{"id":"charge","type":"battery","position":"left","group":"power"}]}"#)
        let store = try fixture.store()
        defer { store.stop() }
        try store.setSessionEdits([.init(action: .bar, properties: ["height": .number(50)])])
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        await setup.load()
        let choice = try XCTUnwrap(setup.choices.first { $0.id == "battery" })
        XCTAssertEqual(choice.package?.id, "power")
        let before = try Data(contentsOf: fixture.url)
        let id = await setup.add(choice, to: .right)
        XCTAssertEqual(id, "battery")
        XCTAssertNil(setup.error)
        XCTAssertNil(setup.review)
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["existing", "battery", "charge"])
        XCTAssertEqual(store.configuration?.widgets.map(\.position), [.right, .right, .right])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        XCTAssertNotNil(try fixture.document()["widgetOrder"])
        XCTAssertNil(try fixture.document()["bar"])
        let installed = fixture.packages.directory.appending(path: "power/1/config.json")
        let packageBytes = try Data(contentsOf: installed)
        let overrides = try XCTUnwrap(fixture.document()["widgetOverrides"]?.decoded([String: [String: ConfigurationValue]].self))
        XCTAssertEqual(overrides["battery"]?["position"], .string("right"))
        try WidgetSetup(store: store).move("charge", to: .notchLeft)
        XCTAssertEqual(store.configuration?.widgets.filter { $0.group == "power" }.map(\.position), [.notchLeft, .notchLeft])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 2)
        try store.customizationHistory.change(.init(action: .set, id: "battery", properties: ["open": .string("com.apple.systempreferences")]))
        try store.customizationHistory.flush()
        try store.customizationHistory.change(.init(action: .remove, id: "charge"))
        XCTAssertEqual(store.configuration?.widgets.first { $0.id == "charge" }?.enabled, false)
        XCTAssertEqual(try Data(contentsOf: installed), packageBytes)
        try store.customizationHistory.undo()
        try store.customizationHistory.undo()
        try store.customizationHistory.undo()
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertEqual(store.sessionEdits.count, 1)
    }

    @MainActor func testCommandPackageStaysSeparateAndCannotInstallOrEnableUntilReview() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        let entry = try await index.add(id: "power", kind: nil, configuration: #"{"widgets":[{"id":"battery","type":"battery","position":"left","onClick":"echo reviewed"}]}"#)
        let store = try fixture.store()
        defer { store.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        let setup = WidgetSetup(store: store, client: client)
        await setup.load()
        XCTAssertNil(setup.choices.first { $0.id == "battery" }?.package)
        let choice = try XCTUnwrap(setup.choices.first { $0.package?.id == entry.id })
        let before = try Data(contentsOf: fixture.url)
        let result = await setup.add(choice, to: .notchRight)
        XCTAssertNil(result)
        XCTAssertNil(setup.error)
        XCTAssertEqual(setup.review?.inspection.commands, ["echo reviewed"])
        XCTAssertEqual(setup.review?.position, .notchRight)
        XCTAssertTrue(try fixture.packages.list().isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        // The existing review's confirmed Add action installs before invoking enable.
        let installed = try fixture.packages.install(try XCTUnwrap(setup.review?.inspection.directory))
        XCTAssertEqual(try setup.enable(installed, settings: [:], position: .notchRight), "battery")
        XCTAssertEqual(store.configuration?.widgets.first?.position, .notchRight)
        XCTAssertEqual(store.configuration?.widgets.first?.onClick, "echo reviewed")
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
    }

    @MainActor func testAddingAnInstalledCommandPackageReviewsItsInstalledFilesAndCanEnableAgain() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "power", kind: nil, configuration: #"{"widgets":[{"id":"battery","type":"battery","position":"left","onClick":"echo review"}]}"#)
        let store = try fixture.store()
        defer { store.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        let setup = WidgetSetup(store: store, client: client)
        await setup.load()
        let choice = try XCTUnwrap(setup.choices.first { $0.package?.id == "power" })
        _ = await setup.add(choice, to: .right)
        let installed = try fixture.packages.install(try XCTUnwrap(setup.review?.inspection.directory))
        _ = try setup.enable(installed, settings: [:], position: .right)
        try store.customizationHistory.change(.init(action: .remove, id: "battery"))
        XCTAssertEqual(store.configuration?.widgets.first?.enabled, false)
        setup.review = nil
        _ = await setup.add(choice, to: .left)
        XCTAssertNil(setup.error)
        XCTAssertEqual(setup.review?.inspection.directory, installed.directory)
        _ = try setup.enable(try XCTUnwrap(setup.review?.inspection), settings: [:], position: .left)
        XCTAssertEqual(store.configuration?.widgets.first?.enabled, true)
        XCTAssertEqual(store.configuration?.widgets.first?.position, .left)
        XCTAssertEqual(try fixture.packages.list().count, 1)
    }

    @MainActor func testInstalledCommandsCannotBypassReviewThroughACachedCommandFreeListing() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        let entry = try await index.add(id: "power", kind: nil, configuration: #"{"widgets":[{"id":"battery","type":"battery","position":"left"}]}"#)
        let store = try fixture.store()
        defer { store.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        let setup = WidgetSetup(store: store, client: client)
        await setup.load()
        let choice = try XCTUnwrap(setup.choices.first { $0.id == "battery" })
        let installed = try await client.installWithoutReview(entry)
        try fixture.write(#"{"widgets":[{"id":"battery","type":"battery","position":"left","onClick":"echo newly reviewed"}]}"#,
                          to: installed.directory.appending(path: "config.json"))
        let before = try Data(contentsOf: fixture.url)
        _ = await setup.add(choice, to: .right)
        XCTAssertEqual(setup.review?.inspection.commands, ["echo newly reviewed"])
        XCTAssertEqual(setup.review?.inspection.directory, installed.directory)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor func testAddingAnInstalledCommandFreePackageKeepsItsSavedSettings() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        let entry = try await index.add(id: "note", kind: "widgets", configuration: #"{"widgets":[{"id":"note","type":"text","position":"left","text":"@setting.message"}]}"#,
                                        settings: #"{"message":{"type":"string","default":"Default"}}"#)
        let store = try fixture.store()
        defer { store.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        let installed = try await client.installWithoutReview(entry)
        let setup = WidgetSetup(store: store, client: client)
        _ = try setup.enable(installed, settings: ["message": .string("Keep my text")], position: .left)
        await setup.load()
        let choice = try XCTUnwrap(setup.choices.first { $0.package?.id == "note" })
        let result = await setup.add(choice, to: .right)
        XCTAssertEqual(result, "note")
        XCTAssertNil(setup.error)
        XCTAssertEqual(store.configuration?.widgets.first?.content, .text("Keep my text"))
        XCTAssertEqual(store.configuration?.widgets.first?.position, .right)
        let selections = try XCTUnwrap(fixture.document()["packages"]?.decoded([WidgetPackageSelection].self))
        XCTAssertEqual(selections.first?.settings, ["message": .string("Keep my text")])
    }

    @MainActor func testPackageWithNoWidgetsInCurrentSetupDoesNotEnableAnInvisiblePackage() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        let entry = try await index.add(id: "empty", kind: "widgets", configuration: #"{"widgets":[]}"#)
        let store = try fixture.store()
        defer { store.stop() }
        let client = PackageStoreClient(packages: fixture.packages, indexURL: index.url)
        let installed = try await client.installWithoutReview(entry)
        let before = try Data(contentsOf: fixture.url)
        XCTAssertThrowsError(try WidgetSetup(store: store, client: client).enable(installed, settings: [:], position: .right))
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }

    @MainActor func testFailedAddReportsAtItsSourceWithoutChangingSelectionOrHistory() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store)
        let before = try Data(contentsOf: fixture.url)
        let invalid = WidgetAddChoice(id: "invalid", name: "Invalid", symbol: "textformat", description: "Invalid text", properties: ["type": .string("text")])
        let result = await setup.add(invalid, to: .right)
        XCTAssertNil(result)
        XCTAssertNotNil(setup.error)
        XCTAssertNil(store.customizationHistory.error)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
    }
}
