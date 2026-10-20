import XCTest
@testable import StableBar

final class WidgetSetupTests: XCTestCase {
    @MainActor func testUnanchoredAddDoesNotLoadWidgetsForInsertion() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        var loads = 0
        let setup = WidgetSetup(store: store, widgetsForInsertion: { loads += 1; return [] })
        let result = await setup.add(try XCTUnwrap(setup.choices.first { $0.id == "text" }), to: .right)
        XCTAssertNotNil(result)
        XCTAssertEqual(loads, 0)
        setup.beginSheet()
        _ = await setup.add(try XCTUnwrap(setup.choices.first { $0.id == "text" }), to: .right, before: result)
        XCTAssertEqual(loads, 1)
    }

    @MainActor func testPlusAnchorUsesPendingSavedWidgetsInsteadOfTemporaryWidgets() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"first","type":"clock","position":"right"},{"id":"pending","type":"clock","position":"left"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        try store.setSessionEdits([
            .init(action: .add, properties: ["id": .string("temporary"), "type": .string("text"), "text": .string("Temporary"), "position": .string("right")]),
            .init(action: .reorder, ids: ["temporary"])
        ])
        try store.setCustomizationEdits([
            .init(action: .set, id: "pending", properties: ["position": .string("right")]),
            .init(action: .reorder, ids: ["pending", "first"])
        ])
        let setup = WidgetSetup(store: store)
        XCTAssertEqual(store.configuration?.widgets.first?.id, "temporary")
        let anchor = try setup.addAnchor(at: .right)
        XCTAssertEqual(anchor, "pending")
        let result = await setup.add(try XCTUnwrap(setup.choices.first { $0.id == "text" }), to: .right, before: anchor)
        let id = try XCTUnwrap(result)
        XCTAssertEqual(store.configuration?.widgets.filter { $0.id != "temporary" }.map(\.id), [id, "pending", "first"])
        XCTAssertFalse(String(decoding: try Data(contentsOf: fixture.url), as: UTF8.self).contains("temporary"))
        XCTAssertEqual(store.sessionEdits.count, 2)
    }

    @MainActor func testAddingBeforeAMemberOfTheFirstUnitDoesNotSplitItsGroup() async throws {
        let fixture = try ThemeGalleryFixture(#"{"groups":{"pair":{}},"widgets":[{"id":"a","type":"clock","position":"right","group":"pair"},{"id":"b","type":"clock","position":"right","group":"pair"},{"id":"last","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store)
        let before = try Data(contentsOf: fixture.url)
        let result = await setup.add(try XCTUnwrap(setup.choices.first { $0.id == "text" }), to: .right, before: "b")
        XCTAssertEqual(store.configuration?.widgets.map(\.id), [try XCTUnwrap(result), "a", "b", "last"])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
    }

    @MainActor func testOfflineBuiltInAddsToSelectedPositionOrRightAndOneUndoRestoresTheFile() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"left","type":"clock","position":"left"},{"id":"right","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: fixture.directory.appending(path: "missing.json")))
        await setup.load()
        XCTAssertTrue(setup.storeUnavailable)
        XCTAssertEqual(setup.choices.count, 13)
        let before = try Data(contentsOf: fixture.url)
        let text = try XCTUnwrap(setup.choices.first { $0.id == "text" })
        let addedLeft = await setup.add(text, to: WidgetPlacement.destination(selectedID: "left", widgets: store.configuration!.widgets))
        let id = try XCTUnwrap(addedLeft)
        XCTAssertEqual(store.configuration?.widgets.filter { $0.position == .left }.map(\.id), ["left", id])
        XCTAssertEqual(store.configuration?.widgets.first { $0.id == id }?.content, .text("New widget"))
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        setup.beginSheet()
        let addedRight = await setup.add(text, to: WidgetPlacement.destination(selectedID: nil, widgets: store.configuration!.widgets))
        let right = try XCTUnwrap(addedRight)
        XCTAssertEqual(store.configuration?.widgets.filter { $0.position == .right }.map(\.id), ["right", right])
    }

    @MainActor func testMultiWidgetPackageReviewsItsContentsThenPlacesAllWidgetsInOneStep() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"existing","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "power", kind: "widgets", configuration: #"{"groups":{"power":{}},"widgets":[{"id":"battery","type":"battery","position":"left","group":"power"},{"id":"charge","type":"battery","position":"left","group":"power"}]}"#)
        let store = try fixture.store()
        defer { store.stop() }
        try store.setSessionEdits([.init(action: .bar, properties: ["height": .number(50)])])
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        await setup.load()
        let choice = try XCTUnwrap(setup.choices.first { $0.package?.id == "power" })
        XCTAssertEqual(choice.package?.id, "power")
        let before = try Data(contentsOf: fixture.url)
        let pending = await setup.add(choice, to: .right)
        XCTAssertNil(pending)
        let review = try XCTUnwrap(setup.review)
        XCTAssertEqual(review.inspection.widgets.map(\.id), ["battery", "charge"])
        let package = try fixture.packages.install(review.inspection.directory)
        let id = try setup.enable(package, settings: [:], position: .right)
        XCTAssertEqual(id, "battery")
        XCTAssertNil(setup.error)
        XCTAssertNotNil(setup.review)
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

    @MainActor func testEachPlusAddsAtItsOpenSideInOneUndoStepIncludingEmptyGroups() async throws {
        for position in WidgetPosition.allCases {
            for empty in [false, true] {
                let fixture = try ThemeGalleryFixture(empty ? #"{"widgets":[]}"# : "{\"widgets\":[{\"id\":\"first\",\"type\":\"text\",\"text\":\"First\",\"position\":\"\(position.rawValue)\"},{\"id\":\"last\",\"type\":\"clock\",\"position\":\"\(position.rawValue)\"}]}")
                defer { fixture.close() }
                let store = try fixture.store()
                defer { store.stop() }
                let before = try Data(contentsOf: fixture.url)
                let setup = WidgetSetup(store: store)
                let anchor = WidgetPlacement.addAnchor(at: position, widgets: store.configuration?.widgets ?? [])
                XCTAssertEqual(anchor, !empty && [.right, .notchLeft].contains(position) ? "first" : nil)
                let result = await setup.add(try XCTUnwrap(setup.choices.first { $0.id == "text" }), to: position, before: anchor)
                let id = try XCTUnwrap(result)
                XCTAssertEqual(store.configuration?.widgets.map(\.id), empty ? [id] : anchor == nil ? ["first", "last", id] : [id, "first", "last"])
                XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
                try store.customizationHistory.undo()
                XCTAssertEqual(try Data(contentsOf: fixture.url), before)
            }
        }
    }

    @MainActor func testAnchoredAddKeepsTemporaryCommandLineWidgetsSeparateFromSavedOrder() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"first","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        try store.setSessionEdits([.init(action: .add, properties: ["id": .string("temporary"), "type": .string("text"),
                                                                  "text": .string("Temporary"), "position": .string("left")])])
        let setup = WidgetSetup(store: store)
        let before = try Data(contentsOf: fixture.url)
        let result = await setup.add(try XCTUnwrap(setup.choices.first { $0.id == "text" }), to: .right, before: "first")
        let id = try XCTUnwrap(result)
        XCTAssertEqual(store.configuration?.widgets.filter { $0.position == .right }.map(\.id), [id, "first"])
        XCTAssertTrue(store.configuration?.widgets.contains { $0.id == "temporary" } == true)
        XCTAssertEqual(store.sessionEdits.count, 1)
        XCTAssertFalse(String(decoding: try Data(contentsOf: fixture.url), as: UTF8.self).contains("temporary"))
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertEqual(store.sessionEdits.count, 1)
    }

    @MainActor func testCommandFreePackageAddsBeforeThePlusAnchorWithoutReview() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"first","type":"clock","position":"notchLeft"}]}"#)
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "notes", kind: "widgets",
            configuration: #"{"widgets":[{"id":"note","type":"text","text":"Note","position":"right"}]}"#)
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        await setup.load()
        let before = try Data(contentsOf: fixture.url)
        let id = await setup.add(try XCTUnwrap(setup.choices.first { $0.package?.id == "notes" }), to: .notchLeft, before: "first")
        XCTAssertEqual(id, "note")
        XCTAssertNil(setup.review)
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["note", "first"])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
    }

    @MainActor func testCommandPackageKeepsItsPlusAnchorThroughReviewAndAddsAllMembersOnce() async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"first","type":"clock","position":"right"}]}"#)
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "commands", kind: nil,
            configuration: #"{"widgets":[{"id":"a","type":"text","text":"A","position":"left","onClick":"echo reviewed"},{"id":"b","type":"text","text":"B","position":"left"}]}"#)
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        await setup.load()
        let before = try Data(contentsOf: fixture.url)
        _ = await setup.add(try XCTUnwrap(setup.choices.first { $0.package?.id == "commands" }), to: .right, before: "first")
        let review = try XCTUnwrap(setup.review)
        XCTAssertEqual(review.before, "first")
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
        let installed = try fixture.packages.install(review.inspection.directory)
        _ = try setup.enable(installed, settings: [:], position: review.position, before: review.before)
        XCTAssertEqual(store.configuration?.widgets.map(\.id), ["a", "b", "first"])
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        try store.customizationHistory.undo()
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
    }

    @MainActor func testCommandFreePackageWithHostsRequiresReview() async throws {
        try await assertCommandFreePackageRequiresReview(hosts: #"["example.com"]"#)
    }

    @MainActor func testCommandFreePackageWithPermissionsRequiresReview() async throws {
        try await assertCommandFreePackageRequiresReview(permissions: #"["calendars"]"#)
    }

    @MainActor func testCommandFreePackageWithRequiredToolsRequiresReview() async throws {
        try await assertCommandFreePackageRequiresReview(requires: #"["curl"]"#)
    }

    @MainActor func testCommandFreePackageWithSecretSettingsRequiresReview() async throws {
        try await assertCommandFreePackageRequiresReview(settings: #"{"token":{"type":"secret"}}"#)
    }

    @MainActor private func assertCommandFreePackageRequiresReview(hosts: String = "[]", permissions: String = "[]",
                                                                  requires: String = "[]", settings: String = "{}") async throws {
        let fixture = try ThemeGalleryFixture(#"{"widgets":[{"id":"first","type":"clock","position":"notchLeft"}]}"#)
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "review", kind: "widgets",
            configuration: #"{"widgets":[{"id":"note","type":"text","text":"Note","position":"right"}]}"#,
            settings: settings, hosts: hosts, permissions: permissions, requires: requires)
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        await setup.load()
        let choice = try XCTUnwrap(setup.choices.first { $0.package?.id == "review" })
        let before = try Data(contentsOf: fixture.url)
        let result = await setup.add(choice, to: .notchLeft, before: "first")
        XCTAssertNil(result)
        XCTAssertNil(setup.error)
        let review = try XCTUnwrap(setup.review)
        XCTAssertTrue(review.inspection.commands.isEmpty)
        XCTAssertEqual(review.position, .notchLeft)
        XCTAssertEqual(review.before, "first")
        XCTAssertTrue(try fixture.packages.list().isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(store.customizationHistory.undoSteps.isEmpty)
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
        setup.beginSheet()
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
        let choice = try XCTUnwrap(setup.choices.first { $0.package?.id == "power" })
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
        let result = try await addAndReview(choice, with: setup, fixture: fixture, position: .right)
        XCTAssertEqual(result, "note")
        XCTAssertNil(setup.error)
        XCTAssertEqual(store.configuration?.widgets.first?.content, .text("Keep my text"))
        XCTAssertEqual(store.configuration?.widgets.first?.position, .left)
        XCTAssertTrue(store.customizationHistory.notice?.contains("already on the bar") == true)
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
    @MainActor func testOneRequestPerSheetIgnoresSequentialAddsAndAllowsRetryAfterFailure() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store)
        let choice = try XCTUnwrap(setup.choices.first { $0.id == "text" })
        let first = await setup.add(choice, to: .left)
        let second = await setup.add(choice, to: .right)
        XCTAssertNotNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(store.configuration?.widgets.count, 1)
        XCTAssertEqual(store.customizationHistory.undoSteps.count, 1)
        setup.beginSheet()
        let invalid = WidgetAddChoice(id: "bad", name: "Bad", symbol: "textformat", description: "Bad", properties: ["type": .string("text")])
        let failed = await setup.add(invalid, to: .right)
        XCTAssertNil(failed)
        XCTAssertFalse(setup.requestStarted)
        let retry = await setup.add(choice, to: .right)
        XCTAssertNotNil(retry)
        XCTAssertEqual(store.configuration?.widgets.count, 2)
    }

    @MainActor func testBuiltInAndStoreChoicesRemainSeparateAndBothCanBeAdded() async throws {
        let fixture = try ThemeGalleryFixture()
        defer { fixture.close() }
        let index = LocalPackageIndex(fixture: fixture)
        _ = try await index.add(id: "power", kind: "widgets", configuration: #"{"widgets":[{"id":"power","type":"battery","position":"left"}]}"#)
        let store = try fixture.store()
        defer { store.stop() }
        let setup = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
        await setup.load()
        let choice = try XCTUnwrap(setup.choices.first { $0.package?.id == "power" })
        let basic = try XCTUnwrap(setup.choices.first { $0.id == "battery" })
        XCTAssertNil(basic.package)
        let basicID = await setup.add(basic, to: .right)
        XCTAssertNotNil(basicID)
        XCTAssertTrue(try fixture.packages.list().isEmpty)
        XCTAssertNil(try fixture.document()["packages"])
        setup.beginSheet()
        let packageID = await setup.add(choice, to: .left)
        XCTAssertEqual(packageID, "power")
        XCTAssertEqual(try fixture.packages.list().map(\.id), ["power"])
        XCTAssertEqual(store.configuration?.widgets.map(\.id), [basicID!, "power"])
        XCTAssertEqual(store.configuration?.widgets.first?.content, .provider("battery"))
    }

    @MainActor func testNewPackageVersionKeepsCompatibleSettingsAndExistingPositions() async throws {
        for alreadyOnBar in [false, true] {
            let fixture = try ThemeGalleryFixture()
            defer { fixture.close() }
            let source = fixture.directory.appending(path: "sources/note")
            let package = #"{"widgets":[{"id":"note","type":"text","position":"left","text":"@setting.message"}]}"#
            try fixture.write(package, to: source.appending(path: "config.json"))
            let oldSettings = #"{"message":{"type":"string","default":"Old"},"gone":{"type":"bool","default":true},"changed":{"type":"string","default":"Old"}}"#
            let newSettings = #"{"message":{"type":"string","default":"New"},"changed":{"type":"number","default":3}}"#
            try fixture.write(#"{"id":"note","name":"Note","version":"1","kind":"widgets","entry":"config.json","settings":\#(oldSettings)}"#, to: source.appending(path: "package.json"))
            let old = try fixture.packages.install(source)
            let store = try fixture.store()
            defer { store.stop() }
            let setup = WidgetSetup(store: store)
            _ = try setup.enable(old, settings: ["message": .string("Mine"), "gone": .bool(false), "changed": .string("Old")], position: .notchLeft)
            if alreadyOnBar {
                try store.customizationHistory.change(.init(action: .unset, id: "note", properties: ["position": .null]))
                XCTAssertEqual(store.configuration?.widgets.first?.position, .left)
            } else { try setup.remove("note") }
            let index = LocalPackageIndex(fixture: fixture)
            _ = try await index.add(id: "note", kind: "widgets", configuration: package.replacingOccurrences(of: "left", with: "right"),
                                    settings: newSettings, version: "2")
            let adding = WidgetSetup(store: store, client: PackageStoreClient(packages: fixture.packages, indexURL: index.url))
            await adding.load()
            let choice = try XCTUnwrap(adding.choices.first { $0.package?.id == "note" })
            let selected = try await addAndReview(choice, with: adding, fixture: fixture, position: .right)
            XCTAssertNil(adding.error)
            let settings: [String: ConfigurationValue] = ["message": .string("Mine")]
            XCTAssertEqual(selected, "note")
            XCTAssertEqual(store.configuration?.widgets.first?.content, .text("Mine"))
            XCTAssertEqual(store.configuration?.widgets.first?.position, alreadyOnBar ? .left : .right)
            XCTAssertEqual(store.configuration?.widgets.first?.enabled, true)
            XCTAssertEqual(store.customizationHistory.notice?.contains("already on the bar") == true, alreadyOnBar)
            let selection = try XCTUnwrap(fixture.document()["packages"]?.decoded([WidgetPackageSelection].self).first)
            XCTAssertEqual(selection.version, "2")
            XCTAssertEqual(selection.settings, settings)
        }
    }

    @MainActor func testAddingAPackageKeepsSavedSettingsSeparateFromCommandLineSettings() async throws {
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
        _ = try setup.enable(installed, settings: ["message": .string("Saved")], position: .left)
        try store.setSessionEdits([.init(action: .package, properties: ["id": .string("note"), "version": .string("1"),
            "settings": .object(["message": .string("Temporary")])])])
        await setup.load()
        let choice = try XCTUnwrap(setup.choices.first { $0.package?.id == "note" })
        let id = try await addAndReview(choice, with: setup, fixture: fixture, position: .right)
        XCTAssertEqual(id, "note")
        XCTAssertNil(setup.error)
        XCTAssertEqual(try fixture.document()["packages"]?.decoded([WidgetPackageSelection].self).first?.settings,
                       ["message": .string("Saved")])
        XCTAssertEqual(store.configuration?.widgets.first?.content, .text("Temporary"))
        XCTAssertEqual(store.sessionEdits.count, 1)
    }

    @MainActor private func addAndReview(_ choice: WidgetAddChoice, with setup: WidgetSetup,
                                         fixture: ThemeGalleryFixture, position: WidgetPosition) async throws -> String? {
        if let id = await setup.add(choice, to: position) { return id }
        let review = try XCTUnwrap(setup.review)
        let inspection: WidgetPackageInspection
        if try fixture.packages.list().contains(where: { $0.versionKey == review.inspection.manifest.versionKey }) {
            inspection = review.inspection
        } else {
            inspection = try fixture.packages.install(review.inspection.directory)
        }
        return try setup.enable(inspection, settings: setup.savedSettings(for: inspection.manifest), position: position)
    }

}
