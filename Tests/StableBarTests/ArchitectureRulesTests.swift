import Foundation
import Testing
@testable import StableBar

// The architecture rules in AGENTS.md, checked on every run. The numbers below are today's code and may only go
// down: when a test here fails, follow the rule instead of raising them.

private let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "Sources")

/// Every Swift file under `Sources`, nested ones too, by its path from there, such as `StableBar/BarStore.swift`.
private func swiftSources() throws -> [(path: String, text: String)] {
    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
    return try files.filter { $0.pathExtension == "swift" }.map { file in
        (file.pathComponents.dropFirst(sources.pathComponents.count).joined(separator: "/"),
         try String(contentsOf: file, encoding: .utf8))
    }
}

/// New state goes into a type of its own, not into `BarStore`.
@Test @MainActor func barStoreGainsNoStoredState() {
    let store = BarStore(configurationURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    let stored = Mirror(reflecting: store).children.count
    #expect(stored <= 75, "BarStore has \(stored) stored properties: put new state in a type of its own (AGENTS.md)")
}

/// A view or a task can keep a helper alive after the `BarStore` it points back at is gone, so new references to it
/// are `weak`.
@Test func unownedReferencesOnlyGoAway() throws {
    let allowed = ["StableBar/BarEditing.swift": 1, "StableBar/ConfigurationHistory.swift": 2,
                   "StableBar/WidgetPopup.swift": 1]
    let files = try swiftSources()
    #expect(files.count > 100)
    for file in files {
        let found = file.text.matches(of: #/\bunowned\b/#).count
        #expect(found <= allowed[file.path, default: 0],
                "\(file.path) has \(found) unowned references: hold a store or owner weakly (AGENTS.md)")
    }
}

/// Private macOS API stays in the files that use it today; a new one is a maintainer's decision.
@Test func privateAPIStaysInItsFiles() throws {
    let allowed: Set = ["StableBar/MenuBarDelay.swift", "StableBar/Spaces.swift", "StableBar/WidgetActions.swift"]
    let files = try swiftSources()
    #expect(files.count > 100)
    for file in files where !allowed.contains(file.path) {
        #expect(file.text.firstMatch(of: #/@_silgen_name|\b(dlsym|dlopen)\b|PrivateFrameworks/#) == nil,
                "\(file.path) calls private macOS API: ask a maintainer first (AGENTS.md)")
    }
}
