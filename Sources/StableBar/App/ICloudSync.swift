import Foundation

/// Keeps the configuration folder in iCloud Drive and links it back to where StableBar reads it, so every Mac signed in
/// to the same Apple Account loads the same bar. Whether it's on is read from the folder itself, never stored.
struct ICloudSync {
    enum State: Equatable {
        case off, on
        /// Why it can't be turned on.
        case unavailable(String)
    }

    /// Which configuration stays when iCloud Drive already has one from another Mac.
    enum Keep { case thisMac, iCloud }

    /// The folder StableBar reads, such as `~/.config/stablebar`.
    let folder: URL
    var drive = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)

    var synced: URL { drive.appending(path: "StableBar", directoryHint: .isDirectory) }

    var state: State {
        let files = FileManager.default
        if let destination = try? files.destinationOfSymbolicLink(atPath: folder.path) {
            let target = URL(filePath: destination, relativeTo: folder.deletingLastPathComponent())
            if target.standardizedFileURL.path == synced.standardizedFileURL.path { return .on }
            let home = NSHomeDirectory()
            return .unavailable("\(folder.path.replacingOccurrences(of: home, with: "~")) is a link to "
                + "\(target.path.replacingOccurrences(of: home, with: "~")). Remove the link to sync it from here.")
        }
        guard files.fileExists(atPath: drive.path) else {
            return .unavailable("Turn on iCloud Drive in System Settings → Apple Account → iCloud.")
        }
        return .off
    }

    /// Whether iCloud Drive already has a configuration, such as one another Mac synced.
    var hasSyncedConfiguration: Bool { FileManager.default.fileExists(atPath: synced.path) }

    /// Copies iCloud Drive keeps when two Macs save a file at once, such as `config 2.json` beside `config.json`.
    var conflicts: [String] {
        guard state == .on, let names = try? FileManager.default.contentsOfDirectory(atPath: synced.path) else { return [] }
        return names.filter { name in
            guard let match = name.wholeMatch(of: /(.+) [0-9]+(\.[^.]+)?/) else { return false }
            return names.contains(String(match.1) + String(match.2 ?? ""))
        }.sorted()
    }

    /// Moves the folder into iCloud Drive and links it back. The configuration not kept goes to the Trash.
    func turnOn(keeping keep: Keep = .thisMac) throws {
        guard state == .off else { return }
        let files = FileManager.default
        let hasFolder = files.fileExists(atPath: folder.path)
        let replacesSynced = hasSyncedConfiguration && hasFolder && keep == .thisMac
        let usesSynced = hasSyncedConfiguration && !replacesSynced
        // Both are set aside rather than trashed at once, so a step that fails puts everything back.
        let aside = folder.deletingLastPathComponent().appending(path: ".\(folder.lastPathComponent)-before-icloud")
        let replaced = drive.appending(path: ".StableBar-replaced")
        if hasFolder { try files.moveItem(at: folder, to: aside) }
        do {
            if replacesSynced { try files.moveItem(at: synced, to: replaced) }
            if !usesSynced {
                if hasFolder { try files.moveItem(at: aside, to: synced) }
                else { try files.createDirectory(at: synced, withIntermediateDirectories: true) }
            }
            try files.createSymbolicLink(at: folder, withDestinationURL: synced)
        } catch {
            if hasFolder, !usesSynced, !files.fileExists(atPath: aside.path) { try? files.moveItem(at: synced, to: aside) }
            if hasFolder { try? files.moveItem(at: aside, to: folder) }
            if replacesSynced, files.fileExists(atPath: replaced.path) { try? files.moveItem(at: replaced, to: synced) }
            throw error
        }
        if replacesSynced { try files.trashItem(at: replaced, resultingItemURL: nil) }
        if usesSynced, hasFolder { try files.trashItem(at: aside, resultingItemURL: nil) }
    }

    /// Replaces the link with a copy of the synced folder. The folder stays in iCloud Drive for the other Macs.
    func turnOff() throws {
        guard state == .on else { return }
        let files = FileManager.default
        let copy = folder.deletingLastPathComponent().appending(path: ".\(folder.lastPathComponent)-from-icloud")
        try? files.removeItem(at: copy)
        // Copying downloads the files macOS evicted to save space, so the copy holds their contents.
        try files.copyItem(at: synced, to: copy)
        do {
            try files.removeItem(at: folder)
            try files.moveItem(at: copy, to: folder)
        } catch {
            if !files.fileExists(atPath: folder.path) { try? files.createSymbolicLink(at: folder, withDestinationURL: synced) }
            try? files.removeItem(at: copy)
            throw error
        }
    }
}
