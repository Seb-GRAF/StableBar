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
    #expect(stored <= 74, "BarStore has \(stored) stored properties: put new state in a type of its own (AGENTS.md)")
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

/// What a `StateMachine`'s code may not use: a UI framework, work that runs later, or the clock, the disk and the
/// system, which belong to the owner that performs its effects.
private let stateMachineReaches: [(pattern: String, name: String)] = [
    (#"\bimport\s+(AppKit|SwiftUI|Cocoa|Combine)\b"#, "a UI framework"),
    (#"\b(Task|DispatchQueue|Timer|RunLoop|Thread)\b"#, "work that runs later"),
    (#"\bDate\s*(\(|\.now\b)|\b(ContinuousClock|SuspendingClock)\b|\.sleep\b"#, "the clock"),
    (#"\b(FileManager|UserDefaults|NotificationCenter|Process|NSWorkspace|URLSession)\b"#, "the system"),
]

/// `text` without its comments and string literals, which name things without reaching them.
private func code(_ text: String) -> String {
    text.replacing(#/"""[\s\S]*?"""|#*"(?:[^"\\\n]|\\.)*"#*|/\*[\s\S]*?\*/|//[^\n]*/#, with: "")
}

/// What `text`, code that's part of a `StateMachine`, reaches that it shouldn't.
private func stateMachineViolations(_ text: String) throws -> [String] {
    let code = code(text)
    // Unicode word boundaries make `UserDefaults.standard` one word, which `\b` wouldn't split.
    return try stateMachineReaches.filter { code.contains(try Regex($0.pattern).wordBoundaryKind(.simple)) }.map(\.name)
}

/// The types `text` makes conform to `StateMachine`, such as `Hold` for `extension Outer.Hold: StateMachine`.
private func stateMachineNames(_ text: String) -> [String] {
    code(text).matches(of: #/\b(?:struct|enum|class|actor|extension)\s+(?:\w+\.)*(\w+)(?:<[^>]*>)?\s*:[^{]*\bStateMachine\b/#)
        .map { String($0.1) }
}

/// Whether `text` declares or extends one of `names`, so holds part of a state machine.
private func holdsStateMachine(_ text: String, named names: Set<String>) throws -> Bool {
    let code = code(text)
    return try names.contains { name in
        code.contains(try Regex(#"\b(struct|enum|class|actor|extension)\s+(\w+\.)*"# + name + #"\b"#))
    }
}

/// Decisions about state live in a `StateMachine` whose owner performs its effects, so a unit test covers every
/// transition without a window, a clock or a script.
@Test func stateMachinesDecideAndTheirOwnersAct() throws {
    let files = try swiftSources()
    #expect(files.count > 100)
    let names = Set(files.flatMap { stateMachineNames($0.text) })
    for file in files where try holdsStateMachine(file.text, named: names) {
        for reach in try stateMachineViolations(file.text) {
            Issue.record("""
                \(file.path) holds part of a StateMachine and reaches \(reach): return an effect for its owner to \
                perform instead (AGENTS.md)
                """)
        }
    }
}

/// The checks above find what they look for and only that, whichever file holds which part of a state machine.
@Test func theStateMachineCheckFindsWhatAStateMachineMayNotReach() throws {
    let pure = """
        struct Hold: StateMachine {
            enum Event { case opened }
            enum Effect { case none }
            // Its owner starts a Task and reads Date.now.
            mutating func handle(_ event: Event) -> [Effect] { _ = "a Task, a \\(1) Timer"; return [] }
        }
        """
    #expect(stateMachineNames(pure) == ["Hold"])
    #expect(try stateMachineViolations(pure).isEmpty)
    #expect(stateMachineNames("extension Outer.Hold: Equatable, StateMachine {}") == ["Hold"])
    #expect(stateMachineNames("struct Hold: Equatable {} // : StateMachine").isEmpty)
    #expect(try holdsStateMachine("extension Hold { func later() {} }", named: ["Hold"]))
    #expect(try !holdsStateMachine("struct Holder {}", named: ["Hold"]))
    #expect(try stateMachineViolations("import AppKit\n\(pure)") == ["a UI framework"])
    #expect(try stateMachineViolations("\(pure)\nfunc later() { Task { } }") == ["work that runs later"])
    #expect(try stateMachineViolations("DispatchQueue.main.async {}") == ["work that runs later"])
    #expect(try stateMachineViolations("let now = Date()") == ["the clock"])
    #expect(try stateMachineViolations("let now = Date.now") == ["the clock"])
    #expect(try stateMachineViolations("let defaults = UserDefaults.standard") == ["the system"])
}
