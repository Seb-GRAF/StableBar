import Foundation
import Testing
@testable import StableBar

// The architecture rules in AGENTS.md, checked on every run. The numbers below are today's code and may only go
// down: when a test here fails, follow the rule instead of raising them.

private let sources = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "Sources")

/// Every Swift file under `Sources`, nested ones too, by its path from there, such as `StableBar/Bar/BarStore.swift`.
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
    #expect(stored <= 40, "BarStore has \(stored) stored properties: put new state in a type of its own (AGENTS.md)")
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
        // The now-playing library runs only inside perl, where its whole job is MediaRemote's private calls.
        guard file.path != "StableBar/System/PrivateAPI.swift", !file.path.hasPrefix("NowPlayingAdapter/") else { continue }
        #expect(file.text.firstMatch(of: #/\b(dlsym|dlopen)\b|PrivateFrameworks/#) == nil,
                "\(file.path) calls private macOS API: add it to PrivateAPI.swift, with a maintainer's OK (AGENTS.md)")
    }
}

/// What a `StateMachine`'s code may not use: a UI framework, work that runs later, or the clock, the disk and the
/// system, which belong to the owner that performs its effects.
private let stateMachineReaches: [(pattern: String, name: String)] = [
    (#"\bimport\s+(AppKit|SwiftUI|Cocoa|Combine)\b"#, "a UI framework"),
    (#"\b(Task|DispatchQueue|Timer|RunLoop|Thread)\b"#, "work that runs later"),
    (#"\bDate\s*(\(|\.init\b|\.now\b|=\s*\.now\b)|\b(ContinuousClock|SuspendingClock|DispatchTime|DispatchWallTime|CFAbsoluteTimeGetCurrent|mach_absolute_time)\b|\.sleep\b"#,
     "the clock"),
    (#"\b(FileManager|UserDefaults|NotificationCenter|Process|ProcessInfo|NSWorkspace|URLSession)\b"#, "the system"),
]

/// `text` without its comments and the literal parts of its strings, which name things without reaching them. What a
/// string interpolates runs, so it stays, a raw string's `\#(` included.
private func code(_ text: String) -> String {
    let characters = Array(text)
    var code = ""
    var index = 0
    // The strings open around `index`, innermost last: their quotes, the `#`s of a raw string, and how deep in
    // parentheses their interpolation is, 0 in their text.
    var strings: [(quotes: Int, hashes: Int, depth: Int)] = []
    func at(_ prefix: String) -> Bool { characters[index...].starts(with: prefix) }
    while index < characters.count {
        if let string = strings.last, string.depth == 0 {
            let close = String(repeating: "\"", count: string.quotes) + String(repeating: "#", count: string.hashes)
            let interpolation = "\\" + String(repeating: "#", count: string.hashes) + "("
            if at(interpolation) {
                strings[strings.count - 1].depth = 1
                index += interpolation.count
            } else if at(close) {
                strings.removeLast()
                index += close.count
            } else {
                index += string.hashes == 0 && characters[index] == "\\" ? 2 : 1
            }
            continue
        }
        if at("//") {
            while index < characters.count, characters[index] != "\n" { index += 1 }
            continue
        }
        // A space keeps `struct/* … */Hold` two words.
        if at("/*") {
            var depth = 0
            repeat {
                if at("/*") {
                    depth += 1
                    index += 2
                } else if at("*/") {
                    depth -= 1
                    index += 2
                } else {
                    index += 1
                }
            } while depth > 0 && index < characters.count
            code.append(" ")
            continue
        }
        let hashes = characters[index...].prefix { $0 == "#" }.count
        if index + hashes < characters.count, characters[index + hashes] == "\"" {
            index += hashes
            let quotes = at("\"\"\"") ? 3 : 1
            strings.append((quotes, hashes, 0))
            index += quotes
            continue
        }
        if !strings.isEmpty, characters[index] == "(" { strings[strings.count - 1].depth += 1 }
        if !strings.isEmpty, characters[index] == ")" {
            strings[strings.count - 1].depth -= 1
            if strings[strings.count - 1].depth == 0 {
                index += 1
                continue
            }
        }
        code.append(characters[index])
        index += 1
    }
    return code
}

/// What `code`, without comments and string text, reaches that a state machine shouldn't.
private func stateMachineViolations(_ code: String) throws -> [String] {
    // Unicode word boundaries make `UserDefaults.standard` one word, which `\b` wouldn't split.
    try stateMachineReaches.filter { code.contains(try Regex($0.pattern).wordBoundaryKind(.simple)) }.map(\.name)
}

/// Matches code that makes a type conform to `StateMachine`, directly or through protocols of `files` that refine it.
/// Its captures are the indentation, the keyword and the type's name as written, such as `Outer.Hold` for
/// `extension Outer.Hold: StateMachine`.
private func stateMachineConformance(in files: [String]) throws -> Regex<AnyRegexOutput> {
    let refinements = files.flatMap { $0.matches(of: #/\bprotocol\s+(\w+)[^{]*?:([^{]*)/#).map { (String($0.1), String($0.2)) } }
    // A protocol can refine one that refines `StateMachine`, so collect them until no new one turns up.
    var protocols: Set<String> = []
    var found: Set<String> = ["StateMachine"]
    while found != protocols {
        protocols = found
        for (name, parents) in refinements
        where parents.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).contains(where: { protocols.contains(String($0)) }) {
            found.insert(name)
        }
    }
    return try Regex(#"(?m)^([ \t]*)(?:(?:public|package|internal|fileprivate|private|final|indirect)\s+)*(struct|enum|class|actor|extension)\s+([\w.]+)(?:<[^>]*>)?\s*:[^{]*\b(?:"#
                     + protocols.sorted().joined(separator: "|") + #")\b"#).wordBoundaryKind(.simple)
}

/// The names another file's extension of a state machine writes: `Outer.State` for an `enum State` nested in `Outer`,
/// so an unrelated `State` stays out.
private func stateMachineNames(in files: [String], conformance: Regex<AnyRegexOutput>) -> Set<String> {
    Set(files.flatMap { file in
        file.matches(of: conformance).compactMap { match -> String? in
            guard let name = match.output[3].substring.map(String.init) else { return nil }
            let indent = match.output[1].substring?.count ?? 0
            return (enclosingTypes(above: match.range.lowerBound, indent: indent, in: file) + [name]).joined(separator: ".")
        }
    })
}

/// The types a declaration `indent` deep at `position` is nested in, outermost first, read from the less indented
/// declarations above it.
private func enclosingTypes(above position: String.Index, indent: Int, in file: String) -> [String] {
    var types: [String] = []
    var indent = indent
    for line in file[..<position].split(separator: "\n").reversed() where indent > 0 {
        guard let declaration = line.firstMatch(of: #/^([ \t]*)(?:\w+\s+)*?(?:struct|enum|class|actor|extension)\s+([\w.]+)/#),
              declaration.1.count < indent else { continue }
        types.insert(String(declaration.2), at: 0)
        indent = declaration.1.count
    }
    return types
}

/// Matches code that declares or extends one of `names`, nested types included, so holds part of a state machine; nil
/// without names.
private func stateMachinePart(named names: Set<String>) throws -> Regex<AnyRegexOutput>? {
    guard !names.isEmpty else { return nil }
    let alternatives = names.sorted().map { $0.replacingOccurrences(of: ".", with: #"\."#) }.joined(separator: "|")
    return try Regex(#"\b(struct|enum|class|actor|extension)\s+(\w+\.)*(?:"# + alternatives + #")\b"#)
        .wordBoundaryKind(.simple)
}

/// Decisions about state live in a `StateMachine` whose owner performs its effects, so a unit test covers every
/// transition without a window, a clock or a script.
@Test func stateMachinesDecideAndTheirOwnersAct() throws {
    let files = try swiftSources().map { (path: $0.path, code: code($0.text)) }
    #expect(files.count > 100)
    let conformance = try stateMachineConformance(in: files.map(\.code))
    let part = try stateMachinePart(named: stateMachineNames(in: files.map(\.code), conformance: conformance))
    for file in files where file.code.contains(conformance) || part.map(file.code.contains) == true {
        for reach in try stateMachineViolations(file.code) {
            Issue.record("""
                \(file.path) holds part of a StateMachine and reaches \(reach): return an effect for its owner to \
                perform instead (AGENTS.md)
                """)
        }
    }
}

/// The checks above find what they look for and only that, whichever file holds which part of a state machine.
@Test func theStateMachineCheckFindsWhatAStateMachineMayNotReach() throws {
    let pure = code("""
        struct Hold: StateMachine {
            enum Event { case opened }
            enum Effect { case none }
            /* Its owner starts a /* nested */ Task and reads Date.now. */
            mutating func handle(_ event: Event) -> [Effect] { _ = "a Task, a \\(1) Timer"; _ = #"a "Thread""#; return [] }
        }
        """)
    func names(_ files: String...) throws -> Set<String> {
        let files = files.map(code)
        return stateMachineNames(in: files, conformance: try stateMachineConformance(in: files))
    }
    #expect(try names(pure) == ["Hold"])
    #expect(try names("import Foundation\n\n// A machine.\nstruct Hold: StateMachine {}") == ["Hold"])
    #expect(try stateMachineViolations(pure).isEmpty)
    #expect(try names("extension Outer.Hold: Equatable, StateMachine {}") == ["Outer.Hold"])
    #expect(try names("struct Hold: Equatable {} // : StateMachine").isEmpty)
    #expect(try names("protocol Machine: StateMachine {}", "struct Hold: Machine {}") == ["Hold"])
    #expect(try names("protocol Base: StateMachine {}", "protocol Derived: Equatable, Base {}", "struct Hold: Derived {}") == ["Hold"])
    #expect(try names("struct/* a */Hold: StateMachine {}") == ["Hold"])
    #expect(try names("indirect enum Hold: StateMachine {}") == ["Hold"])
    let nested = "final class Outer {\n    struct Inner {\n        enum State: StateMachine {}\n    }\n}"
    #expect(try names(nested, "enum State {}") == ["Outer.Inner.State"])
    let nestedPart = try #require(try stateMachinePart(named: names(nested)))
    #expect(code("extension Outer.Inner.State { func now() -> Date { Date() } }").contains(nestedPart))
    #expect(!code("enum State {}").contains(nestedPart))
    let part = try #require(try stateMachinePart(named: ["SetupPlacement", "Outer.State"]))
    #expect(code("extension SetupPlacement.Phase { }").contains(part))
    #expect(code("extension Outer.State { }").contains(part))
    #expect(!code("struct SetupPlacementView {}").contains(part))
    #expect(!code("enum State {}").contains(part))
    #expect(try stateMachineViolations(code("import AppKit")) == ["a UI framework"])
    #expect(try stateMachineViolations(code("func later() { Task { } }")) == ["work that runs later"])
    #expect(try stateMachineViolations(code("DispatchQueue.main.async {}")) == ["work that runs later"])
    for clock in ["Date()", "Date.init()", "Date.now", "let now: Date = .now", "DispatchTime.now()", "CFAbsoluteTimeGetCurrent()",
                  #"let message = "failed at \(Date.now), not by a Timer""#, ##"let message = #"at \#(Date.now)"#"##] {
        #expect(try stateMachineViolations(code(clock)) == ["the clock"], "\(clock)")
    }
    #expect(try stateMachineViolations(code(##"let s = #"a "quoted" Task"#; let now = Date()"##)) == ["the clock"])
    #expect(try stateMachineViolations(code("let defaults = UserDefaults.standard")) == ["the system"])
    #expect(try stateMachineViolations(code("let host = ProcessInfo.processInfo.hostName")) == ["the system"])
    #expect(try stateMachineViolations(code("let text = \"\"\"\n    a Task\n    \"\"\"")).isEmpty)
}
