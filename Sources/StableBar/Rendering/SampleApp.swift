import AppKit

/// An app as a render shows it: the name and icon of its bundle, whether it runs or not, so a render
/// doesn't depend on the apps running on the Mac that draws it.
final class SampleApp: NSRunningApplication, @unchecked Sendable {
    private let name: String?
    private let image: NSImage?
    private let identifier: String

    init(bundleIdentifier: String) {
        identifier = bundleIdentifier
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        let bundle = url.flatMap(Bundle.init(url:))
        name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? bundle?.object(forInfoDictionaryKey: "CFBundleName")) as? String
        image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        super.init()
    }

    override var localizedName: String? { name }
    override var icon: NSImage? { image }
    override var bundleIdentifier: String? { identifier }
}
