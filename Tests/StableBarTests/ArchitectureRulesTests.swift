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

/// A view or a task can keep a helper alive after the `BarStore` it points back at is gone, so references back to it
/// are `weak`.
@Test func noUnownedReferences() throws {
    let files = try swiftSources()
    #expect(files.count > 100)
    for file in files {
        #expect(file.text.firstMatch(of: #/\bunowned\b/#) == nil,
                "\(file.path) has an unowned reference: hold a store or owner weakly (AGENTS.md)")
    }
}

/// Private macOS API is looked up at runtime in PrivateAPI.swift, so a macOS without one of its calls only turns that
/// feature off; a new call is a maintainer's decision. `@_silgen_name` binds at launch, so it's never used.
@Test func privateAPIStaysInItsFile() throws {
    let files = try swiftSources()
    #expect(files.count > 100)
    for file in files {
        #expect(file.text.firstMatch(of: #/@_silgen_name/#) == nil, """
            \(file.path) binds a private symbol at launch, so a macOS without it can't open StableBar: \
            look it up in PrivateAPI.swift (AGENTS.md)
            """)
        guard file.path != "StableBar/PrivateAPI.swift" else { continue }
        #expect(file.text.firstMatch(of: #/\b(dlsym|dlopen)\b|PrivateFrameworks/#) == nil,
                "\(file.path) calls private macOS API: add it to PrivateAPI.swift, with a maintainer's OK (AGENTS.md)")
    }
}
