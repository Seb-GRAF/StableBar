import AppKit
import Darwin
import Foundation
import Security

/// The filesystem and Mac around a move. Tests supply temporary folders and a recoverable stand-in for the Trash.
struct ApplicationMoveSystem: Sendable {
    var source = Bundle.main.bundleURL
    var applications = URL(filePath: "/Applications", directoryHint: .isDirectory)
    var userApplications = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
    var recoveryStore = ApplicationMoveRecoveryStore()
    var isWritable: @Sendable (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) }
    var isReadOnly: @Sendable (URL) throws -> Bool = {
        guard let readOnly = try $0.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly else {
            throw CommandFailure(message: "Couldn’t check whether the app’s disk is writable. Try again or use Finder.")
        }
        return readOnly
    }
    var isRunning: @Sendable (URL) async -> Bool = { url in
        // NSWorkspace's list needs a main run loop; the detached helper only runs dispatchMain().
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "org.stablebar.app").contains {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path
                == url.standardizedFileURL.resolvingSymlinksInPath().path
        }
    }
    var copy: @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    var move: @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    var trash: @Sendable (URL) throws -> URL = {
        var result: NSURL?
        try FileManager.default.trashItem(at: $0, resultingItemURL: &result)
        guard let result else { throw CommandFailure(message: "Couldn’t find the recoverable copy in the Trash.") }
        return result as URL
    }
    var removeQuarantine: @Sendable (URL) throws -> Void = ApplicationMover.removeQuarantine
    var validateCopySignature: @Sendable (URL) throws -> Void = ApplicationMover.validateCopySignature
    var validateExistingSignature: @Sendable (URL) throws -> Void = ApplicationMover.validateExistingSignature
    var stagingDirectory: @Sendable (URL) throws -> URL = {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: $0, create: true)
    }
}

/// No Bundle cache: a failed attempt may have put a different app at the same path.
struct ApplicationBundleIdentity: Codable, Equatable, Sendable {
    let identifier: String
    let version: String
    let build: String
    let executable: String

    init(identifier: String, version: String, build: String, executable: String) {
        self.identifier = identifier
        self.version = version
        self.build = build
        self.executable = executable
    }

    init(at url: URL) throws {
        let data = try Data(contentsOf: url.appending(path: "Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard let identifier = plist?["CFBundleIdentifier"] as? String,
              let version = plist?["CFBundleShortVersionString"] as? String,
              let build = plist?["CFBundleVersion"] as? String,
              let executable = plist?["CFBundleExecutable"] as? String,
              !identifier.isEmpty, !version.isEmpty, !build.isEmpty, !executable.isEmpty,
              executable == URL(filePath: executable).lastPathComponent,
              FileManager.default.isExecutableFile(atPath: url.appending(path: "Contents/MacOS/\(executable)").path) else {
            throw CommandFailure(message: "This copy of StableBar is incomplete. Download it again or use Finder.")
        }
        self.identifier = identifier
        self.version = version
        self.build = build
        self.executable = executable
    }

    func compared(to other: Self) -> ComparisonResult {
        let release = compareReleases(version, other.version)
        return release == .orderedSame ? build.compare(other.build, options: .numeric) : release
    }
}

struct ApplicationMoveOffer: Sendable {
    enum Action: Sendable { case install, replace, useExisting }
    let source: URL
    let destination: URL
    let current: ApplicationBundleIdentity
    let existing: ApplicationBundleIdentity?
    let action: Action
}

/// Unlike a bundle identifier and version, this identifies one bundle directory on disk.
struct ApplicationMoveFileIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64

    init(at url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw CommandFailure(message: "Couldn’t identify the copy at \(url.path). Use Finder to check it.")
        }
        device = info.st_dev
        inode = info.st_ino
    }
}

/// Failed recovery must survive another launch, including when a hidden backup cannot be renamed.
struct ApplicationMoveRecoveryStore: Sendable {
    var domain = Bundle.main.bundleIdentifier ?? "org.stablebar.app"
    static let key = "applicationMoveKeptPreviousCopies"

    func pathsToKeep() -> Set<String>? {
        guard CFPreferencesAppSynchronize(domain as CFString) else { return nil }
        guard let value = CFPreferencesCopyAppValue(Self.key as CFString, domain as CFString) else { return [] }
        guard let paths = value as? [String] else { return nil }
        return Set(paths)
    }

    func keep(_ copy: URL) {
        CFPreferencesAppSynchronize(domain as CFString)
        var paths = Set(CFPreferencesCopyAppValue(Self.key as CFString, domain as CFString) as? [String] ?? [])
        paths.insert(copy.standardizedFileURL.resolvingSymlinksInPath().path)
        CFPreferencesSetAppValue(Self.key as CFString, paths.sorted() as CFArray, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }
}

/// Describes exactly what this attempt changed, so a launch failure can put both copies back.
struct ApplicationMoveTransaction: Codable, Sendable {
    let source: URL
    let destination: URL
    var sourceIdentity: ApplicationMoveFileIdentity?
    var installed = false
    var installedIdentity: ApplicationMoveFileIdentity?
    var trashSourceAfterLaunch = false
    /// A hidden sibling in Applications, so recovery never needs access to the Trash.
    var replaced: URL?

    static let hiddenCopyHint = "Press ⇧⌘. (Shift-Command-Period) in Finder to show hidden copies."

    func originalNote(using system: ApplicationMoveSystem) -> String {
        if source.pathComponents.contains("AppTranslocation") || (try? system.isReadOnly(source)) != false {
            return "Your original copy is unchanged."
        }
        return "Your original copy is unchanged at \(source.path)."
    }

    private func keepPreviousCopy(using system: ApplicationMoveSystem) -> URL? {
        let files = FileManager.default
        guard let replaced, files.fileExists(atPath: replaced.path) else { return nil }
        let directory = replaced.deletingLastPathComponent()
        var number = 1
        while true {
            let name = number == 1 ? "StableBar (previous).app" : "StableBar (previous \(number)).app"
            let visible = directory.appending(path: name, directoryHint: .isDirectory)
            if (try? files.attributesOfItem(atPath: visible.path)) != nil { number += 1; continue }
            do {
                try system.move(replaced, visible)
                return visible
            } catch {
                // Another recovery can claim the same name between the check and the rename.
                if (try? files.attributesOfItem(atPath: visible.path)) != nil { number += 1; continue }
                system.recoveryStore.keep(replaced)
                return replaced
            }
        }
    }

    func previousCopyNote(using system: ApplicationMoveSystem) -> String {
        guard let copy = keepPreviousCopy(using: system) else { return "" }
        let hint = copy.lastPathComponent.hasPrefix(".") ? " \(Self.hiddenCopyHint)" : ""
        return " The previous Applications copy is at \(copy.path).\(hint)"
    }

    private func recoveryNote(using system: ApplicationMoveSystem) -> String {
        "Your original copy is at \(source.path). Check the Applications copy at \(destination.path).\(previousCopyNote(using: system)) Quit any running copy, then use Finder to choose which copy to keep."
    }

    func rollback(using system: ApplicationMoveSystem) async throws {
        let files = FileManager.default
        // The destination may have been opened or replaced while the helper waited for the parent to exit.
        if installed {
            guard !(await system.isRunning(destination)), let installedIdentity,
                  (try? ApplicationMoveFileIdentity(at: destination)) == installedIdentity else {
                throw CommandFailure(message: "The Applications copy changed or may be running, so all copies were kept. \(recoveryNote(using: system))")
            }
        }
        do {
            if installed {
                try files.removeItem(at: destination)
            }
            if let replaced { try system.move(replaced, destination) }
        } catch {
            throw CommandFailure(message: "Couldn’t put the previous copies back. \(recoveryNote(using: system))")
        }
    }

    /// Opening Applications has already succeeded. Cleanup must never turn that into a failed move.
    func finish(using system: ApplicationMoveSystem) -> String? {
        var remaining: [URL] = []
        if let replaced, FileManager.default.fileExists(atPath: replaced.path),
           (try? system.trash(replaced)) == nil, let kept = keepPreviousCopy(using: system) {
            remaining.append(kept)
        }
        var sourceNote: String?
        if trashSourceAfterLaunch {
            if let sourceIdentity, (try? ApplicationMoveFileIdentity(at: source)) == sourceIdentity {
                if (try? system.trash(source)) == nil { remaining.append(source) }
            } else {
                sourceNote = "The original location at \(source.path) changed or couldn’t be checked, so it was left untouched."
            }
        }
        guard !remaining.isEmpty || sourceNote != nil else { return nil }
        let hidden = remaining.contains { $0.lastPathComponent.hasPrefix(".") } ? " \(Self.hiddenCopyHint)" : ""
        let cleanup = remaining.isEmpty ? nil : "Remove the old \(remaining.count == 1 ? "copy" : "copies") at \(remaining.map(\.path).formatted()) with Finder.\(hidden)"
        return ["StableBar now opens from \(destination.path).", cleanup, sourceNote].compactMap { $0 }.joined(separator: " ")
    }
}

/// Called off the main actor, only after someone chooses Move to Applications. No steady-state work.
struct ApplicationMover: Sendable {
    var system = ApplicationMoveSystem()

    func offer() async throws -> ApplicationMoveOffer {
        do { return try await inspect() }
        catch { throw CommandFailure(message: Self.failureMessage(error)) }
    }

    private func existingIdentity(at destination: URL) throws -> ApplicationBundleIdentity? {
        guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
        do { return try ApplicationBundleIdentity(at: destination) }
        catch {
            throw CommandFailure(message: "The copy of StableBar at \(destination.path) is incomplete. Move it aside with Finder, then try again.")
        }
    }

    private func inspect() async throws -> ApplicationMoveOffer {
        let files = FileManager.default
        let current = try ApplicationBundleIdentity(at: system.source)
        let directory: URL
        if system.isWritable(system.applications) {
            directory = system.applications
        } else {
            directory = system.userApplications
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            guard system.isWritable(directory) else {
                throw CommandFailure(message: "Neither Applications folder is writable. Move StableBar with Finder.")
            }
        }
        let destination = directory.appending(path: "StableBar.app", directoryHint: .isDirectory)
        guard system.source.resolvingSymlinksInPath().path != destination.resolvingSymlinksInPath().path else {
            throw CommandFailure(message: "StableBar is already in Applications. Open that copy again.")
        }
        if await system.isRunning(destination) {
            throw CommandFailure(message: "StableBar in Applications is running. Quit that copy, then try again.")
        }
        let existing = try existingIdentity(at: destination)
        if let existing, existing.identifier != current.identifier {
            throw CommandFailure(message: "Applications has a different app named StableBar. Move it aside with Finder first.")
        }
        let action: ApplicationMoveOffer.Action = existing.map {
            $0.compared(to: current) == .orderedAscending ? .replace : .useExisting
        } ?? .install
        return ApplicationMoveOffer(source: system.source, destination: destination, current: current, existing: existing, action: action)
    }

    func install(_ offer: ApplicationMoveOffer) async throws -> ApplicationMoveTransaction {
        do { return try await transfer(offer) }
        catch { throw CommandFailure(message: Self.failureMessage(error)) }
    }

    private func transfer(_ offer: ApplicationMoveOffer) async throws -> ApplicationMoveTransaction {
        // Recheck after confirmation: another copy may have been installed or opened meanwhile.
        let fresh = try await self.offer()
        guard fresh.destination.path == offer.destination.path, fresh.current == offer.current, fresh.existing == offer.existing else {
            throw CommandFailure(message: "The copy in Applications changed. Try again to review it.")
        }
        var transaction = ApplicationMoveTransaction(source: offer.source, destination: offer.destination,
            sourceIdentity: try ApplicationMoveFileIdentity(at: offer.source))
        if offer.action == .useExisting {
            try verifyIdentity(offer.destination, identity: offer.existing!)
            try system.validateExistingSignature(offer.destination)
            return transaction
        }
        let files = FileManager.default
        let staging = try system.stagingDirectory(offer.destination)
        defer { try? files.removeItem(at: staging) }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        let candidate = staging.appending(path: "StableBar.app")
        let copyOnly = try offer.source.pathComponents.contains("AppTranslocation") || system.isReadOnly(offer.source)
        // Copy before touching either original. A full disk or bad signature leaves both as they were.
        try await BlockingWork.run {
            try system.copy(offer.source, candidate)
            try verifyIdentity(candidate, identity: offer.current)
            try system.validateCopySignature(candidate)
            try system.removeQuarantine(candidate)
        }
        let existing = try existingIdentity(at: offer.destination)
        guard existing == offer.existing else {
            throw CommandFailure(message: "The copy in Applications changed. Try again to review it.")
        }
        guard !(await system.isRunning(offer.destination)) else {
            throw CommandFailure(message: "StableBar in Applications is running. Quit that copy, then try again.")
        }
        do {
            // The replacement directory is on the destination's volume; renaming preserves this identity.
            transaction.installedIdentity = try ApplicationMoveFileIdentity(at: candidate)
            if offer.existing != nil {
                let backup = offer.destination.deletingLastPathComponent()
                    .appending(path: ".StableBar-previous-\(UUID().uuidString).app", directoryHint: .isDirectory)
                try system.move(offer.destination, backup)
                transaction.replaced = backup
            }
            // Always install the verified copy. Bundle.main can keep reading the running bundle until it quits.
            try system.move(candidate, offer.destination)
            transaction.installed = true
            transaction.trashSourceAfterLaunch = !copyOnly
            return transaction
        } catch {
            try await transaction.rollback(using: system)
            throw error
        }
    }

    private func verifyIdentity(_ url: URL, identity: ApplicationBundleIdentity) throws {
        guard (try? ApplicationBundleIdentity(at: url)) == identity else {
            throw CommandFailure(message: "The copy of StableBar for Applications is incomplete. Try again or use Finder.")
        }
    }

    private static func runningCode() throws -> SecStaticCode {
        var running: SecCode?
        var code: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code else {
            throw CommandFailure(message: "Couldn’t verify the running StableBar. Download it again or use Finder.")
        }
        return code
    }

    static func validateCopySignature(_ url: URL) throws {
        var requirement: SecRequirement?
        guard try SecCodeCopyDesignatedRequirement(runningCode(), [], &requirement) == errSecSuccess, let requirement else {
            throw CommandFailure(message: "Couldn’t verify the running StableBar. Download it again or use Finder.")
        }
        _ = try validateSignature(url, requirement: requirement)
    }

    static func validateExistingSignature(_ url: URL) throws {
        let code: SecStaticCode
        do { code = try validateSignature(url) }
        catch {
            throw CommandFailure(message: "The copy of StableBar at \(url.path) couldn’t be verified. Move it aside with Finder, then try again.")
        }
        try validateTeamIdentifier(teamIdentifier(of: code), matches: teamIdentifier(of: runningCode()))
    }

    /// Once per launch from Applications, off the main thread. Only our generated sibling backups qualify.
    static func cleanUpPreviousCopies(using system: ApplicationMoveSystem) async {
        let directory = system.source.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard [system.applications, system.userApplications].contains(where: {
            $0.standardizedFileURL.resolvingSymlinksInPath() == directory
        }), await system.isRunning(system.source),
            let identity = try? ApplicationBundleIdentity(at: system.source),
            let keptPaths = system.recoveryStore.pathsToKeep(),
            let contents = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for copy in contents {
            let name = copy.lastPathComponent
            guard name.hasPrefix(".StableBar-previous-"), name.hasSuffix(".app"),
                  !keptPaths.contains(copy.standardizedFileURL.resolvingSymlinksInPath().path),
                  UUID(uuidString: String(name.dropFirst(".StableBar-previous-".count).dropLast(".app".count))) != nil,
                  let values = try? copy.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink == false,
                  (try? ApplicationBundleIdentity(at: copy))?.identifier == identity.identifier,
                  !(await system.isRunning(copy)) else { continue }
            _ = try? system.trash(copy)
        }
    }

    static func validateTeamIdentifier(_ candidate: String?, matches running: String?) throws {
        guard running == nil || candidate == running else {
            throw CommandFailure(message: "The copy of StableBar in Applications is signed by another developer. Move it aside with Finder, then try again.")
        }
    }

    static func teamIdentifier(of code: SecStaticCode) throws -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any] else {
            throw CommandFailure(message: "Couldn’t read StableBar’s signing information. Try again or use Finder.")
        }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }

    @discardableResult
    static func validateSignature(_ url: URL, requirement: SecRequirement? = nil) throws -> SecStaticCode {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard created == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), requirement)
                == errSecSuccess else {
            throw CommandFailure(message: "The copy of StableBar for Applications couldn’t be verified. Download StableBar again or use Finder.")
        }
        return code
    }

    /// Filesystem errors may contain private staging paths. Show only a useful, plain reason.
    static func failureMessage(_ error: any Error) -> String {
        if let failure = error as? CommandFailure { return failure.message }
        let error = error as NSError
        if (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
            || (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError) {
            return "Applications is full. Free some space, then try again."
        }
        if (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code))
            || (error.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code)) {
            return "StableBar doesn’t have permission to copy into Applications. Use Finder to move it."
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error { return failureMessage(underlying) }
        return "Couldn’t copy StableBar to Applications. Try again or use Finder."
    }

    static func removeQuarantine(_ url: URL) throws {
        func clear(_ file: URL) throws {
            if removexattr(file.path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0 && errno != ENOATTR && errno != ENOTSUP {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        try clear(url)
        var failure: (any Error)?
        let contents = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, errorHandler: { _, error in
            failure = error
            return false
        })
        guard let contents else { throw CommandFailure(message: "Couldn’t read the copied app. Try again or use Finder.") }
        for case let file as URL in contents { try clear(file) }
        if let failure { throw failure }
    }
}
