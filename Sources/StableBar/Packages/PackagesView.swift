import AppKit
import SwiftUI

struct PackagesView: View {
    let store: BarStore
    var selectedPackageID: String?
    var reviewing: WidgetPackageInspection?
    /// The source the reviewed package is added from; nil for a folder.
    var reviewingSourceID: String?
    /// The settings the review starts from, in place of the ones the bar has saved for the package.
    var reviewingSettings: [String: ConfigurationValue]?
    var onEnable: ((WidgetPackageInspection, [String: ConfigurationValue]) throws -> Void)?
    var onAdded: (() -> Void)?
    var onWorkingChanged: ((Bool) -> Void)?
    @Binding var searchTarget: String?
    @State private var library: PackageLibrary
    @State private var tab: PackageDetailTab
    @State private var additions: [String] = []
    @State private var gallery: ThemeGallery
    @State private var setup: WidgetSetup
    @State private var showsLoading = false
    @State private var showingSources = false
    @State private var uninstalling: WidgetPackageManifest?
    @State private var sourceLink: PackageSourceLink?
    @FocusState private var searching: Bool

    init(store: BarStore, indexURL: URL = PackageIndex.url, selectedPackageID: String? = nil,
         reviewing: WidgetPackageInspection? = nil, reviewingSourceID: String? = nil,
         reviewingSettings: [String: ConfigurationValue]? = nil,
         onEnable: ((WidgetPackageInspection, [String: ConfigurationValue]) throws -> Void)? = nil,
         onAdded: (() -> Void)? = nil, onWorkingChanged: ((Bool) -> Void)? = nil,
         searchTarget: Binding<String?> = .constant(nil)) {
        self.store = store
        self.selectedPackageID = selectedPackageID
        self.reviewing = reviewing
        self.reviewingSourceID = reviewingSourceID
        self.reviewingSettings = reviewingSettings
        self.onEnable = onEnable
        self.onAdded = onAdded
        self.onWorkingChanged = onWorkingChanged
        _searchTarget = searchTarget
        _gallery = State(initialValue: ThemeGallery(store: store))
        _setup = State(initialValue: WidgetSetup(store: store))
        _tab = State(initialValue: selectedPackageID == nil ? .overview : .settings)
        if reviewing != nil || indexURL != PackageIndex.url {
            let packages = WidgetPackageStore(directory: store.configurationStore.configurationURL.deletingLastPathComponent().appending(path: "packages"))
            // A review shares the app's client, which knows the private source it installs for.
            let client = indexURL == PackageIndex.url ? nil : PackageStoreClient(packages: packages, indexURL: indexURL)
            _library = State(initialValue: PackageLibrary(store: store, client: client, reviewing: reviewing != nil))
        } else {
            _library = State(initialValue: store.packageLibrary)
        }
    }

    var body: some View {
        Group {
            if reviewing != nil {
                detail
            } else {
                let items = catalog
                let owned = Set(library.installedPackages.map(\.id))
                VStack(spacing: 0) {
                    topBar
                    Divider()
                    HStack(spacing: 0) {
                        sidebar(items, owned: owned)
                            .frame(width: 200)
                            .background(SettingsPalette.sidebar)
                            .disabled(busy)
                        Divider()
                        if library.draft != nil || library.loading {
                            VStack(alignment: .leading, spacing: 0) {
                                Button("Store", systemImage: "chevron.left") { library.deselect() }
                                    .buttonStyle(.borderless)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .disabled(busy)
                                Divider()
                                detail
                            }
                        } else {
                            storeList(items, owned: owned).disabled(busy)
                        }
                    }
                }
            }
        }
        .task {
            await library.loadInstalled()
            if let reviewing {
                await library.select(reviewing.directory, sourceID: reviewingSourceID, settings: reviewingSettings)
            } else {
                await gallery.refresh()
                if let selectedPackageID {
                    await library.selectPackage(selectedPackageID)
                }
                await library.loadStore()
                if let selectedPackageID, library.draft?.inspection.manifest.id != selectedPackageID {
                    await library.selectPackage(selectedPackageID)
                }
            }
        }
        .task(id: searchTarget) {
            if let target = searchTarget {
                if target != SettingsSearchResult.packageSources.id {
                    library.filter = target == SettingsSearchResult.library.id ? .installed : .all
                    library.deselect()
                }
                showingSources = target == SettingsSearchResult.packageSources.id
                searchTarget = nil
            }
        }
        .confirmationDialog("Review additional access", isPresented: Binding(get: { library.pendingUpdate != nil }, set: { if !$0 { library.pendingUpdate = nil } }),
                            presenting: library.pendingUpdate) { draft in
            Button("Update package") { Task { await library.confirmUpdate(draft) } }
        } message: { _ in
            Text("This version adds:\n\(library.updateAdditions.joined(separator: "\n"))")
        }
        .confirmationDialog(uninstalling.map { "Uninstall \($0.name)?" } ?? "",
                            isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } }),
                            presenting: uninstalling) { manifest in
            Button("Uninstall", role: .destructive) {
                Task {
                    for version in library.installed where version.id == manifest.id { await library.uninstall(version) }
                }
            }
        } message: { manifest in
            Text(manifest.kind == .theme
                 ? "Its files will be deleted. A bar that uses it switches to Clear, and a screen that uses it to the bar’s theme, without its settings. This cannot be undone."
                 : "Its files will be deleted and its widgets removed from the bar. Its settings and saved credentials are kept. This cannot be undone.")
        }
        .sheet(isPresented: $showingSources) { PackageSourcesView(library: library, link: $sourceLink) }
        .onAppear(perform: openPendingSourceLink)
        .onChange(of: store.pendingLinks.source) { openPendingSourceLink() }
        .onAppear(perform: openPendingPackageLink)
        .onChange(of: store.pendingLinks.package) { openPendingPackageLink() }
        .onChange(of: busy) { openPendingPackageLink() }
        .onChange(of: store.effectiveDocument) { library.configurationChanged() }
        .onChange(of: library.sources) {
            if case let .source(id) = library.filter, !library.sources.contains(where: { $0.id == id }) { library.filter = .all }
        }
        .onChange(of: selectedPackageID) { _, id in
            if let id {
                tab = .settings
                Task { await library.selectPackage(id) }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                TextField("Search widgets and themes", text: $library.search)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onExitCommand { library.search = "" }
            }
            .padding(.horizontal, 8)
            .frame(width: 240, height: 26)
            .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(searching ? Color.accentColor : SettingsPalette.groupBorder,
                                                                     lineWidth: searching ? 2 : 1))
            Spacer()
            ProgressView().controlSize(.small).opacity(library.loadingStore ? 1 : 0)
            Button("Reload Store", systemImage: "arrow.clockwise") { Task { await library.loadStore(reload: true) } }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Reload the Store and check for updates")
                .disabled(library.loadingStore)
            Button("Sources…", systemImage: "tray.2") { showingSources = true }
                .controlSize(.small)
            Button("Open a folder…", systemImage: "folder", action: chooseFolder)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .disabled(library.draft?.working == true)
    }

    private var busy: Bool {
        library.draft?.working == true || !additions.isEmpty || library.pendingUpdate != nil
    }

    /// Everything the Store lists that matches the search, by name.
    private var catalog: [StoreItem] {
        let themes = gallery.choices.filter { $0.isBundled && (library.search.isEmpty || $0.title.localizedCaseInsensitiveContains(library.search)) }
        let items = library.storeEntries.map(StoreItem.entry) + WidgetAddCatalog.builtIns.filter { $0.matches(library.search) }.map(StoreItem.builtIn)
            + themes.map(StoreItem.theme) + library.unlistedPackages.map(StoreItem.unlisted)
        // Entries keep their source order when they share a name.
        return items.enumerated().sorted {
            let order = $0.element.name.localizedStandardCompare($1.element.name)
            return order == .orderedSame ? $0.offset < $1.offset : order == .orderedAscending
        }.map(\.element)
    }

    private func items(in filter: PackageFilter, from items: [StoreItem], owned: Set<String>) -> [StoreItem] {
        items.filter { item in
            switch (filter, item) {
            case (.all, _): true
            case let (.updates, .entry(entry)): library.hasUpdate(entry)
            case let (.installed, .entry(entry)): owned.contains(entry.id)
            case (.installed, .unlisted), (.included, .builtIn), (.included, .theme): true
            case let (.source(id), .entry(entry)): entry.sourceID == id
            case (.themes, _): item.category == nil
            case let (.category(category), _): item.category == category
            default: false
            }
        }
    }

    private func sidebar(_ items: [StoreItem], owned: Set<String>) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sidebarRow(.all, "All", "square.grid.2x2", count: items.count)
                sidebarRow(.updates, "Updates", "arrow.down.circle", count: self.items(in: .updates, from: items, owned: owned).count)
                sidebarRow(.installed, "Installed", "checkmark.circle", count: self.items(in: .installed, from: items, owned: owned).count)
                sidebarHeader("Sources")
                sidebarRow(.included, "Included", "sparkle", count: self.items(in: .included, from: items, owned: owned).count)
                ForEach(library.sources) { source in
                    sidebarRow(.source(source.id), source.isStore ? "Store" : source.name, source.isStore ? "bag" : "lock",
                               count: self.items(in: .source(source.id), from: items, owned: owned).count)
                }
                sidebarHeader("Categories")
                ForEach(WidgetCategory.allCases, id: \.self) { category in
                    sidebarRow(.category(category), category.title, category.symbol,
                               count: self.items(in: .category(category), from: items, owned: owned).count)
                }
                sidebarRow(.themes, "Themes", "paintpalette", count: self.items(in: .themes, from: items, owned: owned).count)
            }
            .padding(10)
        }
    }

    private func sidebarHeader(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
    }

    private func sidebarRow(_ filter: PackageFilter, _ title: String, _ symbol: String, count: Int) -> some View {
        let selected = library.filter == filter
        return Button {
            library.filter = filter
            library.deselect()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(selected ? SettingsPalette.control : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func storeList(_ items: [StoreItem], owned: Set<String>) -> some View {
        let shown = self.items(in: library.filter, from: items, owned: owned)
        let suggested = library.filter == .all ? shown.filter { item in
            if case let .entry(entry) = item { library.suggested.contains(entry.id) && !owned.contains(entry.id) } else { false }
        } : []
        let groups: [(title: String, items: [StoreItem])] = switch library.filter {
        case .updates: [("Updates", shown)]
        case .themes: [("Themes", shown)]
        case let .category(category): [(category.title, shown)]
        case .all, .installed, .included, .source:
            WidgetCategory.allCases.map { category in (category.title, shown.filter { $0.category == category }) }
                + [("Themes", shown.filter { $0.category == nil })]
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let linkError = library.linkError {
                    SettingsCallout(systemImage: "link", text: Text(linkError)).textSelection(.enabled)
                }
                ForEach(failedSources, id: \.self) { id in
                    SettingsCallout(systemImage: "wifi.exclamationmark",
                                    text: Text(sourceErrorSummary(id) + "\n") + Text(library.sourceErrors[id] ?? "").font(.caption))
                        .textSelection(.enabled)
                }
                rows("Suggested for you", suggested, note: "For tools and apps on your Mac")
                ForEach(groups, id: \.title) { group in rows(group.title, group.items) }
                if shown.isEmpty {
                    Text(library.search.isEmpty ? "Nothing here." : "No packages match your search.").font(.caption).foregroundStyle(.secondary)
                }
                if let error = library.error ?? setup.error { errorLabel(error) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A titled group of rows; a group without rows is left out.
    @ViewBuilder private func rows(_ title: String, _ items: [StoreItem], note: String? = nil) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(note ?? "\(items.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        row(item)
                    }
                }
                .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.groupBorder))
            }
        }
    }

    @ViewBuilder private func row(_ item: StoreItem) -> some View {
        switch item {
        case let .builtIn(choice):
            StoreRow(name: choice.name, badge: nil, description: choice.description, open: nil) {
                RowIcon(symbol: choice.symbol)
            } trailing: {
                if widgetTypes.contains(where: { $0 == choice.properties?["type"] }) {
                    StatusLabel(status: .onBar)
                } else {
                    Button("Add to bar") {
                        setup.beginSheet()
                        Task {
                            if await setup.add(choice, to: .right) != nil {
                                store.customizationHistory.showNotice("\(choice.name) added to the right side of your bar.")
                            }
                        }
                    }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                    .disabled(setup.isAdding)
                    .accessibilityLabel("Add \(choice.name) to bar")
                }
            }
        case let .theme(choice):
            StoreRow(name: choice.title, badge: nil, description: gallery.error(for: choice.key) ?? choice.manifest.description, open: nil) {
                PackagePreview(screenshotData: nil, look: gallery.previews[choice.key]?.configuration(for: gallery.previewAppearance))
                    .frame(width: 128, height: 64).scaleEffect(0.5625).frame(width: 72, height: 36)
                    .background(SettingsPalette.control, in: RoundedRectangle(cornerRadius: 6))
            } trailing: {
                if choice.key == gallery.selectedKey {
                    StatusLabel(status: .inUse)
                } else {
                    Button("Use") { gallery.select(choice) }
                        .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                        .accessibilityLabel("Use \(choice.title)")
                }
            }
        case let .entry(entry):
            StoreRow(name: entry.name, badge: entry.sourceID == PackageSource.storeID ? nil : library.origin(of: entry), description: entry.description, open: {
                Task {
                    if library.installedPackages.contains(where: { $0.id == entry.id }) {
                        await library.selectPackage(entry.id)
                    } else {
                        await library.selectStore(entry)
                    }
                    tab = .overview
                }
            }) {
                if entry.kind == .theme {
                    PackageListPreview(key: entry.key) { try await library.preview(entry) }
                        .frame(width: 128).scaleEffect(0.5625).frame(width: 72, height: 36)
                } else {
                    RowIcon(symbol: entry.symbol ?? "shippingbox")
                }
            } trailing: {
                if let manifest = library.installedPackages.first(where: { $0.id == entry.id }) { uninstallMenu(manifest) }
                EntryStatus(entry: entry, library: library) {
                    tab = .overview
                    Task {
                        if let manifest = library.updates.first(where: { library.update(for: $0)?.key == entry.key }) {
                            await library.update(manifest)
                        }
                        else { await library.get(entry) }
                    }
                }
            }
        case let .unlisted(manifest):
            let badge: PackageOrigin? = switch library.origin(of: manifest) {
            case .local?: .local
            case .saved?: .saved
            case .themeLink?: .themeLink
            case .barLink?: .barLink
            case .retired?: .retired
            case let .privateSource(name)?: .privateSource(name)
            default: nil
            }
            StoreRow(name: manifest.name, badge: badge, description: manifest.description, open: {
                Task {
                    await library.selectPackage(manifest.id)
                    tab = .overview
                }
            }) {
                if manifest.kind == .theme {
                    PackageListPreview(key: manifest.versionKey) { try await library.preview(manifest) }
                        .frame(width: 128).scaleEffect(0.5625).frame(width: 72, height: 36)
                } else {
                    RowIcon(symbol: "shippingbox")
                }
            } trailing: {
                uninstallMenu(manifest)
                StatusLabel(status: library.installedStatus(manifest))
            }
        }
    }

    private func uninstallMenu(_ manifest: WidgetPackageManifest) -> some View {
        Menu {
            Button("Uninstall…", role: .destructive) { uninstalling = manifest }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions for \(manifest.name)")
    }

    /// The types of the widgets the configuration defines, which built-in widgets show as on the bar.
    private var widgetTypes: [ConfigurationValue] {
        guard case let .array(widgets)? = store.effectiveDocument["widgets"] else { return [] }
        return widgets.compactMap { if case let .object(widget) = $0 { widget["type"] } else { nil } }
    }

    /// The Store first, then the private sources in their configured order.
    private var failedSources: [String] {
        library.sources.map(\.id).filter { library.sourceErrors[$0] != nil }
    }

    private func sourceErrorSummary(_ id: String) -> String {
        id == PackageSource.storeID ? "Store unavailable. Installed packages are still available."
            : "\(library.sourceName(id)) is unavailable. Other sources and installed packages still work."
    }

    /// A join link opens the sources sheet with its Add source form; the store's copy is cleared once taken.
    private func openPendingSourceLink() {
        guard reviewing == nil, let link = store.pendingLinks.source else { return }
        store.pendingLinks.source = nil
        sourceLink = link
        showingSources = true
    }

    /// A package link shows its package once nothing is being added or updated; the store's copy is cleared once taken.
    private func openPendingPackageLink() {
        guard reviewing == nil, !busy, let link = store.pendingLinks.package else { return }
        store.pendingLinks.package = nil
        tab = .overview
        Task { await library.open(link) }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if let draft = library.draft {
                PackageDetailView(store: store, library: library, draft: draft, reviewing: reviewing != nil, tab: $tab,
                                  additions: $additions, onEnable: onEnable, onAdded: onAdded, onWorkingChanged: onWorkingChanged)
            } else if library.loading {
                ProgressView("Loading package…")
                    .opacity(showsLoading ? 1 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                        showsLoading = true
                    }
                    .onDisappear { showsLoading = false }
            } else {
                Spacer()
            }
            if let error = library.error { errorLabel(error) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorLabel(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            .textSelection(.enabled).font(.callout).padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Review package"
        if panel.runModal() == .OK, let url = panel.url {
            tab = .overview
            Task { await library.select(url) }
        }
    }
}

/// One row of the Store: a widget or theme included with StableBar, a source's package, or an installed package
/// that no source lists.
private enum StoreItem {
    case builtIn(WidgetAddChoice), theme(ThemeChoice), entry(PackageIndex.Entry), unlisted(WidgetPackageManifest)

    var id: String {
        switch self {
        case let .builtIn(choice): "builtIn:\(choice.id)"
        case let .theme(choice): "theme:\(choice.key)"
        case let .entry(entry): entry.key
        case let .unlisted(manifest): "unlisted:\(manifest.id)"
        }
    }

    var name: String {
        switch self {
        case let .builtIn(choice): choice.name
        case let .theme(choice): choice.title
        case let .entry(entry): entry.name
        case let .unlisted(manifest): manifest.name
        }
    }

    /// nil for a theme.
    var category: WidgetCategory? {
        switch self {
        case let .builtIn(choice): choice.category
        case .theme: nil
        case let .entry(entry): entry.kind == .theme ? nil : WidgetCategory(rawValue: entry.category ?? "") ?? .utilities
        case let .unlisted(manifest): manifest.kind == .theme ? nil : .utilities
        }
    }
}

/// A row of the Store, which opens its package when clicked; `open` is nil when it has nothing to open.
/// `badge` names a private source or a local folder, which nobody at StableBar reviewed.
private struct StoreRow<Leading: View, Trailing: View>: View {
    let name: String
    let badge: PackageOrigin?
    let description: String?
    let open: (() -> Void)?
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let badge { PackageOriginBadge(source: badge) }
                }
                if let description {
                    Text(description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .help(description ?? "")
            Spacer(minLength: 8)
            HStack(spacing: 10) { trailing }.fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering && open != nil ? SettingsPalette.control : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { open?() }
    }
}

private struct RowIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14))
            .frame(width: 30, height: 30)
            .background(SettingsPalette.control, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// An installed package's state on its row.
private struct StatusLabel: View {
    let status: StoreCardStatus

    var body: some View {
        Group {
            switch status {
            case .onBar: Label("On your bar", systemImage: "checkmark").foregroundStyle(SettingsPalette.success)
            case .inUse: Label("In use", systemImage: "checkmark").foregroundStyle(SettingsPalette.success)
            case .notOnBar: Text("Not on your bar").foregroundStyle(.secondary)
            default: Label("Installed", systemImage: "checkmark").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11.5))
    }
}

/// What a Store entry's row offers: Get, Update, its progress or its installed state.
private struct EntryStatus: View {
    let entry: PackageIndex.Entry
    let library: PackageLibrary
    let get: () -> Void

    var body: some View {
        switch library.cardStatus(entry) {
        case let .working(updating):
            Text(updating ? "Updating…" : "Getting…").font(.system(size: 11.5)).foregroundStyle(.secondary)
        case .update:
            Button("Update", action: get).buttonStyle(.borderedProminent).controlSize(.small)
                .accessibilityLabel("Update \(entry.name)")
        case let .installedElsewhere(name):
            Text("Installed from \(name)").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
        case .get:
            Button("Get", action: get)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityLabel("Get \(entry.name)")
        case let status:
            StatusLabel(status: status)
        }
    }
}

/// What a Store entry offers: its own install, or another source's, decides between an installed state and Get.
enum StoreCardStatus: Equatable {
    case working(updating: Bool), update, installedElsewhere(String), installed, onBar, notOnBar, inUse, get
}

extension PackageLibrary {
    func cardStatus(_ entry: PackageIndex.Entry) -> StoreCardStatus {
        let update = hasUpdate(entry)
        if getting.contains(entry.key) || (update && updating.contains(entry.id)) { return .working(updating: update) }
        if update { return .update }
        if let name = installedElsewhere(entry) { return .installedElsewhere(name) }
        if let manifest = installedPackages.first(where: { $0.id == entry.id }) { return installedStatus(manifest) }
        return installed.contains { $0.id == entry.id } ? .installed : .get
    }

    /// A theme is in use or only installed; a widget package is on the bar or not.
    func installedStatus(_ manifest: WidgetPackageManifest) -> StoreCardStatus {
        if manifest.kind == .theme { return isActive(manifest) ? .inUse : .installed }
        return isActive(manifest) ? .onBar : .notOnBar
    }
}

extension WidgetPackageManifest {
    var versionKey: String { "\(id)/\(version)" }
}

struct PackageSettingsFields: View {
    @Bindable var draft: PackageDraft
    var includesCredentials = true
    let set: (String, ConfigurationValue) -> Void

    var body: some View {
        ForEach(draft.inspection.manifest.settingNames.filter {
            includesCredentials || draft.inspection.manifest.settings[$0]!.type != "secret"
        }, id: \.self) { name in
            let setting = draft.inspection.manifest.settings[name]!
            let title = setting.title ?? name
            VStack(alignment: .leading, spacing: 4) {
                if setting.type == "secret" {
                    let saved = draft.savedSecrets?.contains(name) == true && draft.secrets[name] == nil
                    LabeledContent(title) {
                        HStack {
                            SecureField(title, text: Binding(get: { draft.secrets[name, default: ""] }, set: { draft.secrets[name] = $0 }),
                                        prompt: Text(draft.savedSecrets == nil ? "Not checked" : saved ? "Saved" : "Not set"))
                                .labelsHidden()
                            if saved { Button("Remove") { draft.secrets[name] = "" }.buttonStyle(.borderless) }
                        }
                    }
                } else if let choices = setting.choices, case let .string(text) = draft.settings[name]! {
                    Picker(title, selection: Binding(get: { text }, set: { set(name, .string($0)) })) {
                        ForEach(choices, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    PackageSettingField(title: title, value: Binding(get: { draft.settings[name]! }, set: { set(name, $0) }))
                }
                if let description = setting.description { Text(description).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct WidgetPackageSettings: View {
    let store: BarStore
    let packageID: String
    let onManage: () -> Void
    private var library: PackageLibrary { store.packageLibrary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let draft = library.draft, draft.inspection.manifest.id == packageID, library.isActive(draft) {
                let manifest = draft.inspection.manifest
                Text(manifest.settings.isEmpty
                     ? "Content comes from \(manifest.name). Use Technical details for per-widget JSON overrides."
                     : "Content settings are shared by widgets from \(manifest.name). Per-widget JSON overrides are in Technical details.")
                    .font(.caption).foregroundStyle(.secondary)
                if !manifest.settings.isEmpty {
                    PackageSettingsFields(draft: draft, includesCredentials: false,
                                          set: { name, value in library.setSetting(name, value: value, in: draft) })
                    if manifest.settings.values.contains(where: { $0.type == "secret" }) {
                        Button(draft.secrets.isEmpty ? "Manage credentials…" : "Review unsaved credentials…", action: onManage)
                    }
                }
                if let error = draft.error ?? draft.credentialsError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.caption).textSelection(.enabled)
                }
                Button("Manage package…", action: onManage)
            } else if let error = library.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption).textSelection(.enabled)
                Button("Open package library…", action: onManage)
            } else {
                ProgressView("Loading package settings…").controlSize(.small)
            }
        }
        .task(id: packageID) {
            await library.loadInstalled()
            await library.selectPackage(packageID)
        }
        .onChange(of: store.effectiveDocument) { library.configurationChanged() }
    }
}

private struct PackageSettingField: View {
    let title: String
    @Binding var value: ConfigurationValue

    var body: some View {
        switch value {
        case let .string(text):
            LabeledContent(title) {
                TextField(title, text: Binding(get: { text }, set: { value = .string($0) })).labelsHidden()
            }
        case let .number(number):
            LabeledContent(title) {
                TextField(title, value: Binding(get: { number }, set: { value = .number($0) }), format: .number).labelsHidden()
            }
        case let .bool(enabled):
            Toggle(title, isOn: Binding(get: { enabled }, set: { value = .bool($0) }))
        default:
            EmptyView()
        }
    }
}
