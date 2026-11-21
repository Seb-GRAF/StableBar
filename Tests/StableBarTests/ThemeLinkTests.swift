import Foundation
import Testing
@testable import StableBar

struct ThemeLinkTests {
    @Test func themeLinksRoundTripTheExactFileBytes() throws {
        let sample = try sample()
        let manifest = Data(sample.manifest.utf8)
        let configuration = Data(sample.configuration.utf8)
        let link = ThemeLink(manifest: manifest, configuration: configuration)
        #expect(sample.manifest.unicodeScalars.contains { !$0.isASCII })
        #expect(link.link.absoluteString == sample.link)
        let encodedFiles = URLComponents(string: sample.link)!.queryItems!
            .filter { $0.name == "package" || $0.name == "config" }.compactMap(\.value).joined()
        #expect(encodedFiles.contains("-"))
        #expect(encodedFiles.contains("_"))
        #expect(manifest == (try Data(contentsOf: fixtures.appending(path: "linked-theme/package.json"))))
        #expect(configuration == (try Data(contentsOf: fixtures.appending(path: "linked-theme/config.json"))))
        #expect(try ThemeLink(url: URL(string: sample.link)!) == link)

        var padded = URLComponents(string: sample.link)!
        padded.queryItems = padded.queryItems?.map { item in
            guard item.name == "package" || item.name == "config", let value = item.value else { return item }
            let padding = String(repeating: "=", count: (4 - value.utf8.count % 4) % 4)
            return URLQueryItem(name: item.name, value: value + padding)
        }
        #expect(try ThemeLink(url: padded.url!) == link)
        #expect(manifest.count % 3 == 1)
        let literallyPadded = sample.link.replacingOccurrences(of: "&config=", with: "==&config=")
        #expect(try ThemeLink(url: URL(string: literallyPadded)!) == link)
        #expect(try ThemeLink(url: URL(string: sample.link + "&x=1")!) == link)
    }

    @Test(arguments: [("-", "+"), ("_", "/")])
    func standardBase64AlphabetIsRefused(urlCharacter: String, standardCharacter: String) throws {
        let sample = try sample()
        #expect(sample.link.contains(urlCharacter))
        let link = sample.link.replacingOccurrences(of: urlCharacter, with: standardCharacter)
        #expect(throws: ThemeLinkError.damaged) { try ThemeLink(url: URL(string: link)!) }
    }

    @Test(arguments: ["stablebar://package/nord", "https://theme?v=1", "stablebar://themes?v=1"])
    func otherLinksAreNotThemeLinks(link: String) throws {
        #expect(try ThemeLink(url: URL(string: link)!) == nil)
    }

    @Test(arguments: [
        ("v=1&config=e30", ThemeLinkError.damaged),
        ("v=1&package=!!&config=e30", .damaged),
        ("v=1&package=e30&config=WzFd", .damaged),
        ("package=e30&config=e30", .damaged),
        ("v=2&package=e30&config=e30", .damaged),
        ("v=2&d=", .damaged),
        ("v=2&d=!!", .damaged),
        ("v=2&d=AAAA", .damaged),
        ("v=3&package=e30&config=e30", .unsupportedVersion("3")),
        ("v=3&d=AAAA", .unsupportedVersion("3")),
        ("v=&package=e30&config=e30", .damaged),
        ("v=0&package=e30&config=e30", .damaged),
        ("v=-1&package=e30&config=e30", .damaged),
        ("v=abc&package=e30&config=e30", .damaged)
    ])
    func damagedThemeLinksSayWhy(query: String, error: ThemeLinkError) {
        #expect(throws: error) {
            try ThemeLink(url: URL(string: "stablebar://theme?" + query)!)
        }
    }

    @Test(arguments: [
        "stablebar://theme/?v=1&package=e30&config=e30",
        "stablebar://theme/extra?v=1&package=e30&config=e30",
        "stablebar://theme?v=1&package=e30&config=e30#fragment",
        "stablebar://theme?v=1&package=e30&config=e30#",
        "stablebar://user@theme?v=1&package=e30&config=e30",
        "stablebar://user:password@theme?v=1&package=e30&config=e30",
        "stablebar://theme:123?v=1&package=e30&config=e30"
    ])
    func additionalURLComponentsAreDamaged(link: String) {
        #expect(throws: ThemeLinkError.damaged) { try ThemeLink(url: URL(string: link)!) }
    }

    @Test(arguments: [
        "v=1&package=WzFd&config=e30",
        "v=1&package=e30&config=!!",
        "v=1&package=e30&config=bnVsbA",
        "v=1&package=e30&config=ew",
        "v=1&package=e30",
        "v=1&package&config=e30"
    ])
    func bothFilesMustBeJSONObjects(query: String) {
        #expect(throws: ThemeLinkError.damaged) {
            try ThemeLink(url: URL(string: "stablebar://theme?" + query)!)
        }
    }

    @Test(arguments: [
        "v=1&v=2&package=e30&config=e30",
        "v=1&package=e30&package=e30&config=e30",
        "v=1&package=e30&config=e30&config=e30",
        "v=1&package=e30==&config=e30",
        "v=1&package=e30&config=e=30",
        "v=1&package=e30&config=a"
    ])
    func ambiguousOrMalformedQueryItemsAreDamaged(query: String) {
        #expect(throws: ThemeLinkError.damaged) {
            try ThemeLink(url: URL(string: "stablebar://theme?" + query)!)
        }
    }

    @Test func themeLinksOverTheLimitsAreRefused() throws {
        let prefix = "stablebar://theme?"
        let longLink = prefix + String(repeating: "x", count: 65_537 - prefix.utf8.count)
        #expect(longLink.utf8.count == 65_537)
        #expect(throws: ThemeLinkError.tooLong) { try ThemeLink(url: URL(string: longLink)!) }

        let large = ThemeLink(manifest: paddedObject(bytes: 70_000), configuration: paddedObject(bytes: 61_073))
        #expect(throws: ThemeLinkError.tooLarge) { try large.validateFiles() }
        #expect(throws: ThemeLinkError.tooLarge) { try ThemeLink(url: compressedLink(large)) }

        let deep = ThemeLink(manifest: Data("{}".utf8), configuration: nestedObject(levels: 33))
        #expect(throws: ThemeLinkError.tooDeep) { try ThemeLink(url: deep.link) }
    }

    @Test func themeLinksAtTheLimitsAreAccepted() throws {
        #expect(ThemeLink.maximumLength == 65_536)
        #expect(ThemeLink.maximumFileBytes == 131_072)
        #expect(ThemeLink.maximumDepth == 32)
        #expect(ThemeLink.maximumValues == 4_096)

        let link = ThemeLink(manifest: Data("{}".utf8), configuration: Data("{}".utf8))
        let prefix = link.link.absoluteString + "&x="
        let maximumLength = prefix + String(repeating: "x", count: 65_536 - prefix.utf8.count)
        #expect(try ThemeLink(url: URL(string: maximumLength)!) == link)

        try ThemeLink(manifest: paddedObject(bytes: 70_000), configuration: paddedObject(bytes: 61_072)).validateFiles()

        let maximumDepth = ThemeLink(manifest: Data("{}".utf8), configuration: nestedObject(levels: 32))
        #expect(try ThemeLink(url: maximumDepth.link) == maximumDepth)
    }

    @Test func compressedThemeLinksCarryTheExactFilesInAPayloadOfAtMost128KB() throws {
        let sample = try sample()
        let link = ThemeLink(manifest: Data(sample.manifest.utf8), configuration: Data(sample.configuration.utf8))
        let url = try compressedLink(link)
        #expect(url.absoluteString.hasPrefix("stablebar://theme?v=2&d="))
        #expect(try ThemeLink(url: url) == link)

        func payload(spaces: Int) throws -> Data {
            try JSONEncoder().encode(["package": "{}", "config": "{" + String(repeating: " ", count: spaces) + "}"])
        }
        let spaces = try ThemeLink.maximumFileBytes - payload(spaces: 0).count
        let full = ThemeLink(manifest: Data("{}".utf8), configuration: Data(("{" + String(repeating: " ", count: spaces) + "}").utf8))
        #expect(try ThemeLink(url: compressedLink(payload: payload(spaces: spaces))) == full)
        #expect(throws: ThemeLinkError.tooLarge) { try ThemeLink(url: compressedLink(payload: payload(spaces: spaces + 1))) }

        for damaged in ["{", "[]", #"{"package":"{}"}"#, #"{"package":{},"config":"{}"}"#, #"{"package":"{}","config":"{}","widgets":"[]"}"#] {
            #expect(throws: ThemeLinkError.damaged) { try ThemeLink(url: compressedLink(payload: Data(damaged.utf8))) }
        }
    }

    @Test(arguments: [false, true])
    func rawValuesAcrossBothFilesAreLimitedBeforeDecoding(inManifest: Bool) throws {
        // Two roots and the array leave the rest of the values to its scalars.
        let scalars = ["null", "true", "false", "-12.5e2", #""commas, [ ] { } \" \\ \u0066""#]
        let entries = (0..<ThemeLink.maximumValues - 3).map { scalars[$0 % scalars.count] }.joined(separator: ",")
        let full = Data((#"{"values":["# + entries + "]}").utf8)
        let empty = Data("{}".utf8)
        let link = ThemeLink(manifest: inManifest ? full : empty, configuration: inManifest ? empty : full)
        #expect(try ThemeLink(url: link.link) == link)

        let extra = Data(#"{"x":0}"#.utf8)
        let overflow = ThemeLink(manifest: inManifest ? full : extra, configuration: inManifest ? extra : full)

        #expect(throws: ThemeLinkError.tooManySettings) { try ThemeLink(url: overflow.link) }
    }

    @Test func duplicateKeysCannotHideValuesFromTheRawLimit() {
        let entries = Array(repeating: #""x":{}"#, count: ThemeLink.maximumValues - 1).joined(separator: ",")
        let link = ThemeLink(manifest: Data("{}".utf8), configuration: Data(("{" + entries + "}").utf8))

        #expect(throws: ThemeLinkError.tooManySettings) {
            try ThemeLink(url: link.link)
        }
    }

    @Test(arguments: [false, true])
    func deeplyNestedFilesAreRefusedBeforeConfigurationValueDecoding(inManifest: Bool) {
        let nested = nestedObject(levels: 501, padding: 30_800)
        let empty = Data("{}".utf8)
        let link = ThemeLink(manifest: inManifest ? nested : empty, configuration: inManifest ? empty : nested)
        #expect(nested.count < ThemeLink.maximumFileBytes)
        #expect(link.link.absoluteString.utf8.count < 65_536)
        #expect(throws: ThemeLinkError.tooDeep) {
            try ThemeLink(url: link.link)
        }
    }

    @Test func depthCountsObjectsAndArraysButNotTheirStringContents() throws {
        let leaf = #"{"text":"[[[[{{{{\"\\"}"#
        let configuration = String(repeating: #"{"x":["#, count: 15) + leaf + String(repeating: "]}", count: 15)
        let link = ThemeLink(manifest: Data("{}".utf8), configuration: Data(configuration.utf8))
        #expect(try ThemeLink(url: link.link) == link)
        let tooDeep = #"{"x":["# + configuration + "]}"
        let deeper = ThemeLink(manifest: Data("{}".utf8), configuration: Data(tooDeep.utf8))
        #expect(throws: ThemeLinkError.tooDeep) { try ThemeLink(url: deeper.link) }
    }

    @Test(arguments: [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian,
                      .utf32, .utf32LittleEndian, .utf32BigEndian])
    func themeFilesMustUseUTF8(encoding: String.Encoding) throws {
        let data = try #require(#"{"label":"Harbour — Nord"}"#.data(using: encoding))
        let empty = Data("{}".utf8)
        for inManifest in [false, true] {
            let link = ThemeLink(manifest: inManifest ? data : empty, configuration: inManifest ? empty : data)

            #expect(throws: ThemeLinkError.damaged) {
                try ThemeLink(url: link.link)
            }
        }
    }

    @Test func utf8ByteOrderMarksPreserveTheExactBytes() throws {
        let manifest = Data("\u{FEFF}{\"name\":\"Harbour — Nord\"}".utf8)
        let configuration = Data([0xEF, 0xBB, 0xBF]) + nestedObject(levels: 32)
        let link = ThemeLink(manifest: manifest, configuration: configuration)
        #expect(try ThemeLink(url: link.link) == link)
        let deep = ThemeLink(manifest: manifest, configuration: Data([0xEF, 0xBB, 0xBF]) + nestedObject(levels: 33))
        #expect(throws: ThemeLinkError.tooDeep) { try ThemeLink(url: deep.link) }
    }

    @Test func excessiveDepthIsRefusedBeforeTheJSONParsersDepthLimit() {
        let link = ThemeLink(manifest: Data("{}".utf8), configuration: nestedObject(levels: 5_001))
        #expect(link.configuration.count < ThemeLink.maximumFileBytes)

        #expect(throws: ThemeLinkError.tooDeep) {
            try ThemeLink(url: link.link)
        }
    }

    @Test(arguments: [false, true])
    func duplicateJSONKeysCannotHideDeepValues(deepValueFirst: Bool) throws {
        let nested = try #require(String(data: nestedObject(levels: 40), encoding: .utf8))
        let entries = [#""x":"# + nested, #""x":null"#]
        let ordered = deepValueFirst ? entries : entries.reversed().map { $0 }
        let configuration = Data(("{" + ordered.joined(separator: ",") + "}").utf8)
        let link = ThemeLink(manifest: Data("{}".utf8), configuration: configuration)

        #expect(throws: ThemeLinkError.tooDeep) {
            try ThemeLink(url: link.link)
        }
    }

    @Test(arguments: [false, true])
    func duplicateJSONKeysCannotHideExtraProfiles(extraProfilesFirst: Bool) throws {
        let extra = try #require(String(data: profiles(count: 17), encoding: .utf8))
        let entries = [String(extra.dropFirst().dropLast()), #""profiles":[]"#]
        let ordered = extraProfilesFirst ? entries : entries.reversed().map { $0 }
        let configuration = Data(("{" + ordered.joined(separator: ",") + "}").utf8)
        let link = ThemeLink(manifest: Data("{}".utf8), configuration: configuration)

        #expect(throws: ThemeLinkError.tooManyProfiles) {
            try ThemeLink(url: link.link)
        }
    }

    @Test func themeLinksLimitProfilesBeforeConfigurationValueDecoding() throws {
        let sixteen = ThemeLink(manifest: Data("{}".utf8), configuration: profiles(count: 16))
        #expect(try ThemeLink(url: sixteen.link) == sixteen)
        for count in [17, 1_900] {
            let link = ThemeLink(manifest: Data("{}".utf8), configuration: profiles(count: count))

            #expect(throws: ThemeLinkError.tooManyProfiles) {
                try ThemeLink(url: link.link)
            }
        }
    }

    @Test func escapedProfileKeysAndDelimitersInStringsKeepTheProfileLimit() throws {
        let entry = #"{"name":"commas, [ ] { } \" \\ \u0066"}"#
        let other = Array(repeating: "0", count: 17).joined(separator: ",")
        for count in [16, 17] {
            let entries = Array(repeating: entry, count: count).joined(separator: ",")
            let prefix = #"{"label":"profiles","other":["# + other + #"],"pro\u0066iles":["#
            let link = ThemeLink(manifest: Data("{}".utf8), configuration: Data((prefix + entries + "]}").utf8))
            if count == 16 {
                #expect(try ThemeLink(url: link.link) == link)
            } else {
                #expect(throws: ThemeLinkError.tooManyProfiles) { try ThemeLink(url: link.link) }
            }
        }
    }

    @Test(arguments: [
        (ThemeLinkError.tooLong, "This theme link is too long. Install the theme's folder instead, with Open a folder… in the Store."),
        (.unsupportedVersion("3"), "This theme link needs a newer version of StableBar."),
        (.damaged, "This theme link is damaged. Copy it again from the page."),
        (.tooLarge, "This theme is larger than a theme link can carry (128 KB)."),
        (.tooDeep, "This theme nests its settings more than 32 levels deep."),
        (.tooManyProfiles, "This theme has more than 16 profiles, which a theme link can't carry."),
        (.tooManySettings, "This theme has more settings than a link can carry. Install the theme's folder instead, with Open a folder… in the Store."),
        (.indirectBar, "A theme link must set the bar's settings directly, not through a token or setting."),
        (.tooManyReferences, "This theme refers to its own values too many times to open from a link. Install the theme's folder instead, with Open a folder… in the Store."),
        (.barValue("height"), "A theme link can't set the bar's height outside what Settings allows."),
        (.idTaken("Harbour-Test"), "Another package already uses the ID Harbour-Test. Rename the theme on the page.")
    ])
    func themeLinkErrorsExplainWhatHappened(error: ThemeLinkError, message: String) {
        #expect(error.errorDescription == message)
    }

    @Test func barLinksRoundTripTheirPayload() throws {
        let link = try BarLink(payload: Data(contentsOf: fixtures.appending(path: "linked-bar.json")))
        #expect(link.widgets.count == 5)
        #expect(link.packages == [BarLink.Package(id: "weather", version: "1.2.0", settings: ["units": .string("metric")]),
                                  BarLink.Package(id: "uptime", version: "1.0.0", settings: ["interval": .number(300)])])
        #expect(try JSONSerialization.jsonObject(with: link.theme.configuration) is [String: Any])
        let url = try link.url()
        #expect(url.absoluteString.hasPrefix("stablebar://bar?v=1&d="))
        #expect(try BarLink(url: url) == link)
        #expect(try BarLink(url: URL(string: "stablebar://theme?v=1")!) == nil)
        var unlisted = link
        unlisted.widgets.append(["id": .string("hidden"), "type": .string("clock"), "position": .string("left")])
        #expect(try BarLink(url: unlisted.url()) == link)
    }

    @Test func barLinksKeepOnlyHowBuiltInWidgetsLookAndWhereTheySit() {
        let button: ConfigurationValue = .object(["type": .string("button"), "title": .string("Go"), "onClick": .string("say hi")])
        let clock: [String: ConfigurationValue] = [
            "id": .string("clock"), "type": .string("clock"), "position": .string("right"), "format": .string("HH:mm"),
            "onClick": .string("open -a Calendar"), "menu": .array([]), "events": .array([.string("tick")]),
            "environment": .object(["TOKEN": .string("x")]), "display": .string("builtIn"), "popupName": .string("agenda"),
            "popup": .object([
                "style": .object([:]), "onOpen": .string("refresh"),
                "layout": .object(["type": .string("column"), "children": .array([
                    .object(["type": .string("text"), "text": .string("Today")]), button,
                    .object(["type": .string("image"), "path": .string("~/Pictures/me.png")]),
                    .object(["type": .string("list"), "source": .string("events"),
                             "row": .object(["type": .string("text"), "text": .string("x"), "open": .string("https://example.com")])])
                ])])
            ])
        ]
        #expect(BarLink.carried(clock) == [
            "id": .string("clock"), "type": .string("clock"), "position": .string("right"), "format": .string("HH:mm"),
            "popup": .object(["style": .object([:]), "layout": .object(["type": .string("column"), "children": .array([
                .object(["type": .string("text"), "text": .string("Today")])
            ])])])
        ])
        var appleMenu = clock
        appleMenu["type"] = .string("appleMenu")
        appleMenu["click"] = .string("lockScreen")
        appleMenu["popup"] = .object(["style": .object([:]), "layout": button])
        #expect(BarLink.carried(appleMenu)?["click"] == nil)
        #expect(BarLink.carried(appleMenu)?["popup"] == nil)
        var views = clock
        views["popup"] = .object(["views": .object([
            "photo": .object(["type": .string("image"), "path": .string("~/Pictures/me.png")]),
            "week": .object(["type": .string("text"), "text": .string("Week"), "view": .string("photo")])
        ]), "layout": .object(["type": .string("row"), "children": .array([
            .object(["type": .string("text"), "text": .string("Photo"), "view": .string("photo")]),
            .object(["type": .string("text"), "text": .string("Week"), "view": .string("week")])
        ])])])
        #expect(BarLink.carried(views)?["popup"] == .object(["views": .object([
            "week": .object(["type": .string("text"), "text": .string("Week")])
        ]), "layout": .object(["type": .string("row"), "children": .array([
            .object(["type": .string("text"), "text": .string("Photo")]),
            .object(["type": .string("text"), "text": .string("Week"), "view": .string("week")])
        ])])]))
        for type in ["script", "provider", "unknown"] {
            #expect(BarLink.carried(["id": .string("x"), "type": .string(type), "position": .string("left"), "command": .string("x")]) == nil)
        }
    }

    @Test func barLinksBoundTheirLengthSizeNestingAndValues() throws {
        let theme = try BarLink(payload: Data(contentsOf: fixtures.appending(path: "linked-bar.json"))).theme
        func opened(_ change: (inout BarLink) -> Void) throws -> BarLink? {
            var link = BarLink(theme: theme)
            change(&link)
            return try BarLink(url: link.url())
        }
        func nested(_ levels: Int) -> ConfigurationValue {
            (0..<levels).reduce(ConfigurationValue.number(0)) { value, _ in .array([value]) }
        }
        // The root, `widgets` and the widget hold three of the 32 levels.
        _ = try opened { $0.widgets = [["id": .string("x"), "type": .string("text"), "text": .string("x"), "position": .string("left"), "style": nested(29)]] }
        #expect(throws: BarLinkError.tooDeep) { try opened { $0.widgets = [["id": .string("x"), "style": nested(30)]] } }
        // The root and its six keys are seven values.
        _ = try opened { $0.widgetOrder = Array(repeating: "x", count: BarLink.maximumValues - 7) }
        #expect(throws: BarLinkError.tooLarge) { try opened { $0.widgetOrder = Array(repeating: "x", count: BarLink.maximumValues - 6) } }
        #expect(throws: BarLinkError.tooLarge) {
            try opened { $0.theme.configuration = Data(("{" + String(repeating: " ", count: BarLink.maximumBytes) + "}").utf8) }
        }
        let noise = (0..<BarLink.maximumLength).map { _ in String(UInt8.random(in: 0...255), radix: 16) }.joined()
        #expect(throws: BarLinkError.tooLarge) { try opened { $0.widgetOrder = [noise] } }

        let url = try BarLink(theme: theme).url().absoluteString
        #expect(throws: BarLinkError.unsupportedVersion) { try BarLink(url: URL(string: url.replacingOccurrences(of: "v=1", with: "v=2"))!) }
        for damaged in [url.replacingOccurrences(of: "v=1", with: "v=0"), url + "#x", url + "&d=x", "stablebar://bar?v=1&d=AAAA",
                        "stablebar://bar/x?v=1&d=AAAA", "stablebar://bar?v=1"] {
            #expect(throws: BarLinkError.damaged) { try BarLink(url: URL(string: damaged)!) }
        }
        #expect(throws: BarLinkError.damaged) { try BarLink(payload: Data(#"{"package":"{}","config":"{}"}"#.utf8)) }
    }

    private func compressedLink(_ link: ThemeLink) throws -> URL {
        try compressedLink(payload: JSONEncoder().encode(["package": String(decoding: link.manifest, as: UTF8.self),
                                                          "config": String(decoding: link.configuration, as: UTF8.self)]))
    }

    private func compressedLink(payload: Data) throws -> URL {
        let compressed = try (payload as NSData).compressed(using: .zlib) as Data
        return URL(string: "stablebar://theme?v=2&d=" + ThemeLink.encoded(compressed))!
    }

    private func paddedObject(bytes: Int) -> Data {
        Data(("{" + String(repeating: " ", count: bytes - 2) + "}").utf8)
    }

    private func nestedObject(levels: Int, padding: Int = 0) -> Data {
        let arrays = levels - 1
        let content = String(repeating: "[", count: arrays) + "0" + String(repeating: "]", count: arrays)
        return Data((#"{"x":"# + content + String(repeating: " ", count: padding) + "}").utf8)
    }

    private func profiles(count: Int) -> Data {
        let entries = Array(repeating: #"{"name":"x"}"#, count: count).joined(separator: ",")
        return Data((#"{"profiles":["# + entries + "]}").utf8)
    }

    private var fixtures: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "Fixtures")
    }

    private func sample() throws -> Sample {
        try JSONDecoder().decode(Sample.self, from: Data(contentsOf: fixtures.appending(path: "theme-link/sample.json")))
    }

    private struct Sample: Decodable {
        var manifest: String
        var configuration: String
        var link: String

        enum CodingKeys: String, CodingKey {
            case manifest = "package.json", configuration = "config.json", link
        }
    }
}
