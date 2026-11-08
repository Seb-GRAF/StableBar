import Foundation
import Testing
@testable import StableBar

// The architecture rules in AGENTS.md, checked on every run. The numbers below are today's code and may only go
// down: when a test here fails, follow the rule instead of raising them.

private let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "Sources/StableBar")

private func swiftSources() throws -> [(name: String, text: String)] {
    try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
        .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
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
    let allowed = ["BarEditing.swift": 1, "ConfigurationHistory.swift": 2, "PackageLibrary.swift": 1, "WidgetPopup.swift": 1]
    let files = try swiftSources()
    #expect(files.count > 100)
    for file in files {
        let found = file.text.matches(of: #/\bunowned\b/#).count
        #expect(found <= allowed[file.name, default: 0],
                "\(file.name) has \(found) unowned references: hold a store or owner weakly (AGENTS.md)")
    }
}

/// Private macOS API stays in the files that use it today; a new one is a maintainer's decision.
@Test func privateAPIStaysInItsFiles() throws {
    let allowed: Set = ["MenuBarDelay.swift", "Spaces.swift", "WidgetActions.swift"]
    let files = try swiftSources()
    #expect(files.count > 100)
    for file in files where !allowed.contains(file.name) {
        #expect(file.text.firstMatch(of: #/@_silgen_name|\bdlsym\(|\bdlopen\(|PrivateFrameworks/#) == nil,
                "\(file.name) calls private macOS API: ask a maintainer first (AGENTS.md)")
    }
}
