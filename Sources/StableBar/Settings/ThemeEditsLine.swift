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

/// Each edit, by section, in columns: its value, the theme's own value, a revert arrow and `actions`.
private struct ThemeEditList<Actions: View>: View {
    let store: BarStore
    let changes: [ThemeEdit]
    let theme: String
    let revert: (ThemeEdit) -> Void
    @ViewBuilder let actions: (ThemeEdit) -> Actions

    var body: some View {
        let sections = changes.reduce(into: [String]()) { if !$0.contains($1.section) { $0.append($1.section) } }
        let tokens = store.themeTokenColors
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                Color.clear.frame(height: 1)
                Text("Yours").frame(width: 130, alignment: .leading)
                Text(theme).lineLimit(1).frame(width: 130, alignment: .leading)
                Color.clear.frame(width: 46, height: 1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            ForEach(sections, id: \.self) { section in
                Text(section)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .gridCellColumns(4)
                ForEach(changes.filter { $0.section == section }) { change in
                    GridRow {
                        Text(change.title).lineLimit(1).truncationMode(.middle).help(change.title)
                        ThemeEditValue(value: change.value, tokens: tokens).frame(width: 130, alignment: .leading)
                        Group {
                            if let value = change.themeValue {
                                ThemeEditValue(value: value, tokens: tokens)
                            } else {
                                Text("—").foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 130, alignment: .leading)
                        HStack(spacing: 2) {
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
                    }
                }
            }
        }
        .padding(.horizontal, 14)
    }
}

/// A value in one line: a color as its swatches, with a theme color's name or a single color's hex, anything else as
/// short text. The whole value is in its help.
private struct ThemeEditValue: View {
    let value: ConfigurationValue
    let tokens: [ThemeTokenColor]

    var body: some View {
        HStack(spacing: 5) {
            if let sides = colorSides(value) {
                HStack(spacing: 2) {
                    ForEach(Array(sides.enumerated()), id: \.offset) { _, rgba in
                        RoundedRectangle(cornerRadius: 3).fill(HexColor(rgba).color).frame(width: 12, height: 12)
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.primary.opacity(0.15)))
                    }
                }
                .accessibilityHidden(true)
                if case let .string(text) = value, text.hasPrefix("@token.") {
                    Text(tokens.first { $0.name == text.dropFirst(7) }?.title ?? String(text.dropFirst(7)))
                } else if sides.count == 1 {
                    Text(String(format: "#%06X", sides[0] >> 8)).monospacedDigit()
                }
            } else {
                Text(text)
            }
        }
        .lineLimit(1)
        .help(value.sourceDescription)
    }

    /// A color's light and dark sides, one when they match, with theme colors resolved.
    private func colorSides(_ value: ConfigurationValue) -> [UInt32]? {
        func color(_ side: ConfigurationValue) -> HexColor? {
            if case let .string(text) = side, text.hasPrefix("@token.") { return tokens.first { $0.name == text.dropFirst(7) }?.color }
            return try? side.decoded(HexColor.self)
        }
        if case let .object(pair) = value, Set(pair.keys) == ["light", "dark"],
           let light = color(pair["light"]!)?.light, let dark = color(pair["dark"]!)?.dark {
            return light == dark ? [light] : [light, dark]
        }
        return color(value).map { $0.light == $0.dark ? [$0.light] : [$0.light, $0.dark] }
    }

    private var text: String {
        switch value {
        case .null: "None"
        case .object where value.isGradient: "Gradient"
        case .object, .array: "Custom"
        default: value.sourceDescription
        }
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
