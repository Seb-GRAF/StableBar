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
    let start = ContinuousClock.now
    do {
        _ = try await runCommand("/bin/zsh", arguments: ["-c", "head -c 1048577 /dev/zero" + (stderr ? " >&2" : "")])
        Issue.record("The oversized output was accepted.")
    } catch {
        #expect(error.localizedDescription == "Command output exceeded 1 MiB.")
    }
    #expect(start.duration(to: .now) < .seconds(2))
}

@Test(arguments: [false, true])
func cancellingOrTimingOutStopsShellChildren(timeout: Bool) async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    let task = Task {
        try await runCommand("/bin/zsh", arguments: ["-c", "trap '' TERM; sleep 30 & printf '%s' $! > '\(marker.path).tmp'; mv '\(marker.path).tmp' '\(marker.path)'; wait"],
                             timeout: timeout ? 0.3 : 10)
    }
    defer { task.cancel() }
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: marker.path) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let child = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
    let start = ContinuousClock.now
    if !timeout { task.cancel() }
    do {
        _ = try await task.value
        Issue.record("The stopped command was accepted.")
    } catch {
        if timeout {
            #expect(error.localizedDescription == "Command timed out after 0.3 seconds.")
        } else {
            #expect(error is CancellationError)
        }
    }
    #expect(start.duration(to: .now) < .seconds(2))
    for _ in 0..<200 {
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

@Test func commandTimeoutClosesPipesHeldByChildrenAfterTheShellExits() async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    let start = ContinuousClock.now
    do {
        _ = try await runCommand("/bin/sh", arguments: ["-c", "sleep 30 & printf '%s' $! > '\(marker.path)'"], timeout: 0.3)
        Issue.record("The command completed while a child still held its pipes.")
    } catch {
        #expect(error.localizedDescription == "Command timed out after 0.3 seconds.")
    }
    #expect(start.duration(to: .now) < .seconds(2))
    let child = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
    for _ in 0..<200 {
        if kill(child, 0) == -1 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(kill(child, 0) == -1)
    #expect(errno == ESRCH)
}

@Test(arguments: [false, true])
func stoppedCommandDoesNotWaitForPipesHeldByAnEscapedChild(timeout: Bool) async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    let task = Task {
        try await runCommand("/usr/bin/perl", arguments: ["-MPOSIX", "-e", """
            if (fork() == 0) {
                POSIX::setsid();
                open(my $marker, '>', $ARGV[0] . '.tmp');
                print $marker $$;
                close($marker);
                rename($ARGV[0] . '.tmp', $ARGV[0]);
                exec('/bin/sleep', '3');
            }
            """, marker.path], timeout: timeout ? 0.5 : 10)
    }
    defer { task.cancel() }
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: marker.path) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let child = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
    defer { kill(child, SIGKILL) }
    #expect(getpgid(child) == child)
    let start = ContinuousClock.now
    if !timeout { task.cancel() }
    do {
        _ = try await task.value
        Issue.record("The stopped command was accepted.")
    } catch {
        if timeout {
            #expect(error.localizedDescription == "Command timed out after 0.5 seconds.")
        } else {
            #expect(error is CancellationError)
        }
    }
    #expect(start.duration(to: .now) < .seconds(1.5))
}

@Test(arguments: [false, true])
func stoppedCommandCannotEscapeByChangingItsProcessGroup(timeout: Bool) async throws {
    let marker = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: marker) }
    let task = Task {
        try await runCommand("/usr/bin/perl", arguments: ["-MPOSIX", "-e", """
            POSIX::setpgid(0, getpgrp(getppid()));
            open(my $marker, '>', $ARGV[0] . '.tmp');
            print $marker "$$ ", getpgrp(0);
            close($marker);
            rename($ARGV[0] . '.tmp', $ARGV[0]);
            exec('/bin/sleep', '3');
            """, marker.path], timeout: timeout ? 0.5 : 10)
    }
    defer { task.cancel() }
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: marker.path) { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let identity = try String(contentsOf: marker, encoding: .utf8).split(separator: " ").compactMap { Int32($0) }
    try #require(identity.count == 2)
    let process = identity[0]
    defer { kill(process, SIGKILL) }
    // The timeout can reap the process before this task resumes, so read the group it recorded while alive.
    #expect(identity[1] == getpgrp())
    let start = ContinuousClock.now
    if !timeout { task.cancel() }
    do {
        _ = try await task.value
        Issue.record("The stopped command was accepted.")
    } catch {
        if timeout {
            #expect(error.localizedDescription == "Command timed out after 0.5 seconds.")
        } else {
            #expect(error is CancellationError)
        }
    }
    #expect(start.duration(to: .now) < .seconds(1.5))
    #expect(kill(process, 0) == -1)
    #expect(errno == ESRCH)
}
