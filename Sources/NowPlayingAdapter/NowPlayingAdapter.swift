import CryptoKit
import Foundation

// What plays now, as Control Center's Now Playing shows it, from MediaRemote. Since macOS 15.4 MediaRemote answers only
// Apple's own binaries, so StableBar never loads this library itself: Resources/now-playing.pl loads it into
// /usr/bin/perl, one of Apple's binaries, and calls one of the entry points below. Each looks its calls up at runtime
// and exits with 1 when this macOS no longer has one.

nonisolated(unsafe) private let mediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)

private func function<Function>(_ name: String, as type: Function.Type) -> Function {
    guard let symbol = dlsym(mediaRemote, name) else { exit(1) }
    return unsafeBitCast(symbol, to: type)
}

private func constant(_ name: String) -> String {
    guard let symbol = dlsym(mediaRemote, name) else { exit(1) }
    return symbol.assumingMemoryBound(to: CFString.self).pointee as String
}

/// Prints StableBar's output for what plays now, then again each time it changes, until perl is stopped. The output
/// has the track's `title`, `artist` and `album`, the playing app's bundle ID in `app`, `playing` ("1" while it plays),
/// `canNext` and `canPrevious` ("1" when the app takes those commands, empty when it doesn't, absent when it doesn't
/// say) and `artwork`, a file in the temporary folder.
@_cdecl("stablebar_now_playing_watch")
public func watch() {
    let queue = DispatchQueue(label: "StableBar.NowPlaying")
    function("MRMediaRemoteRegisterForNowPlayingNotifications", as: (@convention(c) (DispatchQueue) -> Void).self)(queue)
    let names = ["kMRMediaRemoteNowPlayingInfoDidChangeNotification", "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                 "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification", "kMRMediaRemoteSupportedCommandsDidChangeNotification"]
    for name in names.map(constant) {
        NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { _ in queue.async { read(on: queue) } }
    }
    try? FileManager.default.removeItem(at: Artwork.folder)
    queue.async { read(on: queue) }
    dispatchMain()
}

/// Sends the command whose number ends perl's arguments, such as 2 to play or pause, to the app that plays now.
@_cdecl("stablebar_now_playing_send")
public func send() {
    let send = function("MRMediaRemoteSendCommand", as: (@convention(c) (Int32, CFDictionary?) -> Bool).self)
    guard let command = CommandLine.arguments.last.flatMap(Int32.init), send(command, nil) else { exit(1) }
    // The command travels to the app on MediaRemote's queue: give it a moment before perl exits.
    Thread.sleep(forTimeInterval: 0.2)
    exit(0)
}

private func read(on queue: DispatchQueue) {
    typealias Info = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    typealias Playing = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    typealias App = @convention(c) (DispatchQueue, @escaping @convention(block) (NSString?) -> Void) -> Void
    typealias Commands = @convention(c) (DispatchQueue, @escaping @convention(block) (NSArray?) -> Void) -> Void
    function("MRMediaRemoteGetNowPlayingInfo", as: Info.self)(queue) { info in
        function("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: Playing.self)(queue) { playing in
            function("MRMediaRemoteGetNowPlayingApplicationDisplayID", as: App.self)(queue) { app in
                function("MRMediaRemoteCopySupportedCommands", as: Commands.self)(queue) { commands in
                    emit(info as? [String: Any] ?? [:], playing: playing, app: app as String?, commands: commands)
                }
            }
        }
    }
}

/// Whether `commands`, the playing app's, take MediaRemote's command `number`, such as 4 for next.
private func takes(_ number: Int32, _ commands: NSArray) -> Bool {
    let command = function("MRMediaRemoteCommandInfoGetCommand", as: (@convention(c) (AnyObject) -> Int32).self)
    let enabled = function("MRMediaRemoteCommandInfoGetEnabled", as: (@convention(c) (AnyObject) -> Bool).self)
    return commands.contains(where: { command($0 as AnyObject) == number && enabled($0 as AnyObject) })
}

private func emit(_ info: [String: Any], playing: Bool, app: String?, commands: NSArray?) {
    let title = info[constant("kMRMediaRemoteNowPlayingInfoTitle")] as? String ?? ""
    var fields = ["title": title, "playing": playing ? "1" : "", "app": app ?? ""]
    fields["artist"] = info[constant("kMRMediaRemoteNowPlayingInfoArtist")] as? String
    fields["album"] = info[constant("kMRMediaRemoteNowPlayingInfoAlbum")] as? String
    if let commands {
        fields["canNext"] = takes(4, commands) ? "1" : ""
        fields["canPrevious"] = takes(5, commands) ? "1" : ""
    }
    let track = [app, title, fields["artist"], fields["album"]].map { $0 ?? "" }
    fields["artwork"] = Artwork.file(info[constant("kMRMediaRemoteNowPlayingInfoArtworkData")] as? Data, track: track)
    let output: [String: Any] = ["text": title, "icon": playing ? "music.note" : "pause.circle", "fields": fields]
    var line = try! JSONSerialization.data(withJSONObject: output)
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
}

/// The current track's artwork, kept in a file named after its data, so StableBar loads a new image only when it changes.
private enum Artwork {
    static let folder = FileManager.default.temporaryDirectory.appending(path: "StableBar-now-playing")
    nonisolated(unsafe) private static var current: (track: [String], file: URL)?

    /// The file for `data`, or without data the last track's file while the track stays the same: MediaRemote leaves
    /// the artwork out of some of its updates, such as one that only pauses.
    static func file(_ data: Data?, track: [String]) -> String? {
        guard let data else { return current?.track == track ? current?.file.path : nil }
        let file = folder.appending(path: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        if file != current?.file || !FileManager.default.fileExists(atPath: file.path) {
            if let current, current.file != file { try? FileManager.default.removeItem(at: current.file) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file)
            } catch {
                current = nil
                return nil
            }
        }
        current = (track, file)
        return file.path
    }
}
