import AppKit
import SwiftUI

enum PackageDetailTab {
    case overview, settings, access, versions
}

struct PackageDetailView: View {
    let store: BarStore
    let library: PackageLibrary
    let draft: PackageDraft
    let reviewing: Bool
    @Binding var tab: PackageDetailTab
    @Binding var additions: [String]
    var onEnable: ((WidgetPackageInspection, [String: ConfigurationValue]) throws -> Void)?
    var onAdded: (() -> Void)?
    var onWorkingChanged: ((Bool) -> Void)?
    @State private var confirmingRemoval = false
    @State private var uninstalling: WidgetPackageManifest?
    @State private var showingCommands = false

    var body: some View {
        let manifest = draft.inspection.manifest
        VStack(spacing: 0) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        if !reviewing {
                            SettingsSegments(selection: $tab, options: [(.overview, "Overview"), (.settings, "Settings"), (.access, "Access"), (.versions, "Versions")],
                                             stretches: false)
                                .fixedSize()
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                if reviewing {
                    overview
                    settings
                    access
                } else {
                    switch tab {
                    case .overview: overview
                    case .settings: settings
                    case .access: access
                    case .versions: versions
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .disabled(draft.working || library.updating.contains(manifest.id))
            if let error = draft.error ?? draft.credentialsError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .textSelection(.enabled).font(.callout).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .confirmationDialog("Review additional access", isPresented: Binding(get: { !additions.isEmpty }, set: { if !$0 { additions = [] } })) {
            Button("Add to bar") {
                draft.working = true
                onWorkingChanged?(true)
                Task { await add(draft) }
            }
        } message: {
            Text("This version adds:\n\(additions.joined(separator: "\n"))")
        }
        .confirmationDialog(manifest.kind == .theme ? "Use the built-in theme?" : "Remove \(manifest.name) from the bar?", isPresented: $confirmingRemoval) {
            Button(manifest.kind == .theme ? "Use Built-in" : "Remove from bar") { library.deactivate(draft) }
        } message: {
            Text(manifest.kind == .theme ? "The built-in theme will replace this theme. Its files and settings stay available." : "All widgets from this package will be removed from the bar. Its files, settings and saved credentials stay available.")
        }
        .confirmationDialog(uninstalling.map { "Uninstall \($0.name) \($0.version)?" } ?? "",
                            isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } }),
                            presenting: uninstalling) { version in
            Button("Uninstall version", role: .destructive) { Task { await library.uninstall(version) } }
        } message: { _ in
            Text("This version’s files will be deleted and its widgets removed from the bar if active. Other versions, settings and saved credentials are kept. This cannot be undone.")
        }
    }

    private var header: some View {
        let manifest = draft.inspection.manifest
        let source = library.source(draft)
        let byline = manifest.author.map { "by \($0) · " } ?? ""
        return HStack(spacing: 10) {
            PackageIcon(id: manifest.id, name: manifest.name)
            VStack(alignment: .leading, spacing: 3) {
                Text(manifest.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    if let source { PackageSourceBadge(source: source) }
                    Text(byline + manifest.version).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            ProgressView().controlSize(.small).opacity(draft.working || draft.checking ? 1 : 0)
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        let manifest = draft.inspection.manifest
        let update = reviewing ? nil : library.update(for: manifest)
        Group {
            if let update {
                Button(library.updating.contains(manifest.id) ? "Updating…" : "Update to \(update.version)") { Task { await library.update(manifest) } }
                    .disabled(library.updating.contains(manifest.id))
                    .buttonStyle(.borderedProminent)
            }
            if library.isActive(draft) && !reviewing {
                if manifest.kind != .theme && library.shownWidgets(draft) == 0 {
                    Button("Show widgets") { requestAdd(draft) }.buttonStyle(.borderedProminent)
                }
                Button(manifest.kind == .theme ? "Use Built-in" : "Remove from bar…") { confirmingRemoval = true }
            } else if update == nil {
                Button(manifest.kind == .theme ? "Use theme" : "Add to bar") { requestAdd(draft) }.buttonStyle(.borderedProminent)
            } else {
                Button(manifest.kind == .theme ? "Use theme" : "Add to bar") { requestAdd(draft) }
            }
        }
        .disabled(draft.working || draft.checking)
    }

    @ViewBuilder private var overview: some View {
        let manifest = draft.inspection.manifest
        Section {
            switch library.source(draft) {
            case .store?:
                row("bag", "The StableBar Store", hint: (manifest.author.map { "By \($0). " } ?? "")
                    + "Built and published by the Store, not by its author."
                    + (draft.inspection.commands.isEmpty ? "" : " A maintainer read this version before it was published.")) {
                    PackageSourceBadge(source: .store)
                }
            case .listed?:
                row("bag", "Listed in the Store", hint: "\(path). This package ID is in the Store. This installed copy’s source isn’t recorded.") {
                    PackageSourceBadge(source: .listed)
                }
            case .local?:
                row("folder", "A folder on this Mac", hint: "\(path). StableBar doesn’t review local folders.") {
                    PackageSourceBadge(source: .local)
                }
            default:
                row("folder", "On this Mac", hint: "\(path). The installation source isn’t recorded.") {
                    PackageSourceBadge(source: .installed)
                }
            }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.open(draft.inspection.directory) }
                if let repository = manifest.repository { Link("Package source", destination: repository) }
            }
        } header: {
            VStack(alignment: .leading, spacing: 12) {
                if draft.screenshotData != nil || draft.themePreview != nil || !draft.inspection.widgets.isEmpty {
                    let appearance = store.configuration?.bar.appearance ?? (store.context.appearance == "dark" ? BarAppearance.dark : .light)
                    PackagePreview(screenshotData: draft.screenshotData, look: draft.themePreview?.configuration(for: appearance), widgets: draft.inspection.widgets)
                        .frame(height: 150)
                        .environment(\.colorScheme, appearance.colorScheme)
                }
                if let description = manifest.description {
                    Text(description).font(.system(size: 13)).foregroundStyle(.primary)
                }
                Text("Where it comes from")
            }
        }
        if !draft.inspection.widgets.isEmpty {
            Section {
                ForEach(draft.inspection.widgets) { widget in
                    row(widget.content.symbol, WidgetDisplayName.title(for: widget.content), hint: widget.id) {
                        if store.configuration?.widgets.contains(where: { $0.id == widget.id && $0.enabled }) == true {
                            Text("On your bar").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Includes")
            } footer: {
                if draft.inspection.widgets.count > 1 {
                    Text("Some may depend on the active profile. Show or hide each one in Bar.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var settings: some View {
        let manifest = draft.inspection.manifest
        let active = library.isActive(draft) && !reviewing
        if !manifest.settings.isEmpty {
            Section {
                PackageSettingsFields(draft: draft, set: { name, value in library.setSetting(name, value: value, in: draft) })
            } header: {
                Text(manifest.kind == .theme ? "Theme settings" : "Shared by its widgets")
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    if !active {
                        Text("Settings apply when you add this package. Your draft stays here while you browse.")
                    } else if manifest.settings.values.contains(where: { $0.type == "secret" }) {
                        Text("Settings save automatically. Credentials need Save credentials.")
                    } else {
                        Text("Settings save automatically.")
                    }
                    Spacer()
                    if active && !draft.secrets.isEmpty {
                        Button("Save credentials") { Task { await library.saveCredentials(draft) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(draft.working || draft.checking)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else if !reviewing {
            Section { Text("This package has no settings.").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var access: some View {
        let manifest = draft.inspection.manifest
        let commands = draft.inspection.commands
        let missing = manifest.missingTools(path: shellEnvironment.withLock { $0["PATH", default: ""] })
        Section("What it can do") {
            LabeledContent {
                if !commands.isEmpty && !reviewing {
                    Button(showingCommands ? "Hide" : "Show") { showingCommands.toggle() }.controlSize(.small)
                }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(commands.isEmpty ? "Runs no commands" : commands.count == 1 ? "Runs 1 command while it’s on your bar"
                             : "Runs \(commands.count) commands while it’s on your bar")
                        if !commands.isEmpty && (showingCommands || reviewing) {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(commands, id: \.self) { Text($0) }
                            }
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SettingsPalette.groupBorder))
                        }
                    }
                } icon: { Image(systemName: "terminal") }
            }
            row("lock", manifest.permissions.isEmpty ? "Needs no macOS permissions"
                : "Uses \(manifest.permissions.map(\.rawValue.capitalized).formatted(.list(type: .and))) access")
            row("globe", manifest.hosts.isEmpty ? "Doesn’t go online" : "Connects to \(manifest.hosts.formatted(.list(type: .and)))")
            ForEach(manifest.requires, id: \.self) { tool in
                row("wrench.and.screwdriver", "Needs \(tool)") {
                    if missing.contains(tool) {
                        Label("Missing", systemImage: "exclamationmark.triangle.fill").foregroundStyle(SettingsPalette.warning)
                    } else {
                        Label("Found", systemImage: "checkmark").foregroundStyle(SettingsPalette.success)
                    }
                }
            }
            if let minimum = manifest.minimumVersion {
                row("app.badge.checkmark", "Needs StableBar \(minimum) or later")
            }
            switch library.source(draft) {
            case .store?:
                row("checkmark.shield", commands.isEmpty ? "The Store checked that it runs no commands" : "A maintainer read this version") {
                    Label(commands.isEmpty ? "Checked" : "Reviewed", systemImage: "checkmark").foregroundStyle(SettingsPalette.success)
                }
            case .listed?, .installed?:
                row("shield", "Review status unknown", hint: "This installed copy’s review status isn’t recorded.")
            case .local?:
                row("shield", "StableBar doesn’t review local folders") {
                    Text("Local folder").foregroundStyle(SettingsPalette.warning)
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var versions: some View {
        let manifest = draft.inspection.manifest
        let installed = library.installed.filter { $0.id == manifest.id }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        Section {
            if let newest = installed.first, let update = library.update(for: newest) {
                LabeledContent(update.version) {
                    HStack {
                        Text("New in the Store").font(.caption).foregroundStyle(.secondary)
                        Button(library.updating.contains(manifest.id) ? "Updating…" : "Update") { Task { await library.update(manifest) } }
                            .buttonStyle(.borderedProminent).disabled(library.updating.contains(manifest.id))
                    }
                }
            }
            ForEach(installed, id: \.version) { version in
                LabeledContent(version.version) {
                    HStack {
                        if library.isActive(version) {
                            PackageTag(title: "In use", tint: SettingsPalette.success)
                        } else {
                            Button("Use") { use(version) }
                        }
                        Button("Uninstall…") { uninstalling = version }
                    }
                }
            }
            if installed.isEmpty {
                Text("Not installed yet.").foregroundStyle(.secondary)
            }
            LabeledContent("Package ID") { Text(manifest.id).textSelection(.enabled) }
        } header: {
            Text("Versions")
        } footer: {
            Text("Versions stay pinned until you choose another. Your compatible settings carry over.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var path: String {
        draft.inspection.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func row(_ symbol: String, _ title: String, hint: String? = nil) -> some View {
        row(symbol, title, hint: hint) { EmptyView() }
    }

    private func row<Trailing: View>(_ symbol: String, _ title: String, hint: String? = nil,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        LabeledContent {
            trailing()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                }
                .textSelection(.enabled)
            } icon: { Image(systemName: symbol) }
        }
    }

    private func use(_ version: WidgetPackageManifest) {
        Task {
            await library.selectInstalled(version)
            if let draft = library.draft { requestAdd(draft) }
        }
    }

    private func requestAdd(_ draft: PackageDraft) {
        draft.working = true
        onWorkingChanged?(true)
        Task {
            do {
                additions = try await library.accessChanges(draft)
                if additions.isEmpty {
                    await add(draft)
                } else {
                    draft.working = false
                    onWorkingChanged?(false)
                }
            } catch {
                draft.error = errorMessage(error)
                draft.working = false
                onWorkingChanged?(false)
            }
        }
    }

    private func add(_ draft: PackageDraft) async {
        await library.add(draft, onEnable: onEnable)
        onWorkingChanged?(false)
        if draft.error == nil && draft.credentialsError == nil { onAdded?() }
    }
}

struct BuiltInPackagesView: View {
    let store: BarStore
    let gallery: ThemeGallery
    let search: String
    @State private var setup: WidgetSetup

    init(store: BarStore, gallery: ThemeGallery, search: String) {
        self.store = store
        self.gallery = gallery
        self.search = search
        _setup = State(initialValue: WidgetSetup(store: store))
    }

    var body: some View {
        let widgets = WidgetAddCatalog.builtIns.filter { $0.matches(search) }
        let themes = gallery.choices.filter { $0.isBundled && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                BuiltInIcon()
                VStack(alignment: .leading, spacing: 5) {
                    Text("StableBar Essentials").font(.system(size: 17, weight: .semibold))
                    HStack(spacing: 6) {
                        PackageSourceBadge(source: .included)
                        Text("Widgets and themes by StableBar").lineLimit(1)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Ready to use. Included with the app and kept up to date with StableBar.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Widgets").font(.system(size: 14, weight: .semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                            ForEach(widgets) { choice in
                                VStack(alignment: .leading, spacing: 12) {
                                    let widget = try! ConfigurationValue.object(choice.add(position: .right, id: choice.id)!.properties!).decoded(WidgetConfiguration.self)
                                    PackagePreview(screenshotData: nil, look: nil, widgets: [widget]).frame(height: 64)
                                    HStack(spacing: 10) {
                                        Image(systemName: choice.symbol)
                                            .font(.system(size: 17))
                                            .frame(width: 38, height: 38)
                                            .background(SettingsPalette.control, in: RoundedRectangle(cornerRadius: 10))
                                        Text(choice.name).font(.system(size: 13, weight: .medium))
                                        Spacer(minLength: 0)
                                    }
                                    Text(choice.description)
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                        .lineLimit(2, reservesSpace: true)
                                    HStack {
                                        PackageSourceBadge(source: .included)
                                        Spacer()
                                        Button("Add to bar") {
                                            setup.beginSheet()
                                            Task {
                                                if await setup.add(choice, to: .right) != nil {
                                                    store.customizationHistory.showNotice("\(choice.name) added to the right side of your bar.")
                                                }
                                            }
                                        }
                                        .controlSize(.small)
                                        .disabled(setup.isAdding)
                                        .accessibilityLabel("Add \(choice.name) to bar")
                                    }
                                }
                                .padding(14)
                                .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(SettingsPalette.groupBorder))
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Themes").font(.system(size: 14, weight: .semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                            ForEach(themes, id: \.key) { choice in
                                VStack(alignment: .leading, spacing: 6) {
                                    ThemeCard(title: choice.title, look: gallery.previews[choice.key]?.configuration(for: gallery.previewAppearance),
                                              appearance: gallery.previewAppearance, isSelected: choice.key == gallery.selectedKey,
                                              error: gallery.error(for: choice.key), source: .included) { gallery.select(choice) }
                                    if let error = gallery.error(for: choice.key) {
                                        Text(error).font(.caption).foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                    }
                    if let error = setup.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
        }
    }
}

struct PackagePreview: View {
    let screenshotData: Data?
    let look: Configuration?
    var widgets: [WidgetConfiguration] = []

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let screenshotData, let image = NSImage(data: screenshotData) {
                    Image(nsImage: image).resizable().scaledToFit().padding(8)
                } else if let look {
                    ThemeSampleBar(look: look)
                        .frame(width: geometry.size.width * 1.5)
                        .scaleEffect(2 / 3)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if !widgets.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { ForEach(widgets) { WidgetSample(widget: $0) } }
                        WidgetSample(widget: widgets[0])
                    }
                    .padding(12)
                } else {
                    Label("Preview unavailable", systemImage: "photo")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            if look != nil { SampleWallpaper() } else { SettingsPalette.field }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

struct PackageIcon: View {
    let id: String
    let name: String

    var body: some View {
        Text(name.prefix(1).uppercased())
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color(hue: Double(id.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360,
                              saturation: 0.5, brightness: 0.78),
                        in: RoundedRectangle(cornerRadius: 8))
    }
}

struct BuiltInIcon: View {
    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(.gray, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PackageTag: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
    }
}
