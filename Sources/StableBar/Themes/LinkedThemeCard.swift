import SwiftUI

struct LinkedThemeCard: View {
    let candidate: ThemeLinkCandidate
    let editor: ConfigurationEditor
    var screen: ScreenKind? = nil
    var everyBar = false
    @State private var using = false

    private var gallery: ThemeGallery { editor.gallery }
    private var name: String { candidate.choice.manifest.name }
    private var trying: Bool { candidate.state == .trying }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 14, weight: .semibold))
                    if let author = candidate.choice.manifest.author {
                        Text("by \(author)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Label(trying ? "Trying on your bar" : "From a link", systemImage: trying ? "eye" : "link")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(trying ? Color.accentColor : .secondary)
            }
            if let description = candidate.choice.manifest.description {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            preview
            switch candidate.state {
            case .ready, .trying:
                if let error = gallery.error(for: candidate.choice.linkedPreviewKey) {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    Text(trying ? "Cancel returns to your saved theme." : "Your bar hasn’t changed.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 10)
                    if trying {
                        Button("Cancel", action: cancelTrial)
                            .accessibilityLabel("Cancel trying \(name)")
                        Button("Keep", action: use)
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("Keep \(name)")
                    } else {
                        Button("Dismiss", action: dismiss).buttonStyle(.link)
                            .accessibilityLabel("Dismiss \(name)")
                        Button("Try on Bar") {
                            candidate.tryOnBar()
                            gallery.contextChanged()
                        }
                        Button("Use theme", action: use).buttonStyle(.borderedProminent)
                    }
                }
            case let .failed(message):
                HStack {
                    Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    Spacer(minLength: 10)
                    Button("Dismiss", action: dismiss).buttonStyle(.link)
                        .accessibilityLabel("Dismiss \(name)")
                }
            case .used: EmptyView()
            }
        }
        .padding(14)
        .modifier(LinkedThemeCardStyle())
        .disabled(using)
    }

    private var preview: some View {
        GeometryReader { geometry in
            if let look = gallery.previews[candidate.choice.linkedPreviewKey]?.configuration(for: gallery.previewAppearance) {
                ThemeSampleBar(look: look)
                    .frame(width: geometry.size.width / 0.8)
                    .scaleEffect(0.8)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .frame(height: 56)
        .background(SampleWallpaper())
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SettingsPalette.groupBorder))
        .environment(\.colorScheme, gallery.previewAppearance.colorScheme)
    }

    private func use() {
        using = true
        Task {
            await useTheme()
            using = false
        }
    }

    func useTheme() async {
        await candidate.use(on: screen, everyBar: everyBar)
        if candidate.state == .used { gallery.dismissLinkedTheme(candidate) }
        else { gallery.contextChanged() }
    }

    func cancelTrial() {
        candidate.cancelTrial()
        gallery.contextChanged()
    }

    func dismiss() { gallery.dismissLinkedTheme(candidate) }
}

struct LinkedThemeErrorCard: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            Spacer(minLength: 10)
            Button("Dismiss", action: dismiss).buttonStyle(.link)
        }
        .padding(14)
        .modifier(LinkedThemeCardStyle())
    }
}

struct LinkedThemeCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.accentColor.opacity(0.45)))
    }
}
