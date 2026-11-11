import Foundation

/// The `stablebar` command that Settings installs: a script that runs this app's executable.
enum CommandLineTool {
    static let name = "stablebar"
    static let directory = URL(filePath: "/usr/local/bin", directoryHint: .isDirectory)
    private static let marker = "# Installed by StableBar from Settings › General › Command line."
    private static let execPrefix = "exec '", execSuffix = "' \"$@\""

    enum Status: Equatable {
        case missing
        case installed(URL)
        case otherCopy(URL, executable: URL)
        case foreign(URL)
    }

    static func script(running executable: URL) -> String {
        "#!/bin/sh\n\(marker)\nexec \(quoted(executable.path)) \"$@\"\n"
    }

    static func executable(inScript text: String) -> URL? {
        let lines = text.split(separator: "\n")
        guard lines.contains(where: { $0 == marker }),
              let line = lines.first(where: { $0.hasPrefix(execPrefix) && $0.hasSuffix(execSuffix) }) else { return nil }
        let word = line.dropFirst(execPrefix.count).dropLast(execSuffix.count)
        return URL(filePath: word.replacingOccurrences(of: "'\\''", with: "'"))
    }

    /// The first `stablebar` a shell with this `PATH` runs, then the install directory, and what it opens.
    static func status(for executable: URL, path: String?, directory: URL = directory) -> Status {
        let directories = (path ?? "").split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) } + [directory]
        guard let command = directories.lazy.map({ $0.appending(path: name) }).first(where: isCommand) else { return .missing }
        let app = executable.resolvingSymlinksInPath()
        if command.resolvingSymlinksInPath() == app { return .installed(command) }
        guard let target = scriptTarget(of: command) else { return .foreign(command) }
        return target.resolvingSymlinksInPath() == app ? .installed(command) : .otherCopy(command, executable: target)
    }

    /// The `stablebar` scripts StableBar wrote on this `PATH` and in the install directory, whichever copy they open.
    static func installedScripts(path: String?, directory: URL = directory) -> [URL] {
        let directories = (path ?? "").split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) } + [directory]
        var seen = Set<String>()
        return directories.map { $0.appending(path: name) }.filter { command in
            let values = try? command.resourceValues(forKeys: [.isSymbolicLinkKey])
            return seen.insert(command.resolvingSymlinksInPath().path).inserted && values?.isSymbolicLink == false
                && isCommand(command) && scriptTarget(of: command) != nil
        }
    }

    /// Deletes a script StableBar wrote, asking for an administrator password when the folder isn't writable.
    /// Throws `CancellationError` when the password prompt is cancelled.
    static func remove(_ command: URL) async throws {
        guard (try? command.checkResourceIsReachable()) == true else { return }
        guard scriptTarget(of: command) != nil else { throw CommandLineToolError.notOurs(command.path) }
        do {
            try FileManager.default.removeItem(at: command)
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            try await runWithPrivileges(removeCommand(command),
                                        prompt: "StableBar wants to remove the \(name) command from \(command.deletingLastPathComponent().path).")
        }
    }

    static func removeCommand(_ command: URL) -> String {
        "/bin/rm -f \(quoted(command.path))"
    }

    private static func scriptTarget(of command: URL) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: command) else { return nil }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4096)).flatMap { executable(inScript: String(decoding: $0, as: UTF8.self)) }
    }

    /// Writes the script, asking for an administrator password when the folder isn't writable.
    /// Throws `CancellationError` when the password prompt is cancelled.
    static func install(_ executable: URL, at command: URL) async throws {
        if (try? FileManager.default.attributesOfItem(atPath: command.path)) != nil {
            switch status(for: executable, path: nil, directory: command.deletingLastPathComponent()) {
            case .installed, .otherCopy: break
            case .missing, .foreign: throw CommandLineToolError.notOurs(command.path)
            }
        }
        let data = Data(script(running: executable).utf8)
        do {
            try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: command, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            try await installWithPrivileges(data, at: command)
        }
    }

    static func installCommand(from source: URL, to command: URL) -> String {
        "/bin/mkdir -p \(quoted(command.deletingLastPathComponent().path)) && /usr/bin/install -m 755 \(quoted(source.path)) \(quoted(command.path))"
    }

    private static func installWithPrivileges(_ data: Data, at command: URL) async throws {
        let source = FileManager.default.temporaryDirectory.appending(path: "\(name)-\(UUID().uuidString)")
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        try await runWithPrivileges(installCommand(from: source, to: command),
                                    prompt: "StableBar wants to install the \(name) command in \(command.deletingLastPathComponent().path).")
    }

    private static func runWithPrivileges(_ script: String, prompt: String) async throws {
        do {
            _ = try await runCommand("/usr/bin/osascript", arguments: [
                "-e", "on run argv",
                "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
                "-e", "end run",
                script, prompt
            ], timeout: 600)
        } catch let failure as CommandFailure where String(decoding: failure.stderr, as: UTF8.self).contains("(-128)") {
            throw CancellationError()
        }
    }

    private static func isCommand(_ url: URL) -> Bool {
        let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true && FileManager.default.isExecutableFile(atPath: url.path)
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum CommandLineToolError: LocalizedError {
    case notOurs(String)

    var errorDescription: String? {
        switch self {
        case let .notOurs(path): "\(path) wasn't installed by StableBar, so it was left as it is."
        }
    }
}
