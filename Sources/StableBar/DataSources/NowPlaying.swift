import Foundation

/// What plays now in any app, as Control Center's Now Playing shows it. StableBar's now-playing library reads it from
/// MediaRemote inside perl (Resources/now-playing.pl), and sends the Sound details' commands the same way.
enum NowPlaying {
    /// What a button sends to the playing app; `skipBackward` and `skipForward` move it by 15 seconds.
    enum Command: String, Decodable, Sendable {
        case togglePlayPause, nextTrack, previousTrack, skipBackward, skipForward
    }

    /// Runs the library's `watch` in perl, which prints StableBar's output for each change.
    static var watchCommand: String {
        ["/usr/bin/perl", script, library, "watch"].map(CommandLineTool.quoted).joined(separator: " ")
    }

    static func send(_ command: Command) async throws {
        _ = try await runCommand("/usr/bin/perl", arguments: [script, library, "send", command.rawValue])
    }

    private static var script: String { Bundle.main.bundleURL.appending(path: "Contents/Resources/now-playing.pl").path }
    private static var library: String { Bundle.main.bundleURL.appending(path: "Contents/Frameworks/libStableBarNowPlaying.dylib").path }
}
