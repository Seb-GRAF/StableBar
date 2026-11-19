import SwiftUI

/// The selected theme's edits, under the gallery: how many there are, each one, Save as Theme and Revert, and the look
/// values of the main file that apply under every theme.
struct ThemeEditsLine: View {
    let editor: ConfigurationEditor
    let theme: ThemeChoice
    @State private var showsChanges = false
    @State private var showsEveryTheme = false
    @State private var reverting = false
    @State private var naming: SaveAsTheme?

    private var gallery: ThemeGallery { editor.gallery }
    private var edits: ThemeEdits { gallery.edits }
    private var name: String { theme.manifest.name }

    var body: some View {
        if !edits.changes.isEmpty || !edits.everyTheme.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                if !edits.changes.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "pencil").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text("\(Text(name).fontWeight(.semibold)) \(Text("· \(count(edits.changes.count))").foregroundStyle(.secondary))")
                        Spacer(minLength: 8)
                        Button(showsChanges ? "Hide Changes" : "Show Changes") { withAnimation(.snappy) { showsChanges.toggle() } }
                            .buttonStyle(.link)
                        Button("Save as Theme…") { naming = SaveAsTheme(theme: theme, selecting: true) }
                        Button("Revert to \(name)…") { reverting = true }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if showsChanges {
                        ThemeEditList(store: editor.store, changes: edits.changes, theme: name) { change in
                            if let edit = edits.removal(of: [change]) { editor.change(edit, everyBar: editor.themeChangesEveryBar) }
                        } actions: { change in
                            Button("Apply to Every Theme") { editor.change(edits.applyingToEveryTheme(change), everyBar: editor.themeChangesEveryBar) }
                        }
                        .padding(.bottom, 8)
                    }
                }
                if !edits.everyTheme.isEmpty {
                    if !edits.changes.isEmpty { SettingsPalette.separator.frame(height: 1) }
                    HStack(spacing: 10) {
                        Text("\(count(edits.everyTheme.count, of: "setting")) \(edits.everyTheme.count == 1 ? "applies" : "apply") to every theme: \(summary(edits.everyTheme))")
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Button(showsEveryTheme ? "Hide" : "Show") { withAnimation(.snappy) { showsEveryTheme.toggle() } }.buttonStyle(.link)
                        Button("Keep with \(name) Only") {
                            editor.change(edits.keepingWithTheme(edits.everyTheme, name: "\(name) edits"), everyBar: editor.themeChangesEveryBar)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    if showsEveryTheme {
                        ThemeEditList(store: editor.store, changes: edits.everyTheme, theme: name) { change in
                            editor.change(change.removal, everyBar: editor.themeChangesEveryBar)
                        } actions: { change in
                            Button("Keep with \(name) Only") {
                                editor.change(edits.keepingWithTheme([change], name: "\(name) edits"), everyBar: editor.themeChangesEveryBar)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .font(.system(size: 12))
            .controlSize(.small)
            .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.groupBorder))
            .sheet(isPresented: $reverting) {
                RevertThemeSheet(edits: edits, theme: name) {
                    reverting = false
                    naming = SaveAsTheme(theme: theme, selecting: false)
                } revert: {
                    reverting = false
                    if let edit = edits.revertEdit { editor.change(edit, everyBar: editor.themeChangesEveryBar) }
                }
            }
            .sheet(item: $naming) { saving in
                SaveAsThemeSheet(gallery: gallery, saving: saving, everyBar: editor.themeChangesEveryBar) { naming = nil }
            }
        }
    }

    private func count(_ number: Int, of noun: String = "change") -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    private func summary(_ values: [ThemeEdit]) -> String {
        let names = values.prefix(3).map(\.title).joined(separator: ", ")
        return values.count > 3 ? "\(names) and \(values.count - 3) more" : names
    }
}

/// Each edit, by section, with its value, the theme's own value, a revert arrow and `actions`.
private struct ThemeEditList<Actions: View>: View {
    let store: BarStore
    let changes: [ThemeEdit]
    let theme: String
    let revert: (ThemeEdit) -> Void
    @ViewBuilder let actions: (ThemeEdit) -> Actions

    var body: some View {
        let sections = changes.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
        VStack(alignment: .leading, spacing: 2) {
            ForEach(sections, id: \.self) { section in
                Text(section).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 6)
                ForEach(changes.filter { $0.section == section }) { change in
                    HStack(spacing: 8) {
                        Text(change.title).frame(maxWidth: .infinity, alignment: .leading)
                        ThemeEditValue(store: store, value: change.value).frame(width: 170, alignment: .leading)
                        Group {
                            if let value = change.themeValue {
                                HStack(spacing: 4) { Text("\(theme):"); ThemeEditValue(store: store, value: value) }
                            }
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                        Button {
                            revert(change)
                        } label: {
                            Image(systemName: "arrow.uturn.backward").frame(width: 22, height: 22).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Revert \(change.title.lowercased())")
                        .accessibilityLabel("Revert \(change.title)")
                        Menu {
                            actions(change)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("More for \(change.title)")
                    }
                    .frame(minHeight: 24)
                }
            }
        }
        .padding(.horizontal, 14)
    }
}

/// A value as the list shows it: a color as its light and dark swatches, a theme color by name, anything else as text.
private struct ThemeEditValue: View {
    let store: BarStore
    let value: ConfigurationValue

    var body: some View {
        if case let .string(text) = value, text.hasPrefix("@token.") {
            let token = store.themeTokenColors.first { $0.name == text.dropFirst(7) }
            HStack(spacing: 4) {
                if let color = token?.color { swatches(color) }
                Text(token?.title ?? String(text.dropFirst(7))) + Text(" theme").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        } else if let color = try? value.decoded(HexColor.self) {
            HStack(spacing: 4) {
                swatches(color)
                Text(String(format: "#%06X", color.light >> 8) + (color.light == color.dark ? "" : " / " + String(format: "#%06X", color.dark >> 8)))
            }
        } else {
            Text(value.sourceDescription).lineLimit(1)
        }
    }

    private func swatches(_ color: HexColor) -> some View {
        HStack(spacing: 2) {
            ForEach(color.light == color.dark ? [color.light] : [color.light, color.dark], id: \.self) { rgba in
                RoundedRectangle(cornerRadius: 3).fill(HexColor(rgba).color).frame(width: 11, height: 11)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.15)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Asks before removing a theme's edits, and offers to keep them as a theme of their own.
private struct RevertThemeSheet: View {
    let edits: ThemeEdits
    let theme: String
    let saveFirst: () -> Void
    let revert: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sections = edits.changes.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
        VStack(alignment: .leading, spacing: 12) {
            Text("Revert \(theme)?").font(.headline)
            Text("This removes your \(edits.changes.count) \(edits.changes.count == 1 ? "change" : "changes") to \(theme):")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(sections, id: \.self) { section in
                    GridRow {
                        Text(section).foregroundStyle(.secondary).fontWeight(.semibold)
                        Text(edits.changes.filter { $0.section == section }.map(\.title).joined(separator: ", "))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SettingsPalette.groupBorder))
            Text((edits.everyTheme.isEmpty ? "" : "\(edits.everyTheme.map(\.title).formatted(.list(type: .and))) "
                  + "\(edits.everyTheme.count == 1 ? "applies" : "apply") to every theme, so \(edits.everyTheme.count == 1 ? "it stays" : "they stay"). ")
                 + "You can undo this.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Save as Theme…", action: saveFirst)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Revert", action: revert).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct SaveAsTheme: Identifiable {
    let theme: ThemeChoice
    /// Whether the new theme is selected; otherwise the theme it's based on stays selected without its edits.
    let selecting: Bool
    var id: Bool { selecting }
}

private struct SaveAsThemeSheet: View {
    let gallery: ThemeGallery
    let saving: SaveAsTheme
    let everyBar: Bool
    let close: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save as Theme").font(.headline)
            TextField("Name", text: $name).frame(width: 360)
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task { await gallery.save(saving.theme, as: name, everyBar: everyBar, selecting: saving.selecting) }
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding(24)
        .onAppear {
            let manifest = saving.theme.manifest
            name = saving.theme.isBundled || manifest.repository != nil ? "My \(manifest.name)" : manifest.name
        }
    }
}
