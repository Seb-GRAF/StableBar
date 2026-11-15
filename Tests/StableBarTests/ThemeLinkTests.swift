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
        ("v=2&package=e30&config=e30", .unsupportedVersion("2")),
        ("v=3&package=e30&config=e30", .unsupportedVersion("3")),
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

    @Test func themeLinksOverTheLimitsAreRefused() {
        let prefix = "stablebar://theme?"
        let longLink = prefix + String(repeating: "x", count: 65_537 - prefix.utf8.count)
        #expect(longLink.utf8.count == 65_537)
        #expect(throws: ThemeLinkError.tooLong) { try ThemeLink(url: URL(string: longLink)!) }

        let large = ThemeLink(manifest: paddedObject(bytes: 20_000), configuration: paddedObject(bytes: 13_000))
        #expect(large.link.absoluteString.utf8.count < 65_536)
        #expect(throws: ThemeLinkError.tooLarge) { try ThemeLink(url: large.link) }

        let deep = ThemeLink(manifest: Data("{}".utf8), configuration: nestedObject(levels: 33))
        #expect(throws: ThemeLinkError.tooDeep) { try ThemeLink(url: deep.link) }
    }

    @Test func themeLinksAtTheLimitsAreAccepted() throws {
        #expect(ThemeLink.maximumLength == 65_536)
        #expect(ThemeLink.maximumFileBytes == 32_768)
        #expect(ThemeLink.maximumDepth == 32)

        let link = ThemeLink(manifest: Data("{}".utf8), configuration: Data("{}".utf8))
        let prefix = link.link.absoluteString + "&x="
        let maximumLength = prefix + String(repeating: "x", count: 65_536 - prefix.utf8.count)
        #expect(try ThemeLink(url: URL(string: maximumLength)!) == link)

        let maximumBytes = ThemeLink(manifest: paddedObject(bytes: 20_000), configuration: paddedObject(bytes: 12_768))
        #expect(try ThemeLink(url: maximumBytes.link) == maximumBytes)

        let maximumDepth = ThemeLink(manifest: Data("{}".utf8), configuration: nestedObject(levels: 32))
        #expect(try ThemeLink(url: maximumDepth.link) == maximumDepth)
    }

    @Test(arguments: [false, true])
    func deeplyNestedFilesAreRefusedBeforeConfigurationValueDecoding(inManifest: Bool) {
        let nested = nestedObject(levels: 501, padding: 30_800)
        let empty = Data("{}".utf8)
        let link = ThemeLink(manifest: inManifest ? nested : empty, configuration: inManifest ? empty : nested)
        #expect(nested.count < 32_768)
        #expect(link.link.absoluteString.utf8.count < 65_536)
        #expect(throws: ThemeLinkError.tooDeep) { try ThemeLink(url: link.link) }
        var reachedDecoder = false
        #expect(throws: ThemeLinkError.tooDeep) {
            try ThemeLink(url: link.link, decode: { _ in
                reachedDecoder = true
                return .object([:])
            })
        }
        #expect(!reachedDecoder)
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
            var reachedDecoder = false
            #expect(throws: ThemeLinkError.damaged) {
                try ThemeLink(url: link.link, decode: { _ in
                    reachedDecoder = true
                    return .object([:])
                })
            }
            #expect(!reachedDecoder)
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
        #expect(link.configuration.count < 32_768)
        var reachedDecoder = false
        #expect(throws: ThemeLinkError.tooDeep) {
            try ThemeLink(url: link.link, decode: { _ in
                reachedDecoder = true
                return .object([:])
            })
        }
        #expect(!reachedDecoder)
    }

    @Test(arguments: [false, true])
    func duplicateJSONKeysCannotHideDeepValues(deepValueFirst: Bool) throws {
        let nested = try #require(String(data: nestedObject(levels: 40), encoding: .utf8))
        let entries = [#""x":"# + nested, #""x":null"#]
        let ordered = deepValueFirst ? entries : entries.reversed().map { $0 }
        let configuration = Data(("{" + ordered.joined(separator: ",") + "}").utf8)
        let link = ThemeLink(manifest: Data("{}".utf8), configuration: configuration)
        var reachedDecoder = false
        #expect(throws: ThemeLinkError.tooDeep) {
            try ThemeLink(url: link.link, decode: { _ in
                reachedDecoder = true
                return .object([:])
            })
        }
        #expect(!reachedDecoder)
    }

    @Test(arguments: [false, true])
    func duplicateJSONKeysCannotHideExtraProfiles(extraProfilesFirst: Bool) throws {
        let extra = try #require(String(data: profiles(count: 17), encoding: .utf8))
        let entries = [String(extra.dropFirst().dropLast()), #""profiles":[]"#]
        let ordered = extraProfilesFirst ? entries : entries.reversed().map { $0 }
        let configuration = Data(("{" + ordered.joined(separator: ",") + "}").utf8)
        let link = ThemeLink(manifest: Data("{}".utf8), configuration: configuration)
        var reachedDecoder = false
        #expect(throws: ThemeLinkError.tooManyProfiles) {
            try ThemeLink(url: link.link, decode: { _ in
                reachedDecoder = true
                return .object([:])
            })
        }
        #expect(!reachedDecoder)
    }

    @Test func themeLinksLimitProfilesBeforeConfigurationValueDecoding() throws {
        let sixteen = ThemeLink(manifest: Data("{}".utf8), configuration: profiles(count: 16))
        #expect(try ThemeLink(url: sixteen.link) == sixteen)
        for count in [17, 1_900] {
            let link = ThemeLink(manifest: Data("{}".utf8), configuration: profiles(count: count))
            var reachedDecoder = false
            #expect(throws: ThemeLinkError.tooManyProfiles) {
                try ThemeLink(url: link.link, decode: { _ in
                    reachedDecoder = true
                    return .object([:])
                })
            }
            #expect(!reachedDecoder)
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
        (ThemeLinkError.tooLong, "This theme link is too long. Download the theme as a zip from the page instead."),
        (.unsupportedVersion("2"), "This theme link needs a newer version of StableBar."),
        (.damaged, "This theme link is damaged. Copy it again from the page."),
        (.tooLarge, "This theme is larger than a theme link can carry (32 KB)."),
        (.tooDeep, "This theme nests its settings more than 32 levels deep."),
        (.tooManyProfiles, "This theme has more than 16 profiles, which a theme link can't carry."),
        (.indirectBar, "A theme link must set the bar's settings directly, not through a token or setting."),
        (.tooManyReferences, "This theme refers to its own values too many times to open from a link. Download it as a zip instead."),
        (.idTaken("Harbour-Test"), "Another package already uses the ID Harbour-Test. Rename the theme on the page.")
    ])
    func themeLinkErrorsExplainWhatHappened(error: ThemeLinkError, message: String) {
        #expect(error.errorDescription == message)
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
