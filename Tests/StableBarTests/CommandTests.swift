import Darwin
import Foundation
import Testing
@testable import StableBar

@Test func commandResultRetainsSeparateDiagnostics() async throws {
    let result = try await runCommandResult("/bin/zsh", arguments: ["-c", "printf output; printf warning >&2"])
    #expect(String(decoding: result.stdout, as: UTF8.self) == "output")
    #expect(String(decoding: result.stderr, as: UTF8.self) == "warning")
    #expect(result.cpuTime >= 0)
}

@Test func commandWarningsDoNotCorruptJSONOutput() async throws {
    let data = try await runCommand("/bin/zsh", arguments: ["-c", "head -c 131072 /dev/zero >&2; printf '{\"text\":\"Ready\"}'"])
    #expect(try ScriptOutput.read(data).text == "Ready")
}

@Test(arguments: [("exit 7", "Command exited with status 7."), ("kill -TERM $$", "Command terminated by signal 15.")])
func commandFailureWithoutDiagnosticsIncludesExitCode(command: String, message: String) async {
    do {
        _ = try await runCommand("/bin/zsh", arguments: ["-c", command])
        Issue.record("The failed command was accepted.")
    } catch {
        #expect(error.localizedDescription == message)
    }
}

@Test func commandEnvironmentOverridesAreAvailableToScripts() async throws {
    let data = try await runCommand("/bin/zsh", arguments: ["-c", "printf '%s:%s' \"$NAME\" \"$SENDER\""],
                                    environment: ["NAME": "weather", "SENDER": "wake"])
    #expect(String(decoding: data, as: UTF8.self) == "weather:wake")
}

@Test(arguments: [false, true])
func commandOutputHasABoundedSize(stderr: Bool) async {
    do {
        _ = try await runCommand("/bin/zsh", arguments: ["-c", "head -c 1048577 /dev/zero" + (stderr ? " >&2" : "")])
        Issue.record("The oversized output was accepted.")
    } catch {
        #expect(error.localizedDescription == "Command output exceeded 1 MiB.")
    }
}

// The child sleeps for an hour, so a stop that waited for it would run into the time limit.
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func cancellingOrTimingOutStopsShellChildren(timeout: Bool) async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    // The timeout must leave a busy runner time to start the shell and write the marker. When the test cancels, the
    // timeout is long, so the cancel comes first however long the main actor takes to notice the marker.
    let task = Task {
        try await runCommand("/bin/zsh", arguments: ["-c", "trap '' TERM; sleep 3600 & printf '%s' $! > '\(marker.path).tmp'; mv '\(marker.path).tmp' '\(marker.path)'; wait"],
                             timeout: timeout ? 5 : 60)
    }
    defer { task.cancel() }
    for _ in 0..<2000 {
        if FileManager.default.fileExists(atPath: marker.path) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let child = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
    defer { kill(child, SIGKILL) }
    if !timeout { task.cancel() }
    do {
        _ = try await task.value
        Issue.record("The stopped command was accepted.")
    } catch {
        if timeout {
            #expect(error.localizedDescription == "Command timed out after 5.0 seconds.")
        } else {
            #expect(error is CancellationError)
        }
    }
    for _ in 0..<2000 {
        if kill(child, 0) == -1 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(kill(child, 0) == -1)
    #expect(errno == ESRCH)
}

@Test func alreadyCancelledCommandDoesNotLaunchItsExecutable() async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    let task = Task {
        withUnsafeCurrentTask { $0!.cancel() }
        return try await runCommand("/bin/zsh", arguments: ["-c", "touch '\(marker.path)'"])
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test(.timeLimit(.minutes(1))) func cancellingCommandsAsTheyExitCompletes() async throws {
    for _ in 0..<100 {
        let task = Task { try await runCommand("/usr/bin/true", arguments: []) }
        try await Task.sleep(for: .milliseconds(1))
        task.cancel()
        do {
            #expect(try await task.value.isEmpty)
        } catch {
            #expect(error is CancellationError)
        }
    }
}

@Test(.timeLimit(.minutes(1))) func commandTimeoutClosesPipesHeldByChildrenAfterTheShellExits() async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    // The timeout must leave a busy runner time to start the shell and write the marker.
    do {
        _ = try await runCommand("/bin/sh", arguments: ["-c", "sleep 300 & printf '%s' $! > '\(marker.path)'"], timeout: 2)
        Issue.record("The command completed while a child still held its pipes.")
    } catch {
        #expect(error.localizedDescription == "Command timed out after 2.0 seconds.")
    }
    let child = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
    for _ in 0..<2000 {
        if kill(child, 0) == -1 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(kill(child, 0) == -1)
    #expect(errno == ESRCH)
}

// The child sleeps for an hour, so a stop that waited for it would run into the time limit.
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func stoppedCommandDoesNotWaitForPipesHeldByAnEscapedChild(timeout: Bool) async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    // The child leaves the command's process group, so stopping the command doesn't end it. However the test ends,
    // early too, this ends it, waiting a little for a marker that comes late.
    defer {
        for _ in 0..<200 {
            if let child = (try? String(contentsOf: marker, encoding: .utf8)).flatMap({ Int32($0) }) {
                kill(child, SIGKILL)
                break
            }
            usleep(10_000)
        }
    }
    // The timeout must leave a busy runner time to start perl and write the marker. When the test cancels, the
    // timeout is long, so the cancel comes first however long the main actor takes to notice the marker.
    let task = Task {
        try await runCommand("/usr/bin/perl", arguments: ["-MPOSIX", "-e", """
            if (fork() == 0) {
                POSIX::setsid();
                open(my $marker, '>', $ARGV[0] . '.tmp');
                print $marker $$;
                close($marker);
                rename($ARGV[0] . '.tmp', $ARGV[0]);
                exec('/bin/sleep', '3600');
            }
            """, marker.path], timeout: timeout ? 5 : 60)
    }
    defer { task.cancel() }
    for _ in 0..<2000 {
        if FileManager.default.fileExists(atPath: marker.path) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let child = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
    #expect(getpgid(child) == child)
    if !timeout { task.cancel() }
    do {
        _ = try await task.value
        Issue.record("The stopped command was accepted.")
    } catch {
        if timeout {
            #expect(error.localizedDescription == "Command timed out after 5.0 seconds.")
        } else {
            #expect(error is CancellationError)
        }
    }
}

// The child sleeps for an hour, so a stop that waited for it would run into the time limit.
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func stoppedCommandCannotEscapeByChangingItsProcessGroup(timeout: Bool) async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    // The timeout must leave a busy runner time to start perl and write the marker. When the test cancels, the
    // timeout is long, so the cancel comes first however long the main actor takes to notice the marker.
    let task = Task {
        try await runCommand("/usr/bin/perl", arguments: ["-MPOSIX", "-e", """
            POSIX::setpgid(0, getpgrp(getppid()));
            open(my $marker, '>', $ARGV[0] . '.tmp');
            print $marker "$$ ", getpgrp(0);
            close($marker);
            rename($ARGV[0] . '.tmp', $ARGV[0]);
            exec('/bin/sleep', '3600');
            """, marker.path], timeout: timeout ? 5 : 60)
    }
    defer { task.cancel() }
    for _ in 0..<2000 {
        if FileManager.default.fileExists(atPath: marker.path) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let identity = try String(contentsOf: marker, encoding: .utf8).split(separator: " ").compactMap { Int32($0) }
    try #require(identity.count == 2)
    let process = identity[0]
    defer { kill(process, SIGKILL) }
    // The timeout can reap the process before this task resumes, so read the group it recorded while alive.
    #expect(identity[1] == getpgrp())
    if !timeout { task.cancel() }
    do {
        _ = try await task.value
        Issue.record("The stopped command was accepted.")
    } catch {
        if timeout {
            #expect(error.localizedDescription == "Command timed out after 5.0 seconds.")
        } else {
            #expect(error is CancellationError)
        }
    }
    #expect(kill(process, 0) == -1)
    #expect(errno == ESRCH)
}

@Test func installPackageTakesAnOptionalSource() throws {
    guard case let .installFromStore(_, id, source) = try LaunchCommand(arguments: ["--install-package", "clock", "--source", "acme"]) else {
        Issue.record("Expected a Store install.")
        return
    }
    #expect(id == "clock")
    #expect(source == "acme")
    guard case let .installFromStore(_, plainID, plainSource) = try LaunchCommand(arguments: ["--install-package", "clock"]) else {
        Issue.record("Expected a Store install.")
        return
    }
    #expect(plainID == "clock")
    #expect(plainSource == nil)
    #expect(throws: CommandFailure.self) { try LaunchCommand(arguments: ["--install-package", "clock", "--source"]) }
}

@Test func buildSourceTakesPathsAndFlagsInAnyOrder() throws {
    guard case let .buildSource(packages, output, previous, url, name) = try LaunchCommand(arguments: [
        "--build-source", "./packages", "./dist", "--name", "Acme", "--previous", "./previous/index.json",
        "--url", "https://example.com/store/index.json",
    ]) else {
        Issue.record("Expected a source build.")
        return
    }
    #expect(packages.lastPathComponent == "packages")
    #expect(output.lastPathComponent == "dist")
    #expect(previous?.path.hasSuffix("previous/index.json") == true)
    #expect(url == URL(string: "https://example.com/store/index.json"))
    #expect(name == "Acme")
    guard case let .buildSource(_, _, plainPrevious, plainURL, plainName) = try LaunchCommand(arguments: ["--build-source", "p", "o"]) else {
        Issue.record("Expected a source build.")
        return
    }
    #expect(plainPrevious == nil && plainURL == nil && plainName == nil)
}

@Test func buildSourceRefusesBadFlagsAndURLsAndAURLOrNameAlone() {
    for arguments in [
        ["--build-source", "p"],
        ["--build-source", "p", "o", "--url", "https://example.com/index.json"],
        ["--build-source", "p", "o", "--name", "Acme"],
        ["--build-source", "p", "o", "--previous"],
        ["--build-source", "p", "o", "--other", "x"],
        ["--build-source", "p", "o", "--previous", "a", "--previous", "b"],
        ["--build-source", "p", "o", "--url", "http://example.com/index.json", "--name", "Acme"],
        ["--build-source", "p", "o", "--url", "https://user:secret@example.com/index.json", "--name", "Acme"],
        ["--build-source", "p", "o", "--url", "https://example.com/index.json?token=x", "--name", "Acme"],
        ["--build-source", "p", "o", "--url", "https://example.com/index.json", "--name", " "],
    ] {
        #expect(throws: CommandFailure.self) { try LaunchCommand(arguments: arguments) }
    }
}

@Test func packageListingNamesTheSourceOfRecordedPackages() throws {
    let fixture = try ThemeGalleryFixture()
    defer { fixture.close() }
    for id in ["clock", "weather"] {
        let source = fixture.directory.appending(path: "sources/\(id)")
        try fixture.write(#"{"id":"\#(id)","name":"\#(id)","version":"1","kind":"widgets","entry":"config.json"}"#,
                          to: source.appending(path: "package.json"))
        try fixture.write(#"{"widgets":[]}"#, to: source.appending(path: "config.json"))
        _ = try fixture.packages.install(source, record: PackageInstallRecord(source: "acme", name: "Acme", url: nil))
    }
    try FileManager.default.removeItem(at: fixture.packages.directory.appending(path: "weather/\(PackageInstallRecord.fileName)"))
    // A folder build of another version of Acme's clock is listed as the folder's.
    let folder = fixture.directory.appending(path: "sources/clock-2")
    try fixture.write(#"{"id":"clock","name":"clock","version":"2","kind":"widgets","entry":"config.json"}"#,
                      to: folder.appending(path: "package.json"))
    try fixture.write(#"{"widgets":[]}"#, to: folder.appending(path: "config.json"))
    _ = try fixture.packages.install(folder)
    let listing = try #require(JSONSerialization.jsonObject(with: packageListing(fixture.packages)) as? [[String: Any]])
    #expect(listing.map { $0["id"] as? String } == ["clock", "clock", "weather"])
    #expect(listing[0]["source"] as? String == "acme")
    #expect(listing[0]["name"] as? String == "clock")
    #expect(listing[1]["source"] as? String == "local")
    #expect(listing[2]["source"] == nil)
}
