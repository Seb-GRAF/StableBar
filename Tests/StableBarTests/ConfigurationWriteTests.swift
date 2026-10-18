import XCTest
@testable import StableBar

final class ConfigurationWriteTests: XCTestCase {
    @MainActor func testCustomizePersistAndSetupPreserveSymlinksAndUpdateTheirTarget() throws {
        for action in ["Customize", "persist", "Setup"] {
            let fixture = try ThemeGalleryFixture(#"{"bar":{"height":40},"widgets":[]}"#)
            defer { fixture.close() }
            let target = fixture.directory.appending(path: "managed.json")
            try FileManager.default.moveItem(at: fixture.url, to: target)
            try FileManager.default.createSymbolicLink(atPath: fixture.url.path, withDestinationPath: "managed.json")
            let store = try fixture.store()
            defer { store.stop() }
            let before = try Data(contentsOf: target)
            try save(action, store: store)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.url.path), "managed.json", action)
            XCTAssertNotEqual(try Data(contentsOf: target), before, action)
            XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: fixture.url), action)
        }
    }

    @MainActor func testReadOnlyTargetsReportAnErrorAndLeaveTheLinkAndTargetIntact() throws {
        for action in ["Customize", "persist", "Setup"] {
            let fixture = try ThemeGalleryFixture(#"{"bar":{"height":40},"widgets":[]}"#)
            defer { fixture.close() }
            let target = fixture.directory.appending(path: "managed.json")
            try FileManager.default.moveItem(at: fixture.url, to: target)
            try FileManager.default.createSymbolicLink(atPath: fixture.url.path, withDestinationPath: "managed.json")
            let store = try fixture.store()
            defer { store.stop() }
            let before = try Data(contentsOf: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: target.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path) }
            XCTAssertThrowsError(try save(action, store: store)) { error in
                XCTAssertTrue(errorMessage(error).contains("read-only"), errorMessage(error))
            }
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.url.path), "managed.json")
            XCTAssertEqual(try Data(contentsOf: target), before)
        }
    }

    @MainActor func testUnchangedFlushPersistAndSetupNeverWriteTheFile() throws {
        let fixture = try ThemeGalleryFixture(#"{"bar":{"height":40},"widgets":[]}"#)
        defer { fixture.close() }
        let store = try fixture.store()
        defer { store.stop() }
        let date = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: date, .posixPermissions: 0o444], ofItemAtPath: fixture.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.url.path) }
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
        try store.customizationHistory.change(.init(action: .bar, properties: ["height": .number(40)]))
        try store.customizationHistory.flush()
        try store.applyEdits([], persist: true)
        try SetupPreferences().save(to: fixture.url, menuBarHeight: 24, context: store.context)
        let after = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
        XCTAssertEqual(after[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
        XCTAssertEqual(after[.systemFileNumber] as? NSNumber, attributes[.systemFileNumber] as? NSNumber)
        XCTAssertFalse(store.customizationHistory.hasPendingChanges)
        XCTAssertFalse(store.customizationHistory.canUndo)
    }

    @MainActor private func save(_ action: String, store: BarStore) throws {
        switch action {
        case "Customize":
            try store.customizationHistory.change(.init(action: .bar, properties: ["height": .number(48)]))
            try store.customizationHistory.flush()
        case "persist": try store.applyEdits([.init(action: .bar, properties: ["height": .number(48)])], persist: true)
        default: try SetupPreferences(appearance: .light).save(to: store.configurationURL, menuBarHeight: 24, context: store.context)
        }
    }
}
