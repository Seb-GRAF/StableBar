import Darwin
import Foundation
import os
import Security
import Testing
@testable import StableBar

/// All app, destination and Trash paths are inside one temporary directory. No real application is ever run.
private struct MoveFixture: Sendable {
    let directory: URL
    let source: URL
    let applications: URL
    let fallback: URL
    let trash: URL
    var staging: URL { directory.appending(path: "Replacement", directoryHint: .isDirectory) }
    var resumeStore: ApplicationMoveResumeStore { ApplicationMoveResumeStore(domain: "StableBarTests.Move.\(directory.lastPathComponent)") }
    var recoveryStore: ApplicationMoveRecoveryStore { ApplicationMoveRecoveryStore(domain: resumeStore.domain) }
    var destination: URL { applications.appending(path: "StableBar.app", directoryHint: .isDirectory) }
    var previous: URL { applications.appending(path: "StableBar (previous).app", directoryHint: .isDirectory) }

    init(translocated: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "application-move-test-\(UUID().uuidString)")
        source = directory.appending(path: translocated ? "AppTranslocation/random/d/StableBar.app" : "Downloads/StableBar.app", directoryHint: .isDirectory)
        applications = directory.appending(path: "Applications", directoryHint: .isDirectory)
        fallback = directory.appending(path: "Home/Applications", directoryHint: .isDirectory)
        trash = directory.appending(path: "Recoverable")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try bundle(at: source)
    }

    func bundle(at url: URL, version: String = "1.0.0", build: String = "100", id: String = "org.stablebar.app") throws {
        let contents = url.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleVersion": build,
                    "CFBundleExecutable": "StableBar", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        let executable = contents.appending(path: "MacOS/StableBar")
        try Data("stand-in app \(version)".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func mover(readOnly: Bool = false) -> ApplicationMover {
        var system = ApplicationMoveSystem()
        system.source = source
        system.applications = applications
        system.userApplications = fallback
        system.recoveryStore = recoveryStore
        system.isReadOnly = { _ in readOnly }
        system.isWritable = { _ in true }
        system.isRunning = { _ in false }
        let trash = trash
        system.trash = { url in
            let result = trash.appending(path: UUID().uuidString + ".app")
            try FileManager.default.moveItem(at: url, to: result)
            return result
        }
        system.validateCopySignature = { _ in }
        system.validateExistingSignature = { _ in }
        let staging = staging
        system.stagingDirectory = { _ in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            return staging
        }
        return ApplicationMover(system: system)
    }

    func close() {
        UserDefaults.standard.removePersistentDomain(forName: resumeStore.domain)
        try? FileManager.default.removeItem(at: directory)
    }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func noPartialCopy() throws -> Bool {
        !exists(staging)
    }
}

@Test func applicationMoveUsesWritableApplicationsAndCanRollBack() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    let mover = fixture.mover()
    let offer = try await mover.offer()
    #expect(offer.destination == fixture.destination)
    #expect(offer.action == .install)
    let transaction = try await mover.install(offer)
    #expect(transaction.trashSourceAfterLaunch)
    #expect(fixture.exists(fixture.source))
    #expect(try ApplicationBundleIdentity(at: fixture.destination) == offer.current)
    #expect(try fixture.noPartialCopy())
    try await transaction.rollback(using: mover.system)
    #expect(fixture.exists(fixture.source))
    #expect(!fixture.exists(fixture.destination))
}

@Test func applicationMoveFallsBackWithoutAnAdministratorPassword() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    var mover = fixture.mover()
    let primary = fixture.applications
    mover.system.isWritable = { $0 != primary }
    #expect(!fixture.exists(fixture.fallback))
    let offer = try await mover.offer()
    #expect(offer.destination == fixture.fallback.appending(path: "StableBar.app", directoryHint: .isDirectory))
    #expect(fixture.exists(fixture.fallback))
    _ = try await mover.install(offer)
    #expect(fixture.exists(offer.destination))
}

@Test func applicationMoveReportsBothApplicationsFoldersUnwritable() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    var mover = fixture.mover()
    mover.system.isWritable = { _ in false }
    let error = await #expect(throws: CommandFailure.self) { try await mover.offer() }
    #expect(error?.message.contains("Neither Applications folder is writable") == true)
    #expect(fixture.exists(fixture.source))
}

@Test(arguments: [("0.8.0", "99", true), ("1.0.0", "100", false), ("1.2.0", "200", false), ("1.0.0", "99", true),
                  ("1.0.0-beta.1", "200", true)])
func applicationMoveReviewsExistingVersion(version: String, build: String, replace: Bool) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: version, build: build)
    let mover = fixture.mover()
    let offer = try await mover.offer()
    #expect(offer.action == (replace ? .replace : .useExisting))
    // Merely offering has changed neither bundle.
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == version)
    let transaction = try await mover.install(offer)
    #expect(transaction.installed == replace)
    #expect((transaction.replaced != nil) == replace)
    if let previous = transaction.replaced {
        #expect(try ApplicationBundleIdentity(at: previous).version == version)
        try await transaction.rollback(using: mover.system)
        #expect(try ApplicationBundleIdentity(at: fixture.destination).version == version)
    } else {
        #expect(fixture.exists(fixture.source))
    }
}

@Test func applicationMoveNeverTouchesARunningOrForeignDestination() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    var mover = fixture.mover()
    mover.system.isRunning = { _ in true }
    let error = await #expect(throws: CommandFailure.self) { try await mover.offer() }
    #expect(error?.message.contains("Quit that copy") == true)
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "0.8.0")
    #expect(fixture.exists(fixture.source))
    try fixture.bundle(at: fixture.destination, id: "org.other.app")
    mover.system.isRunning = { _ in false }
    await #expect(throws: CommandFailure.self) { try await mover.offer() }
    #expect(try ApplicationBundleIdentity(at: fixture.destination).identifier == "org.other.app")
}

@Test func applicationMoveRechecksAfterTheConfirmation() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    let mover = fixture.mover()
    let offer = try await mover.offer()
    try fixture.bundle(at: fixture.destination, version: "1.2.0")
    await #expect(throws: CommandFailure.self) { try await mover.install(offer) }
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "1.2.0")
    #expect(fixture.exists(fixture.source))
}

@Test(arguments: [false, true])
func applicationMoveRechecksWhatChangedWhileCopying(running: Bool) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    let becameRunning = OSAllocatedUnfairLock(initialState: false)
    var mover = fixture.mover()
    mover.system.isRunning = { _ in becameRunning.withLock { $0 } }
    mover.system.copy = { from, to in
        try FileManager.default.copyItem(at: from, to: to)
        if running { becameRunning.withLock { $0 = true } }
        else { try fixture.bundle(at: fixture.destination, version: "1.2.0") }
    }
    await #expect(throws: CommandFailure.self) { try await mover.install(mover.offer()) }
    #expect(fixture.exists(fixture.source))
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == (running ? "0.8.0" : "1.2.0"))
    #expect(try fixture.noPartialCopy())
}

@Test func applicationMoveUsesPublicDiskChecksOnTemporaryPaths() throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    let system = ApplicationMoveSystem()
    let staging = try system.stagingDirectory(fixture.destination)
    defer { try? FileManager.default.removeItem(at: staging) }
    #expect(!staging.path.hasPrefix(fixture.applications.path + "/"))
    #expect(try !system.isReadOnly(fixture.source))
}

@Test(arguments: [(true, false), (false, true)])
func applicationMoveCopiesReadOnlyAndTranslocatedSources(readOnly: Bool, translocated: Bool) async throws {
    let fixture = try MoveFixture(translocated: translocated)
    defer { fixture.close() }
    let mover = fixture.mover(readOnly: readOnly)
    let transaction = try await mover.install(mover.offer())
    #expect(!transaction.trashSourceAfterLaunch)
    #expect(fixture.exists(fixture.source))
    #expect(transaction.finish(using: mover.system) == nil)
    #expect(fixture.exists(fixture.source))
    #expect(fixture.exists(fixture.destination))
}

@Test func applicationMoveKeepsTheOriginalAndTrashesItOnlyAfterLaunch() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    let mover = fixture.mover()
    let transaction = try await mover.install(mover.offer())
    #expect(transaction.trashSourceAfterLaunch)
    #expect(fixture.exists(fixture.source))
    #expect(transaction.finish(using: mover.system) == nil)
    #expect(!fixture.exists(fixture.source))
    let originals = try FileManager.default.contentsOfDirectory(at: fixture.trash, includingPropertiesForKeys: nil)
    #expect(originals.count == 1)
    #expect(try ApplicationBundleIdentity(at: #require(originals.first)).version == "1.0.0")
}

@Test(arguments: ["replacedWhileCopying", "replaced", "missing", "symlink", "missingIdentity"])
func applicationMoveFinishLeavesAnUnrecognizedSourceUntouched(reason: String) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    let identity = try ApplicationMoveFileIdentity(at: fixture.source)
    let original = fixture.directory.appending(path: "Original.app")
    let changeSource: @Sendable () throws -> Void = {
        try FileManager.default.moveItem(at: fixture.source, to: original)
        if reason == "symlink" {
            try FileManager.default.createSymbolicLink(at: fixture.source, withDestinationURL: original)
        } else if reason != "missing" {
            // The same identifier and version must not make a different directory eligible for cleanup.
            try fixture.bundle(at: fixture.source)
        }
    }
    var mover = fixture.mover()
    if reason == "replacedWhileCopying" {
        mover.system.copy = { from, to in
            try FileManager.default.copyItem(at: from, to: to)
            try changeSource()
        }
    }
    let installed = try await mover.install(mover.offer())
    var transaction = try JSONDecoder().decode(ApplicationMoveTransaction.self, from: JSONEncoder().encode(installed))
    #expect(transaction.sourceIdentity == identity)
    if reason == "missingIdentity" { transaction.sourceIdentity = nil }
    else if reason != "replacedWhileCopying" { try changeSource() }
    let current = try? ApplicationMoveFileIdentity(at: fixture.source)
    let note = transaction.finish(using: mover.system)
    #expect(note?.contains("StableBar now opens from \(fixture.destination.path)") == true)
    #expect(note?.contains(fixture.source.path) == true)
    #expect(note?.contains("left untouched") == true)
    #expect((try? ApplicationMoveFileIdentity(at: fixture.source)) == current)
    #expect(fixture.exists(fixture.source) == (reason != "missing"))
    if reason != "missingIdentity" { #expect(try ApplicationMoveFileIdentity(at: original) == identity) }
    #expect(!fixture.exists(try #require(transaction.replaced)))
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "1.0.0")
    let trashed = try FileManager.default.contentsOfDirectory(at: fixture.trash, includingPropertiesForKeys: nil)
    #expect(trashed.count == 1)
    #expect(try ApplicationBundleIdentity(at: #require(trashed.first)).version == "0.8.0")
}

@Test(arguments: ["space", "signature", "quarantine", "mismatch", "rename", "backup"])
func applicationMoveFailureCleansPartialCopiesAndRestoresOriginals(failure: String) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    let quarantine = "0081;preserve-on-failure"
    #expect(quarantine.withCString { setxattr(fixture.source.path, "com.apple.quarantine", $0, quarantine.utf8.count, 0, 0) } == 0)
    var mover = fixture.mover()
    switch failure {
    case "space": mover.system.copy = { _, to in
        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        throw POSIXError(.ENOSPC)
    }
    case "signature": mover.system.validateCopySignature = { _ in throw CommandFailure(message: "Bad signature") }
    case "quarantine": mover.system.removeQuarantine = { _ in throw POSIXError(.EACCES) }
    case "mismatch": mover.system.copy = { from, to in
        try FileManager.default.copyItem(at: from, to: to)
        try fixture.bundle(at: to, version: "0.1.0")
    }
    case "rename":
        let original = mover.system.move, destination = fixture.destination
        mover.system.move = { from, to in
            if to == destination && from.lastPathComponent == "StableBar.app" { throw POSIXError(.EACCES) }
            try original(from, to)
        }
    case "backup":
        let original = mover.system.move, destination = fixture.destination
        mover.system.move = { from, to in
            if from == destination { throw POSIXError(.EPERM) }
            try original(from, to)
        }
    default: Issue.record("Unknown test case")
    }
    await #expect(throws: (any Error).self) { try await mover.install(mover.offer()) }
    #expect(try ApplicationBundleIdentity(at: fixture.source).version == "1.0.0")
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "0.8.0")
    #expect(getxattr(fixture.source.path, "com.apple.quarantine", nil, 0, 0, 0) == quarantine.utf8.count)
    #expect(try fixture.noPartialCopy())
}

@Test func applicationMoveRemovesQuarantineRecursivelyWithoutFollowingSymlinks() throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    let file = fixture.source.appending(path: "Contents/Info.plist")
    let outside = fixture.directory.appending(path: "outside")
    try Data().write(to: outside)
    try FileManager.default.createSymbolicLink(at: fixture.source.appending(path: "Contents/link"), withDestinationURL: outside)
    let value = "0081;test"
    for url in [fixture.source, file, outside] {
        #expect(value.withCString { setxattr(url.path, "com.apple.quarantine", $0, value.utf8.count, 0, 0) } == 0)
    }
    try ApplicationMover.removeQuarantine(fixture.source)
    for url in [fixture.source, file] { #expect(getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) == -1) }
    #expect(getxattr(outside.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
}

@Test func applicationMoveChecksPublicCodeSignatureValidity() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    let executable = fixture.source.appending(path: "Contents/MacOS/StableBar")
    try FileManager.default.removeItem(at: executable)
    try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: executable)
    _ = try await runCommand("/usr/bin/codesign", arguments: ["--force", "--sign", "-", fixture.source.path], timeout: 15)
    try ApplicationMover.validateSignature(fixture.source)
    try Data("damaged executable".utf8).write(to: executable)
    #expect(throws: CommandFailure.self) { try ApplicationMover.validateSignature(fixture.source) }
}

@Test @MainActor func applicationMoveAsksBeforeReplacingAndRollsBackFailedRelaunch() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    let controller = ApplicationMoveController(isInApplications: false, mover: fixture.mover(), relaunch: { _, _ in
        throw CommandFailure(message: "Couldn’t start the relaunch helper.")
    }, quit: { Issue.record("Must not quit after a failed relaunch") })
    let resume = { ApplicationMoveResume(kind: .settings, configuration: fixture.directory.appending(path: "config.json")) }
    await controller.proceed(resume: resume)
    #expect(controller.confirmation?.contains("Replace StableBar 0.8.0") == true)
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "0.8.0")
    await controller.proceed(resume: resume)
    #expect(controller.error?.contains("relaunch helper") == true)
    #expect(!controller.isBusy)
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "0.8.0")
    #expect(fixture.exists(fixture.source))
}

@Test(arguments: [(false, false), (true, false), (false, true)])
func applicationMoveLaunchFailureRecoversTheSourceAndResume(readOnly: Bool, translocated: Bool) async throws {
    let fixture = try MoveFixture(translocated: translocated)
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    let mover = fixture.mover(readOnly: readOnly)
    let transaction = try await mover.install(mover.offer())
    let resumeStore = fixture.resumeStore
    let snapshot = ApplicationMoveResume.Setup(step: 2, preferences: SetupPreferences(), openAtLogin: true,
        menuBarHidAtStart: false, stableBarHidMenuBarAtStart: false, opensAtLoginAtStart: false)
    let resume = ApplicationMoveResume(kind: .setup, configuration: fixture.directory.appending(path: "config.json"), setup: snapshot)
    let launches = OSAllocatedUnfairLock(initialState: [URL]())
    let plan = ApplicationMoveRelaunch.Plan(transaction: transaction, resume: resume, resumeStore: resumeStore, arguments: ["--config", resume.configuration.path])
    try await ApplicationMoveRelaunch.complete(plan, using: mover.system) { url, _ in
        launches.withLock { $0.append(url) }
        if url == fixture.destination { throw CommandFailure(message: "Launch failed", exitStatus: 1) }
    }
    #expect(launches.withLock { $0 } == [fixture.destination, fixture.source])
    #expect(fixture.exists(fixture.source))
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "0.8.0")
    let restored = try #require(resumeStore.take(configuration: resume.configuration))
    #expect(restored.failure?.contains("Your original copy is unchanged") == true)
    #expect(restored.failure?.contains(fixture.source.path) == (!readOnly && !translocated))
    #expect(restored.failure?.contains("AppTranslocation") == false)
    #expect(restored.setup?.openAtLogin == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test func applicationMoveHelperStartFailureDeletesItsResumeRecord() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    let resume = ApplicationMoveResume(kind: .settings, configuration: fixture.directory.appending(path: "config.json"))
    let store = fixture.resumeStore
    let transaction = ApplicationMoveTransaction(source: fixture.source, destination: fixture.destination)
    await #expect(throws: CommandFailure.self) {
        try await ApplicationMoveRelaunch.prepare(transaction, resume: resume, store: store, arguments: []) { _, _ in
            throw CommandFailure(message: "Spawn failed")
        }
    }
    #expect(UserDefaults(suiteName: store.domain)?.data(forKey: ApplicationMoveResumeStore.key) == nil)
}

@Test func applicationMoveHelperAcknowledgesTheSavedResumeAndKeepsArguments() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    let resume = ApplicationMoveResume(kind: .settings, configuration: fixture.directory.appending(path: "a folder/config.json"))
    let store = fixture.resumeStore
    let transaction = ApplicationMoveTransaction(source: fixture.source, destination: fixture.destination)
    let planFile = OSAllocatedUnfairLock<URL?>(initialState: nil)
    try await ApplicationMoveRelaunch.prepare(transaction, resume: resume, store: store, arguments: ["--config", "relative.json"]) { executable, arguments in
        #expect(executable == fixture.source.appending(path: "Contents/MacOS/StableBar").path)
        #expect(UserDefaults(suiteName: store.domain)?.data(forKey: ApplicationMoveResumeStore.key) != nil)
        #expect(arguments[0] == "--finish-application-move")
        #expect(arguments[2] == String(getpid()))
        let file = URL(filePath: arguments[1])
        planFile.withLock { $0 = file }
        let plan = try JSONDecoder().decode(ApplicationMoveRelaunch.Plan.self, from: Data(contentsOf: file))
        #expect(plan.arguments == ["--config", resume.configuration.path])
        try Data().write(to: file.deletingLastPathComponent().appending(path: "ready"))
    }
    let plan = try #require(planFile.withLock { $0 })
    try FileManager.default.removeItem(at: plan.deletingLastPathComponent())
}

@Test func applicationMoveWaitsForOnlyItsCapturedProcessToExit() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    // A harmless process held by a pipe: no application is opened and no process is killed by name.
    let input = Pipe()
    let process = Process()
    process.executableURL = URL(filePath: "/bin/cat")
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer { try? input.fileHandleForWriting.close(); process.waitUntilExit() }
    let ready = fixture.directory.appending(path: "ready")
    let finished = OSAllocatedUnfairLock(initialState: false)
    let task = Task {
        try await ApplicationMoveExitWaiter().wait(for: process.processIdentifier, ready: ready)
        finished.withLock { $0 = true }
    }
    for _ in 0..<1000 {
        if fixture.exists(ready) { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(fixture.exists(ready))
    #expect(!finished.withLock { $0 })
    try input.fileHandleForWriting.close()
    try await task.value
    #expect(finished.withLock { $0 })
}

@Test func applicationMoveRollbackRenamesThePreviousCopyWithoutReadingTheTrash() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    var mover = fixture.mover()
    mover.system.trash = { _ in
        Issue.record("No app should reach the Trash before a successful launch")
        throw POSIXError(.EPERM)
    }
    let transaction = try await mover.install(mover.offer())
    let previous = try #require(transaction.replaced)
    #expect(previous.deletingLastPathComponent() == fixture.applications)
    #expect(previous.lastPathComponent.hasPrefix("."))
    #expect(try ApplicationBundleIdentity(at: previous).version == "0.8.0")
    #expect(fixture.exists(fixture.source))
    try await transaction.rollback(using: mover.system)
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "0.8.0")
    #expect(!fixture.exists(previous))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test(arguments: ["running", "replaced", "missingIdentity", "missing", "symlink"])
func applicationMoveRollbackKeepsEveryCopyWhenTheDestinationIsUnsafe(reason: String) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    let mover = fixture.mover()
    let installed = try await mover.install(mover.offer())
    // The detached helper receives the identity through its plan, rather than in-memory state.
    var transaction = try JSONDecoder().decode(ApplicationMoveTransaction.self, from: JSONEncoder().encode(installed))
    #expect(transaction.installedIdentity == (try ApplicationMoveFileIdentity(at: fixture.destination)))
    let previous = try #require(transaction.replaced)
    let movedAside = fixture.directory.appending(path: "Installed.app")
    if ["replaced", "missing", "symlink"].contains(reason) {
        try FileManager.default.moveItem(at: fixture.destination, to: movedAside)
        if reason == "replaced" { try fixture.bundle(at: fixture.destination) }
        if reason == "symlink" {
            try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: movedAside)
        }
    }
    if reason == "missingIdentity" { transaction.installedIdentity = nil }
    var system = mover.system
    system.isRunning = { _ in reason == "running" }
    let move = system.move
    system.move = { from, to in
        #expect(from == previous)
        #expect(to == fixture.previous)
        try move(from, to)
    }
    system.trash = { _ in Issue.record("Unsafe rollback must keep every copy"); throw POSIXError(.EPERM) }
    let error = await #expect(throws: CommandFailure.self) { try await transaction.rollback(using: system) }
    let message = try #require(error?.message)
    for path in [fixture.source, fixture.destination, fixture.previous] { #expect(message.contains(path.path)) }
    #expect(message.contains("all copies were kept"))
    #expect(message.contains("Quit any running copy"))
    #expect(!message.contains("⇧⌘. (Shift-Command-Period)"))
    #expect(try ApplicationBundleIdentity(at: fixture.source).version == "1.0.0")
    #expect(!fixture.exists(previous))
    #expect(try ApplicationBundleIdentity(at: fixture.previous).version == "0.8.0")
    if reason != "missing" { #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "1.0.0") }
    if fixture.exists(movedAside) {
        #expect(try ApplicationMoveFileIdentity(at: movedAside) == installed.installedIdentity)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test(arguments: [false, true])
func applicationMoveRecoveryStillLaunchesTheSourceWhenSavingFails(sourceLaunchFails: Bool) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    let mover = fixture.mover()
    let transaction = try await mover.install(mover.offer())
    let resume = ApplicationMoveResume(kind: .settings, configuration: fixture.directory.appending(path: "config.json"))
    let plan = ApplicationMoveRelaunch.Plan(transaction: transaction, resume: resume, resumeStore: fixture.resumeStore,
                                           arguments: ["--config", resume.configuration.path])
    let launches = OSAllocatedUnfairLock(initialState: [URL]())
    let recover = {
        try await ApplicationMoveRelaunch.complete(plan, using: mover.system, saveResume: { _, _ in
            throw CommandFailure(message: "Couldn’t save setup.")
        }) { app, arguments in
            #expect(arguments == plan.arguments)
            launches.withLock { $0.append(app) }
            if app == fixture.destination || sourceLaunchFails {
                throw CommandFailure(message: "Launch failed", exitStatus: 1)
            }
        }
    }
    let message: String?
    if sourceLaunchFails {
        message = await #expect(throws: CommandFailure.self) { try await recover() }?.message
    } else {
        message = try await recover()
    }
    #expect(message?.contains("Couldn’t restore where setup left off") == true)
    #expect(launches.withLock { $0 } == [fixture.destination, fixture.source])
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "0.8.0")
    #expect(try ApplicationBundleIdentity(at: fixture.source).version == "1.0.0")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test(arguments: [false, true]) @MainActor
func applicationMoveCapturesSessionEditsAfterCopying(setup: Bool) async throws {
    let fixture = try MoveFixture()
    let configuration = try ThemeGalleryFixture(#"{"widgets":[]}"#)
    let store = BarStore(configurationURL: configuration.url, themesDirectory: configuration.themes)
    store.reloadConfiguration()
    defer { store.stop(); configuration.close(); fixture.close() }
    let baseline = ConfigurationEdit(action: .bar, properties: ["offset": .number(11)])
    try store.setSessionEdits([baseline])
    var system = SetupSystem()
    system.defaults = try #require(UserDefaults(suiteName: fixture.resumeStore.domain))
    system.menuBarHides = { false }
    system.setMenuBarHidden = { _ in Issue.record("The move must not change this Mac’s menu bar") }
    system.isTrusted = { true }
    system.calendarAccess = { .fullAccess }
    system.isInApplications = { false }
    system.loginStatus = { .notRegistered }
    system.setOpenAtLogin = { _ in Issue.record("The move must not register a login item") }
    system.workspaceSource = { _ in .spaces }
    let session = setup ? SetupSession(store: store, system: system) : nil
    defer { session?.cancel() }
    let copyStarted = OSAllocatedUnfairLock(initialState: false)
    let copiedOnSwiftPool = OSAllocatedUnfairLock(initialState: false)
    let releaseCopy = DispatchSemaphore(value: 0)
    var mover = fixture.mover()
    let copy = mover.system.copy
    mover.system.copy = { from, to in
        try copy(from, to)
        copiedOnSwiftPool.withLock { $0 = isOnSwiftPool() }
        copyStarted.withLock { $0 = true }
        releaseCopy.wait()
    }
    let captured = OSAllocatedUnfairLock<ApplicationMoveResume?>(initialState: nil)
    var quit = false
    let controller = ApplicationMoveController(isInApplications: false, mover: mover, relaunch: { _, resume in
        captured.withLock { $0 = resume }
    }, quit: { quit = true })
    let moving = Task {
        await controller.proceed { session?.resumeAfterMoving() ?? controller.resumeFromSettings(store: store) }
    }
    do {
        for _ in 0..<1000 {
            if copyStarted.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(copyStarted.withLock { $0 })
        try store.applyEdits([ConfigurationEdit(action: .bar, properties: ["height": .number(38)])], persist: false)
    } catch {
        releaseCopy.signal()
        await moving.value
        throw error
    }
    releaseCopy.signal()
    await moving.value
    #expect(!copiedOnSwiftPool.withLock { $0 })
    #expect(controller.error == nil)
    #expect(quit)
    #expect(captured.withLock { $0?.edits.count } == 2)
    #expect(captured.withLock { $0?.edits.first?.restored.properties } == baseline.properties)
    #expect(captured.withLock { $0?.edits.last?.restored.properties?["height"] } == .number(38))
}

@Test func applicationMoveInstallsTheVerifiedCopyAndKeepsRunningResourcesInPlace() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    let original = try FileManager.default.attributesOfItem(atPath: fixture.source.path)[.systemFileNumber] as? NSNumber
    let verification = OSAllocatedUnfairLock<URL?>(initialState: nil)
    var mover = fixture.mover()
    mover.system.validateCopySignature = { candidate in
        #expect(candidate.deletingLastPathComponent() == fixture.staging)
        #expect(fixture.exists(fixture.source.appending(path: "Contents/Info.plist")))
        verification.withLock { $0 = candidate }
    }
    let move = mover.system.move
    mover.system.move = { from, to in
        #expect(from == verification.withLock { $0 })
        #expect(to == fixture.destination)
        try move(from, to)
    }
    let transaction = try await mover.install(mover.offer())
    #expect(verification.withLock { $0 } != nil)
    #expect(try FileManager.default.attributesOfItem(atPath: fixture.source.path)[.systemFileNumber] as? NSNumber == original)
    #expect(transaction.trashSourceAfterLaunch)
    #expect(try fixture.noPartialCopy())
}

@Test(arguments: [false, true])
func applicationMoveSuccessfulLaunchTreatsTrashFailuresAsACalmNote(replacing: Bool) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    if replacing { try fixture.bundle(at: fixture.destination, version: "0.8.0") }
    var mover = fixture.mover()
    mover.system.trash = { _ in throw POSIXError(.EPERM) }
    let transaction = try await mover.install(mover.offer())
    mover.system.isRunning = { _ in true }
    let resume = ApplicationMoveResume(kind: .settings, configuration: fixture.directory.appending(path: "config.json"))
    let plan = ApplicationMoveRelaunch.Plan(transaction: transaction, resume: resume, resumeStore: fixture.resumeStore, arguments: [])
    let note = try await ApplicationMoveRelaunch.complete(plan, using: mover.system) { app, _ in
        #expect(app == fixture.destination)
    }
    #expect(note?.contains("StableBar now opens from \(fixture.destination.path)") == true)
    #expect(note?.contains(fixture.source.path) == true)
    #expect(note?.contains("Open StableBar") == false)
    if let previous = transaction.replaced {
        #expect(note?.contains(fixture.previous.path) == true)
        #expect(!fixture.exists(previous))
        #expect(fixture.exists(fixture.previous))
    }
    #expect(note?.contains("⇧⌘. (Shift-Command-Period)") == false)
    #expect(fixture.exists(fixture.source))
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "1.0.0")
}

@Test(arguments: [1, 2, 11])
func applicationMoveLateLaunchAfterTimeoutKeepsTheInstalledBundle(runningOnCheck: Int) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    var mover = fixture.mover()
    let transaction = try await mover.install(mover.offer())
    let checks = OSAllocatedUnfairLock(initialState: 0)
    mover.system.isRunning = { app in
        #expect(app == fixture.destination)
        #expect(fixture.exists(fixture.source))
        #expect((try? ApplicationBundleIdentity(at: fixture.destination))?.version == "1.0.0")
        #expect(fixture.exists(transaction.replaced!))
        return checks.withLock { $0 += 1; return $0 >= runningOnCheck }
    }
    let resume = ApplicationMoveResume(kind: .settings, configuration: fixture.directory.appending(path: "config.json"))
    let plan = ApplicationMoveRelaunch.Plan(transaction: transaction, resume: resume, resumeStore: fixture.resumeStore, arguments: [])
    let launches = OSAllocatedUnfairLock(initialState: [URL]())
    let note = try await ApplicationMoveRelaunch.complete(plan, using: mover.system, pause: {}) { app, _ in
        launches.withLock { $0.append(app) }
        throw CommandFailure(message: "Command timed out after 15.0 seconds.")
    }
    #expect(note == nil)
    #expect(checks.withLock { $0 } == runningOnCheck)
    #expect(launches.withLock { $0 } == [fixture.destination])
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "1.0.0")
    #expect(!fixture.exists(fixture.source))
    #expect(!fixture.exists(transaction.replaced!))
    let recovered = try FileManager.default.contentsOfDirectory(at: fixture.trash, includingPropertiesForKeys: nil)
    #expect(try recovered.map { try ApplicationBundleIdentity(at: $0).version }.sorted() == ["0.8.0", "1.0.0"])
}

@Test(arguments: [false, true])
func applicationMoveLateLaunchRightAfterRollbackKeepsTheRestoredBundleAndOriginal(afterSavingResume: Bool) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    var mover = fixture.mover()
    let transaction = try await mover.install(mover.offer())
    let move = mover.system.move
    mover.system.move = { from, to in
        try move(from, to)
        #expect(from == transaction.replaced)
        #expect(to == fixture.destination)
    }
    let checks = OSAllocatedUnfairLock(initialState: 0)
    mover.system.isRunning = { _ in
        checks.withLock { $0 += 1; return $0 >= (afterSavingResume ? 4 : 3) }
    }
    let resume = ApplicationMoveResume(kind: .settings, configuration: fixture.directory.appending(path: "config.json"))
    let plan = ApplicationMoveRelaunch.Plan(transaction: transaction, resume: resume, resumeStore: fixture.resumeStore, arguments: [])
    let launches = OSAllocatedUnfairLock(initialState: [URL]())
    let note = try await ApplicationMoveRelaunch.complete(plan, using: mover.system, pause: {}) { app, _ in
        launches.withLock { $0.append(app) }
        throw CommandFailure(message: "open exited with an error", exitStatus: 1)
    }
    #expect(note?.contains("Applications is now running") == true)
    #expect(checks.withLock { $0 } == (afterSavingResume ? 4 : 3))
    #expect(launches.withLock { $0 } == [fixture.destination])
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "0.8.0")
    #expect(try ApplicationBundleIdentity(at: fixture.source).version == "1.0.0")
    #expect(!fixture.exists(transaction.replaced!))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test func applicationMoveOpenErrorKeepsARunningDestinationInPlace() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    var mover = fixture.mover()
    let transaction = try await mover.install(mover.offer())
    mover.system.isRunning = { _ in true }
    let resume = ApplicationMoveResume(kind: .settings, configuration: fixture.directory.appending(path: "config.json"))
    let plan = ApplicationMoveRelaunch.Plan(transaction: transaction, resume: resume, resumeStore: fixture.resumeStore, arguments: [])
    let note = try await ApplicationMoveRelaunch.complete(plan, using: mover.system, pause: {}) { app, _ in
        #expect(app == fixture.destination)
        throw CommandFailure(message: "open exited with an error", exitStatus: 1)
    }
    #expect(note == nil)
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "1.0.0")
    #expect(!fixture.exists(fixture.source))
    #expect(!fixture.exists(transaction.replaced!))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).count == 2)
}

@Test(arguments: [false, true])
func applicationMoveUnconfirmedLaunchPreservesEveryCopy(timedOut: Bool) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    var mover = fixture.mover()
    let transaction = try await mover.install(mover.offer())
    let checks = OSAllocatedUnfairLock(initialState: 0)
    let pauses = OSAllocatedUnfairLock(initialState: 0)
    mover.system.isRunning = { _ in checks.withLock { $0 += 1 }; return false }
    let resume = ApplicationMoveResume(kind: .settings, configuration: fixture.directory.appending(path: "config.json"))
    let plan = ApplicationMoveRelaunch.Plan(transaction: transaction, resume: resume, resumeStore: fixture.resumeStore, arguments: [])
    let launches = OSAllocatedUnfairLock(initialState: [URL]())
    let note = try await ApplicationMoveRelaunch.complete(plan, using: mover.system, pause: {
        pauses.withLock { $0 += 1 }
        #expect(fixture.exists(fixture.source))
        #expect(fixture.exists(fixture.destination))
        #expect(fixture.exists(transaction.replaced!))
    }) { app, _ in
        launches.withLock { $0.append(app) }
        if timedOut { throw CommandFailure(message: "Command timed out after 15.0 seconds.") }
    }
    #expect(checks.withLock { $0 } == 11)
    #expect(pauses.withLock { $0 } == 10)
    #expect(launches.withLock { $0 } == [fixture.destination])
    #expect(note?.contains("Couldn’t confirm") == true)
    #expect(note?.contains(fixture.destination.path) == true)
    #expect(note?.contains(fixture.source.path) == true)
    #expect(note?.contains(fixture.previous.path) == true)
    #expect(note?.contains("⇧⌘. (Shift-Command-Period)") == false)
    #expect(note?.contains("Open StableBar from Applications with Finder") == true)
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "1.0.0")
    #expect(try ApplicationBundleIdentity(at: fixture.source).version == "1.0.0")
    #expect(!fixture.exists(transaction.replaced!))
    #expect(try ApplicationBundleIdentity(at: fixture.previous).version == "0.8.0")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test(arguments: [(true, false), (false, true)])
func applicationMoveUnconfirmedLaunchOmitsReadOnlyAndTranslocatedPaths(readOnly: Bool, translocated: Bool) async throws {
    let fixture = try MoveFixture(translocated: translocated)
    defer { fixture.close() }
    let mover = fixture.mover(readOnly: readOnly)
    let transaction = try await mover.install(mover.offer())
    let resume = ApplicationMoveResume(kind: .settings, configuration: fixture.directory.appending(path: "config.json"))
    let plan = ApplicationMoveRelaunch.Plan(transaction: transaction, resume: resume, resumeStore: fixture.resumeStore, arguments: [])
    let note = try await ApplicationMoveRelaunch.complete(plan, using: mover.system, pause: {}) { _, _ in }
    #expect(note?.contains("Your original copy is unchanged.") == true)
    #expect(note?.contains(fixture.source.path) == false)
    #expect(note?.contains("AppTranslocation") == false)
    #expect(fixture.exists(fixture.source))
    #expect(fixture.exists(fixture.destination))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test func applicationMoveConfirmsASuccessfulOpenBeforeTrashingAnything() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    var mover = fixture.mover()
    let transaction = try await mover.install(mover.offer())
    let running = OSAllocatedUnfairLock(initialState: false)
    mover.system.isRunning = { _ in running.withLock { $0 } }
    let resume = ApplicationMoveResume(kind: .settings, configuration: fixture.directory.appending(path: "config.json"))
    let plan = ApplicationMoveRelaunch.Plan(transaction: transaction, resume: resume, resumeStore: fixture.resumeStore, arguments: [])
    let note = try await ApplicationMoveRelaunch.complete(plan, using: mover.system, pause: {
        #expect(fixture.exists(fixture.source))
        #expect(fixture.exists(transaction.replaced!))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.trash.path))?.isEmpty == true)
        running.withLock { $0 = true }
    }) { app, _ in #expect(app == fixture.destination) }
    #expect(note == nil)
    #expect(!fixture.exists(fixture.source))
    #expect(!fixture.exists(transaction.replaced!))
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "1.0.0")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).count == 2)
}

@Test func applicationMoveOnlyTreatsACompletedCommandExitAsDefinitive() async throws {
    let failed = await #expect(throws: CommandFailure.self) {
        _ = try await runCommand("/bin/sh", arguments: ["-c", "exit 7"])
    }
    #expect(failed?.exitStatus == 7)
    let timedOut = await #expect(throws: CommandFailure.self) {
        _ = try await runCommand("/bin/sleep", arguments: ["30"], timeout: 0.1)
    }
    #expect(timedOut?.exitStatus == nil)
    #expect(timedOut?.message.contains("timed out") == true)
}

@Test(arguments: [false, true])
func applicationMoveVerifiesBeforeRemovingQuarantine(valid: Bool) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    let verified = OSAllocatedUnfairLock(initialState: false)
    var mover = fixture.mover()
    mover.system.validateCopySignature = { _ in
        if !valid { throw CommandFailure(message: "Wrong designated requirement") }
        verified.withLock { $0 = true }
    }
    mover.system.removeQuarantine = { _ in #expect(verified.withLock { $0 }) }
    if valid { _ = try await mover.install(mover.offer()) }
    else { await #expect(throws: CommandFailure.self) { try await mover.install(mover.offer()) } }
    #expect(fixture.exists(fixture.source))
}

@Test func applicationMoveRejectsAnotherValidAdHocSignatureAgainstTheDesignatedRequirement() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    let executable = fixture.source.appending(path: "Contents/MacOS/StableBar")
    try FileManager.default.removeItem(at: executable)
    try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: executable)
    _ = try await runCommand("/usr/bin/codesign", arguments: ["--force", "--sign", "-", fixture.source.path], timeout: 15)
    let code = try ApplicationMover.validateSignature(fixture.source)
    var requirement: SecRequirement?
    #expect(SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess)
    let designated = try #require(requirement)
    try FileManager.default.copyItem(at: fixture.source, to: fixture.destination)
    try ApplicationMover.validateSignature(fixture.destination, requirement: designated)
    #expect(try ApplicationMover.teamIdentifier(of: code) == nil)
    // Re-sign changed bytes with the same identifier. Valid ad-hoc code is not enough to trust our transfer.
    let resources = fixture.destination.appending(path: "Contents/Resources", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    try Data("different resource".utf8).write(to: resources.appending(path: "sample.txt"))
    _ = try await runCommand("/usr/bin/codesign", arguments: ["--force", "--sign", "-", fixture.destination.path], timeout: 15)
    try ApplicationMover.validateSignature(fixture.destination)
    #expect(throws: CommandFailure.self) { try ApplicationMover.validateSignature(fixture.destination, requirement: designated) }
}

@Test(arguments: [("TEAM", "TEAM", true), ("OTHER", "TEAM", false), (nil, "TEAM", false), (nil, nil, true), ("TEAM", nil, true)])
func applicationMoveExistingCopyRequiresOurTeamWhenPresent(candidate: String?, running: String?, accepted: Bool) throws {
    if accepted { try ApplicationMover.validateTeamIdentifier(candidate, matches: running) }
    else { #expect(throws: CommandFailure.self) { try ApplicationMover.validateTeamIdentifier(candidate, matches: running) } }
}

@Test func applicationMoveChecksTheExistingSignatureBeforeUsingIt() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination)
    var mover = fixture.mover()
    mover.system.validateCopySignature = { _ in Issue.record("Must validate the existing signature instead") }
    mover.system.validateExistingSignature = { app in
        #expect(app == fixture.destination)
        throw CommandFailure(message: "Another developer")
    }
    await #expect(throws: CommandFailure.self) { try await mover.install(mover.offer()) }
    #expect(fixture.exists(fixture.source))
    #expect(fixture.exists(fixture.destination))
}

@Test(arguments: ["1.0.0", "2.0.0"])
func applicationMoveNamesAnExistingCopyWithAnInvalidSignature(version: String) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: version)
    var mover = fixture.mover()
    mover.system.validateExistingSignature = ApplicationMover.validateExistingSignature
    let offer = try await mover.offer()
    #expect(offer.action == .useExisting)
    let error = await #expect(throws: CommandFailure.self) { try await mover.install(offer) }
    #expect(error?.message.contains(fixture.destination.path) == true)
    #expect(error?.message.contains("Move it aside with Finder, then try again.") == true)
    #expect(error?.message.contains("Download") == false)
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == version)
    #expect(fixture.exists(fixture.source))
}

@Test(arguments: [0, 1, 2])
func applicationMoveFailedRollbackKeepsAVisiblePreviousCopyAcrossLaunches(occupiedNames: Int) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    func previous(_ number: Int) -> URL {
        fixture.applications.appending(path: number == 1 ? "StableBar (previous).app" : "StableBar (previous \(number)).app")
    }
    for number in 0..<occupiedNames { try fixture.bundle(at: previous(number + 1), version: "0.7.0") }
    var mover = fixture.mover()
    let transaction = try await mover.install(mover.offer())
    let move = mover.system.move
    mover.system.move = { from, to in
        if to == fixture.destination { throw POSIXError(.EPERM) }
        try move(from, to)
    }
    let error = await #expect(throws: CommandFailure.self) { try await transaction.rollback(using: mover.system) }
    let kept = previous(occupiedNames + 1)
    #expect(error?.message.contains(kept.path) == true)
    #expect(error?.message.contains("⇧⌘. (Shift-Command-Period)") == false)
    #expect(!fixture.exists(transaction.replaced!))
    #expect(try ApplicationBundleIdentity(at: kept).version == "0.8.0")
    #expect(fixture.recoveryStore.pathsToKeep() == [])
    try fixture.bundle(at: fixture.destination)
    mover.system.source = fixture.destination
    mover.system.isRunning = { $0 == fixture.destination }
    await ApplicationMover.cleanUpPreviousCopies(using: mover.system)
    #expect(try ApplicationBundleIdentity(at: kept).version == "0.8.0")
    for number in 0..<occupiedNames {
        #expect(try ApplicationBundleIdentity(at: previous(number + 1)).version == "0.7.0")
    }
    #expect(fixture.exists(fixture.source))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test(arguments: [false, true])
func applicationMoveFailedRecoveryRenameProtectsHiddenBackupAcrossLaunches(refusedRollback: Bool) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    var mover = fixture.mover()
    let transaction = try await mover.install(mover.offer())
    mover.system.move = { _, _ in throw POSIXError(.EPERM) }
    mover.system.isRunning = { _ in refusedRollback }
    let error = await #expect(throws: CommandFailure.self) { try await transaction.rollback(using: mover.system) }
    #expect(error?.message.contains(transaction.replaced!.path) == true)
    #expect(error?.message.contains("⇧⌘. (Shift-Command-Period)") == true)
    #expect(fixture.exists(fixture.source))
    #expect(try ApplicationBundleIdentity(at: transaction.replaced!).version == "0.8.0")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    let path = transaction.replaced!.standardizedFileURL.resolvingSymlinksInPath().path
    #expect(UserDefaults(suiteName: fixture.recoveryStore.domain)?.stringArray(forKey: ApplicationMoveRecoveryStore.key) == [path])
    let normalLeftover = fixture.applications.appending(path: ".StableBar-previous-\(UUID().uuidString).app")
    try fixture.bundle(at: normalLeftover, version: "0.7.0")
    if !refusedRollback { try fixture.bundle(at: fixture.destination) }
    var launched = fixture.mover().system
    launched.source = fixture.destination
    launched.isRunning = { $0 == fixture.destination }
    await ApplicationMover.cleanUpPreviousCopies(using: launched)
    #expect(try ApplicationBundleIdentity(at: transaction.replaced!).version == "0.8.0")
    #expect(!fixture.exists(normalLeftover))
    #expect(fixture.exists(fixture.source))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).count == 1)
}

@Test @MainActor func applicationMoveControllerNamesTheBackupWhenApplicationsStartedMeanwhile() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    try fixture.bundle(at: fixture.destination, version: "0.8.0")
    var mover = fixture.mover()
    let running = OSAllocatedUnfairLock(initialState: false)
    mover.system.isRunning = { _ in running.withLock { $0 } }
    let controller = ApplicationMoveController(isInApplications: false, mover: mover, relaunch: { _, _ in
        running.withLock { $0 = true }
        throw CommandFailure(message: "Couldn’t start the relaunch helper.")
    }, quit: { Issue.record("Must not quit after a failed relaunch") })
    let resume = { ApplicationMoveResume(kind: .settings, configuration: fixture.directory.appending(path: "config.json")) }
    await controller.proceed(resume: resume)
    await controller.proceed(resume: resume)
    let copies = try FileManager.default.contentsOfDirectory(at: fixture.applications, includingPropertiesForKeys: nil)
    let previous = try #require(copies.first { $0.lastPathComponent == "StableBar (previous).app" })
    #expect(controller.error?.contains("Applications is now running") == true)
    #expect(controller.error?.contains(previous.standardizedFileURL.path) == true)
    #expect(controller.error?.contains("⇧⌘. (Shift-Command-Period)") == false)
    #expect(try ApplicationBundleIdentity(at: fixture.destination).version == "1.0.0")
    #expect(try ApplicationBundleIdentity(at: previous).version == "0.8.0")
    #expect(fixture.exists(fixture.source))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
}

@Test(arguments: [false, true])
func applicationMoveLaunchCleanupOnlyTrashesItsOwnInactiveSiblingBackups(fallback: Bool) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    let directory = fallback ? fixture.fallback : fixture.applications
    let source = directory.appending(path: "StableBar.app")
    try fixture.bundle(at: source)
    func backup() -> URL { directory.appending(path: ".StableBar-previous-\(UUID().uuidString).app") }
    let old = backup(), older = backup(), running = backup(), foreign = backup(), file = backup(), link = backup()
    let badName = directory.appending(path: ".StableBar-previous-not-a-uuid.app")
    let nested = directory.appending(path: "Other/.StableBar-previous-\(UUID().uuidString).app")
    for copy in [old, older, running, badName, nested] { try fixture.bundle(at: copy, version: "0.8.0") }
    try fixture.bundle(at: foreign, id: "org.someone.else")
    try Data("unrelated file".utf8).write(to: file)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.source)
    var system = fixture.mover().system
    system.source = source
    system.isRunning = {
        let path = $0.standardizedFileURL.path
        return path == source.standardizedFileURL.path || path == running.standardizedFileURL.path
    }
    await ApplicationMover.cleanUpPreviousCopies(using: system)
    #expect(!fixture.exists(old))
    #expect(!fixture.exists(older))
    for copy in [source, running, foreign, badName, nested, file, link, fixture.source] { #expect(fixture.exists(copy)) }
    #expect(try ApplicationBundleIdentity(at: source).version == "1.0.0")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).count == 2)
}

@Test func applicationMoveLaunchCleanupLeavesFailuresAndOtherFoldersAlone() async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    let untouched = fixture.source.deletingLastPathComponent().appending(path: ".StableBar-previous-\(UUID().uuidString).app")
    let failed = fixture.applications.appending(path: ".StableBar-previous-\(UUID().uuidString).app")
    let cleaned = fixture.applications.appending(path: ".StableBar-previous-\(UUID().uuidString).app")
    for copy in [fixture.destination, untouched, failed, cleaned] { try fixture.bundle(at: copy) }
    var system = fixture.mover().system
    system.isRunning = { $0 == fixture.destination }
    let trash = system.trash
    system.trash = { copy in
        #expect(copy != untouched)
        if copy.standardizedFileURL.path == failed.standardizedFileURL.path { throw POSIXError(.EPERM) }
        return try trash(copy)
    }
    await ApplicationMover.cleanUpPreviousCopies(using: system)
    #expect(fixture.exists(untouched))
    #expect(fixture.exists(failed))
    #expect(fixture.exists(cleaned))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).isEmpty)
    system.source = fixture.destination
    await ApplicationMover.cleanUpPreviousCopies(using: system)
    #expect(fixture.exists(untouched))
    #expect(fixture.exists(failed))
    #expect(!fixture.exists(cleaned))
    #expect(fixture.exists(fixture.destination))
    #expect(fixture.exists(fixture.source))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path).count == 1)
}

@Test(arguments: [false, true])
func applicationMoveNamesTheDamagedApplicationsCopy(plainFile: Bool) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    if plainFile { try Data().write(to: fixture.destination) }
    else { try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true) }
    let error = await #expect(throws: CommandFailure.self) { try await fixture.mover().offer() }
    #expect(error?.message.contains(fixture.destination.path) == true)
    #expect(error?.message.contains("This copy") == false)
}

@Test(arguments: [ENOSPC, EACCES, EPERM, EIO])
func applicationMoveFilesystemErrorsHideStagingAndExplainRecovery(code: Int32) async throws {
    let fixture = try MoveFixture()
    defer { fixture.close() }
    var mover = fixture.mover()
    mover.system.copy = { _, candidate in
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                      userInfo: [NSFilePathErrorKey: candidate.path,
                                 NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
    }
    let error = await #expect(throws: CommandFailure.self) { try await mover.install(mover.offer()) }
    let message = try #require(error?.message)
    #expect(!message.contains(fixture.staging.path))
    #expect(!message.contains(".StableBar-move-"))
    #expect(code == ENOSPC ? message.contains("Free some space") : message.contains("Finder"))
    #expect(try fixture.noPartialCopy())
}

@Test @MainActor func applicationMoveSettingsUsesSetupWhileSetupIsOpen() async throws {
    let fixture = try MoveFixture()
    let configuration = try ThemeGalleryFixture(#"{"widgets":[]}"#)
    let store = BarStore(configurationURL: configuration.url, themesDirectory: configuration.themes)
    store.reloadConfiguration()
    defer { store.stop(); configuration.close(); fixture.close() }
    let edit = ConfigurationEdit(action: .bar, properties: ["height": .number(38)])
    try store.setSessionEdits([edit])
    store.barEditing.setupIsOpen = true
    let move = ApplicationMoveController(isInApplications: false, mover: fixture.mover(), relaunch: { _, _ in
        Issue.record("Settings must leave setup in charge of the resume record")
    }, quit: { Issue.record("Settings must not quit during setup") })
    #expect(!move.canMoveFromSettings(setupIsOpen: store.barEditing.setupIsOpen))
    #expect(move.resumeFromSettings(store: store) == nil)
    await move.proceed { move.resumeFromSettings(store: store) }
    #expect(move.offer == nil)
    #expect(move.error == nil)
    #expect(!fixture.exists(fixture.destination))
    #expect(fixture.exists(fixture.source))
    #expect(store.sessionEdits.first?.properties == edit.properties)
    #expect(ApplicationMoveController.setupHint.contains("Finishing touches"))
    store.barEditing.setupIsOpen = false
    let resume = try #require(move.resumeFromSettings(store: store))
    #expect(resume.kind == .settings)
    #expect(resume.edits.first?.restored.properties == edit.properties)
    move.isInApplications = true
    #expect(move.resumeFromSettings(store: store) == nil)
}

@Test @MainActor func applicationMoveExplainsWhyTheExistingCopyIsOffered() {
    let move = ApplicationMoveController.sample(.useExisting)
    #expect(move.confirmation == "StableBar 0.8.0 is already in Applications.")
    #expect(move.action == "Use the One in Applications")
}
