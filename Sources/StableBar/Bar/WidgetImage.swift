import SwiftUI

struct WidgetImage: View {
    let path: String
    let fit: ImageFit
    var tinted = false
    @State private var image: NSImage?
    @State private var error = ""
    @Environment(\.offline) private var offline

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).renderingMode(tinted ? .template : .original).resizable().aspectRatio(contentMode: fit == .fill ? .fill : .fit)
            } else {
                Color.clear
            }
        }
        .help(error)
        .task(id: path) {
            image = nil
            error = ""
            if path.isEmpty { return }
            do {
                let url: URL
                if path.hasPrefix("https://") || path.hasPrefix("http://") || path.hasPrefix("file://") {
                    guard let source = URL(string: path) else { throw URLError(.badURL) }
                    url = source
                } else {
                    url = URL(filePath: NSString(string: path).expandingTildeInPath)
                }
                if offline, !url.isFileURL { return }
                if url.isFileURL {
                    let file = try url.resourceValues(forKeys: [.isApplicationKey, .isExecutableKey, .isRegularFileKey, .contentTypeKey])
                    if file.isApplication == true || file.isExecutable == true && file.isRegularFile == true && file.contentType?.conforms(to: .image) != true {
                        image = NSWorkspace.shared.icon(forFile: url.path)
                        return
                    }
                }
                let data: Data
                if url.isFileURL {
                    data = try await Task.detached { try Data(contentsOf: url) }.value
                } else {
                    data = try await URLSession.shared.data(from: url).0
                }
                try Task.checkCancellation()
                image = NSImage(data: data)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
