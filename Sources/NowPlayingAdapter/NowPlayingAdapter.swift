import CoreServices
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

typealias InfoCall = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void

/// Prints StableBar's output for what plays now, then again each time it changes and each second while it plays, until
/// perl is stopped. The output has the track's `title`, `artist` and `album`, and `line` with both; the playing app's
/// bundle ID in `app`, its name in `source` and its path in `appIcon`; `playing` ("1" while it plays) and `control`,
/// the symbol of the button that plays or pauses it; `elapsed` and `duration` as text and `values.progress`; `canNext`,
/// `canPrevious` and `canSeek` ("1" when the app takes those commands, empty when it doesn't, absent when it doesn't
/// say); and `artwork`, a file in the temporary folder.
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
    // The position moves on its own while something plays, and MediaRemote doesn't announce that.
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { Latest.tick() }
    timer.resume()
    dispatchMain()
}

/// Sends the command named last in perl's arguments to the app that plays now: `togglePlayPause`, `nextTrack`,
/// `previousTrack`, or `skipBackward` and `skipForward`, which move the position by 15 seconds.
@_cdecl("stablebar_now_playing_send")
public func send() {
    let send = function("MRMediaRemoteSendCommand", as: (@convention(c) (Int32, CFDictionary?) -> Bool).self)
    let finish = { (sent: Bool) -> Never in
        // The command travels to the app on MediaRemote's queue: give it a moment before perl exits.
        Thread.sleep(forTimeInterval: 0.2)
        exit(sent ? 0 : 1)
    }
    switch CommandLine.arguments.last {
    case "togglePlayPause": finish(send(2, nil))
    case "nextTrack": finish(send(4, nil))
    case "previousTrack": finish(send(5, nil))
    case let skip where skip == "skipBackward" || skip == "skipForward":
        let queue = DispatchQueue(label: "StableBar.NowPlaying")
        function("MRMediaRemoteGetNowPlayingInfo", as: InfoCall.self)(queue) { info in
            let info = info as? [String: Any] ?? [:]
            let target = max(0, (position(info) ?? 0) + (skip == "skipForward" ? 15 : -15))
            finish(send(24, [constant("kMRMediaRemoteOptionPlaybackPosition"): target] as CFDictionary))
        }
        dispatchMain()
    default: exit(1)
    }
}

/// Where the track is now: the elapsed time MediaRemote last gave, moved on by the time since at the playback rate.
private func position(_ info: [String: Any]) -> Double? {
    guard let elapsed = (info[constant("kMRMediaRemoteNowPlayingInfoElapsedTime")] as? NSNumber)?.doubleValue else { return nil }
    let rate = (info[constant("kMRMediaRemoteNowPlayingInfoPlaybackRate")] as? NSNumber)?.doubleValue ?? 0
    let since = (info[constant("kMRMediaRemoteNowPlayingInfoTimestamp")] as? Date).map { Date().timeIntervalSince($0) } ?? 0
    let duration = (info[constant("kMRMediaRemoteNowPlayingInfoDuration")] as? NSNumber)?.doubleValue ?? .infinity
    return min(max(elapsed + since * rate, 0), duration)
}

private func read(on queue: DispatchQueue) {
    typealias Playing = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    typealias App = @convention(c) (DispatchQueue, @escaping @convention(block) (NSString?) -> Void) -> Void
    typealias Commands = @convention(c) (DispatchQueue, @escaping @convention(block) (NSArray?) -> Void) -> Void
    function("MRMediaRemoteGetNowPlayingInfo", as: InfoCall.self)(queue) { info in
        function("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: Playing.self)(queue) { playing in
            function("MRMediaRemoteGetNowPlayingApplicationDisplayID", as: App.self)(queue) { app in
                function("MRMediaRemoteCopySupportedCommands", as: Commands.self)(queue) { commands in
                    Latest.state = (info as? [String: Any] ?? [:], playing, app as String?, commands)
                    Latest.emit()
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

/// What MediaRemote said last, on the watch's queue, which the output each second moves on from.
private enum Latest {
    nonisolated(unsafe) static var state: (info: [String: Any], playing: Bool, app: String?, commands: NSArray?)?

    static func tick() {
        if state?.playing == true, state?.info[constant("kMRMediaRemoteNowPlayingInfoDuration")] != nil { emit() }
    }

    static func emit() {
        guard let (info, playing, app, commands) = state else { return }
        let title = info[constant("kMRMediaRemoteNowPlayingInfoTitle")] as? String ?? ""
        let artist = info[constant("kMRMediaRemoteNowPlayingInfoArtist")] as? String ?? ""
        var fields = ["title": title, "artist": artist, "line": artist.isEmpty ? title : "\(title) — \(artist)",
                      "playing": playing ? "1" : "", "control": playing ? "pause.fill" : "play.fill", "app": app ?? ""]
        fields["album"] = info[constant("kMRMediaRemoteNowPlayingInfoAlbum")] as? String
        if let app, let bundle = Apps.bundle(app) {
            fields["source"] = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? bundle.object(forInfoDictionaryKey: "CFBundleName")) as? String
            fields["appIcon"] = bundle.bundlePath
        }
        var values: [String: Double] = [:]
        if let duration = (info[constant("kMRMediaRemoteNowPlayingInfoDuration")] as? NSNumber)?.doubleValue, duration > 0,
           let position = position(info) {
            fields["elapsed"] = clock(position)
            fields["duration"] = clock(duration)
            values["progress"] = position / duration
        }
        if let commands {
            fields["canNext"] = takes(4, commands) ? "1" : ""
            fields["canPrevious"] = takes(5, commands) ? "1" : ""
            fields["canSeek"] = takes(24, commands) ? "1" : ""
        }
        let track = [app ?? "", title, artist, fields["album"] ?? ""]
        fields["artwork"] = Artwork.file(info[constant("kMRMediaRemoteNowPlayingInfoArtworkData")] as? Data, track: track)
        let output: [String: Any] = ["text": title, "icon": playing ? "music.note" : "pause.circle", "fields": fields, "values": values,
                                     "hidden": title.isEmpty]
        var line = try! JSONSerialization.data(withJSONObject: output)
        line.append(0x0A)
        FileHandle.standardOutput.write(line)
    }

    /// `seconds` as `m:ss`, or `h:mm:ss` from an hour.
    private static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        let minutes = String(format: "%02d", whole / 60 % 60), rest = String(format: "%02d", whole % 60)
        return whole >= 3600 ? "\(whole / 3600):\(minutes):\(rest)" : "\(whole / 60):\(rest)"
    }
}

/// The apps that play, by bundle ID, found once each.
private enum Apps {
    nonisolated(unsafe) private static var found: [String: Bundle?] = [:]

    static func bundle(_ id: String) -> Bundle? {
        if let bundle = found[id] { return bundle }
        let url = (LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() as? [URL])?.first
        let bundle = url.flatMap(Bundle.init(url:))
        found[id] = bundle
        return bundle
    }
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
