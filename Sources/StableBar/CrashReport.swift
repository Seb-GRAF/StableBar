import Foundation

/// A crash of StableBar, read from the report macOS writes to ~/Library/Logs/DiagnosticReports after every crash.
/// The report stays on the Mac; `markdown` and `issueURL` are what the user can choose to copy or post.
struct CrashReport: Identifiable, Equatable, Sendable {
    struct Frame: Equatable, Sendable {
        var image: String
        var symbol: String?
        /// The offset into `symbol` when there is one, otherwise into `image`.
        var offset: Int
        /// `File.swift:12`, when the build kept line information.
        var source: String?

        var text: String { text(imageWidth: 0) }

        func text(imageWidth: Int, symbolLimit: Int = .max) -> String {
            guard let symbol else { return "\(image) + 0x\(String(offset, radix: 16))" }
            return "\(image.padding(toLength: max(imageWidth, image.count), withPad: " ", startingAt: 0))  "
                + "\(CrashReport.shortened(symbol, to: symbolLimit)) + \(offset)"
                + (source.map { " (\($0))" } ?? "")
        }
    }

    var id: String
    var file: URL
    var date: Date
    var version: String?
    var build: String?
    var system: String
    var model: String?
    var exception: String
    var subtype: String?
    var termination: String?
    var message: String?
    var thread: String
    var frames: [Frame]

    /// Reads a crash report (`bug_type` 309) of StableBar itself. Other reports, and files macOS is still writing, give nil.
    /// So does a launch that dyld stopped before StableBar's code ran, such as a build missing a framework.
    init?(data: Data, file: URL) {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")),
              let header = try? JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any],
              header["bug_type"] as? String == "309", (header["app_name"] ?? header["name"]) as? String == "StableBar",
              let body = try? JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any]
        else { return nil }
        let bundle = body["bundleInfo"] as? [String: Any]
        let os = body["osVersion"] as? [String: Any]
        let exception = body["exception"] as? [String: Any]
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "???" }
        let threads = body["threads"] as? [[String: Any]] ?? []
        let index = body["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
        let thread = threads.indices.contains(index) ? threads[index] : [:]

        id = header["incident_id"] as? String ?? body["incident"] as? String ?? file.lastPathComponent
        self.file = file
        guard let date = Self.date(body["captureTime"]) ?? Self.date(header["timestamp"]) else { return nil }
        self.date = date
        func text(_ value: Any?) -> String? { (value as? String).flatMap { $0.isEmpty ? nil : $0 } }
        version = text(header["app_version"]) ?? text(bundle?["CFBundleShortVersionString"])
        build = text(header["build_version"]) ?? text(bundle?["CFBundleVersion"])
        system = header["os_version"] as? String
            ?? [os?["train"] as? String, (os?["build"] as? String).map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        model = body["modelCode"] as? String
        self.exception = [exception?["type"] as? String ?? "Unknown exception", (exception?["signal"] as? String).map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        subtype = exception?["subtype"] as? String
        termination = (body["termination"] as? [String: Any])?["indicator"] as? String
        let messages = (body["asi"] as? [String: Any] ?? [:]).sorted { $0.key < $1.key }.flatMap { $0.value as? [String] ?? [] }
        message = messages.isEmpty ? nil : Self.redacted(messages.joined(separator: "\n"))
        let details = [thread["name"] as? String, thread["queue"] as? String].compactMap { $0 }
        self.thread = "Thread \(index)" + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")
        frames = (thread["frames"] as? [[String: Any]] ?? []).map { frame in
            let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "???"
            let symbol = frame["symbol"] as? String
            let file = frame["sourceFile"] as? String, line = frame["sourceLine"] as? Int
            return Frame(image: image, symbol: symbol,
                         offset: (symbol == nil ? frame["imageOffset"] : frame["symbolLocation"]) as? Int ?? 0,
                         source: file.map { "\($0)\(line.map { ":\($0)" } ?? "")" })
        }
        // dyld can also end a process that has run, as for a symbol missing at a later call: then some thread shows the
        // process's own frames, while at launch every thread is still in dyld.
        let launching = threads.allSatisfy { thread in
            (thread["frames"] as? [[String: Any]] ?? []).allSatisfy { frame in
                (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } == "dyld"
            }
        }
        if (body["termination"] as? [String: Any])?["namespace"] as? String == "DYLD", launching { return nil }
    }

    /// Where it crashed: the first frame in StableBar's own code, or the top frame when none is.
    var location: String? {
        let frame = frames.first { $0.image == "StableBar" } ?? frames.first
        return frame.map { $0.symbol ?? $0.text }
    }

    /// One line for lists: when, what, where, which build and which file.
    var summary: String {
        "\(Self.timestamp(date)): \(exception)\(location.map { " in \($0)" } ?? ""), StableBar \(release), \(file.lastPathComponent)"
    }

    var markdown: String { markdown() }

    /// The summary to paste into an issue, with at most `frameLimit` frames, `messageLimit` characters of message and
    /// `symbolLimit` characters of each frame's symbol.
    func markdown(frameLimit: Int = 60, messageLimit: Int = 2000, symbolLimit: Int = .max) -> String {
        let shown = frames.prefix(frameLimit)
        let width = shown.filter { $0.symbol != nil }.map(\.image.count).max() ?? 0
        let numberWidth = String(max(shown.count - 1, 0)).count
        var stack = shown.enumerated().map { index, frame in
            String(index).padding(toLength: numberWidth, withPad: " ", startingAt: 0) + "  " + frame.text(imageWidth: width, symbolLimit: symbolLimit)
        }
        if frames.count > shown.count { stack.append("… \(frames.count - shown.count) more frames in the report") }
        var lines = ["StableBar quit unexpectedly on \(Self.timestamp(date)).", ""]
        lines.append("- StableBar: \(release)")
        lines.append("- macOS: \(system)")
        if let model { lines.append("- Mac: \(model)") }
        lines.append("- Exception: \([exception, subtype].compactMap { $0 }.joined(separator: ", "))")
        if let termination { lines.append("- Termination: \(termination)") }
        lines.append("- Report: \(Self.redacted(file.path))")
        if let message {
            lines += ["", "Message:", "", "```", Self.shortened(message, to: messageLimit), "```"]
        }
        lines += ["", "Crashed thread: \(thread)", "", "```"] + stack + ["```"]
        return lines.joined(separator: "\n")
    }

    /// GitHub's bug report form with this crash filled in. Nothing is sent until the user submits the form.
    /// Long Swift symbols are shortened, then frames and message are cut until the address fits in `limit` characters.
    func issueURL(limit: Int = 8000) -> URL {
        let title = "StableBar quit unexpectedly: \(exception.split(separator: " ").first.map(String.init) ?? exception)"
            + (location.map { " in \(Self.shortened($0, to: 160))" } ?? "")
        let happened = "StableBar quit unexpectedly on \(Self.timestamp(date)).\n\nWhat I was doing when it happened: "
        let environment = "StableBar: \(release)\nmacOS: \(system)\nDisplays (how many, which have a notch):\n"
            + "AeroSpace or yabai version, if you use one:"
        func url(frames: Int, message: Int) -> URL {
            let fields = [("template", "bug_report.yml"), ("title", title), ("what-happens", happened),
                          ("environment", environment), ("evidence", markdown(frameLimit: frames, messageLimit: message, symbolLimit: 300))]
            let query = fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: Self.unreserved)!)" }.joined(separator: "&")
            return URL(string: "https://github.com/Seb-GRAF/StableBar/issues/new?\(query)")!
        }
        var frames = 60, message = 2000
        var result = url(frames: frames, message: message)
        while result.absoluteString.count > limit, frames > 0 || message > 200 {
            if message > 200 { message /= 2 } else { frames = frames * 2 / 3 }
            result = url(frames: frames, message: message)
        }
        return result
    }

    private static func shortened(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// The version from the app's Info.plist. A binary without one, as `swift build` makes, is a development build.
    var versionName: String { version ?? "development build" }

    var release: String {
        [versionName, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }

    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter.string(from: date)
    }

    /// Reads `2026-10-26 14:03:12.1234 +0200`, whatever the number of fractional digits.
    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression))
    }

    /// Home folders, the user's or a build machine's, become `~`.
    static func redacted(_ text: String) -> String {
        text.replacingOccurrences(of: #"/Users/[^/\s]+"#, with: "~", options: .regularExpression)
    }
}
