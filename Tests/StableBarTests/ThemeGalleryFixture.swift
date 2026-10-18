import Foundation
@testable import StableBar

struct ThemeGalleryFixture {
    let directory: URL
    var url: URL { directory.appending(path: "config.json") }
    var packages: WidgetPackageStore { WidgetPackageStore(directory: directory.appending(path: "packages")) }
    var themes: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Resources/themes")
    }

    init(_ json: String = #"{"widgets":[]}"#) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try write(json, to: url)
    }

    func close() { try? FileManager.default.removeItem(at: directory) }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func document() throws -> [String: ConfigurationValue] {
        try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(contentsOf: url))
    }

    func theme(_ configuration: String, id: String = "test-theme", install: Bool = true) throws -> ThemeChoice {
        let source = directory.appending(path: "sources/\(id)")
        try write(#"{"id":"\#(id)","name":"Test theme","version":"1","kind":"theme","entry":"config.json"}"#,
                  to: source.appending(path: "package.json"))
        try write(configuration, to: source.appending(path: "config.json"))
        if install {
            let inspection = try packages.install(source)
            return ThemeChoice(manifest: inspection.manifest, directory: inspection.directory, isBundled: false)
        }
        return ThemeChoice(manifest: try packages.manifest(at: source), directory: source, isBundled: false)
    }

    @MainActor func store() throws -> BarStore {
        let store = BarStore(configurationURL: url, themesDirectory: themes)
        var loader = ConfigurationLoader()
        loader.themesDirectory = themes
        store.configuration = try loader.load(url)
        store.effectiveDocument = loader.document
        store.origins = loader.origins
        store.widgetPackageNames = loader.widgetPackageNames
        store.activeProfiles = loader.activeProfiles
        store.preparePresentations()
        return store
    }
}
