import AppKit
import SwiftUI

struct PackagesView: View {
    let store: BarStore
    var selectedPackageID: String?
    var reviewing: WidgetPackageInspection?
    var onEnable: ((WidgetPackageInspection, [String: ConfigurationValue]) throws -> Void)?
    var onAdded: (() -> Void)?
    var onWorkingChanged: ((Bool) -> Void)?
    @Binding var searchTarget: String?
    @State private var library: PackageLibrary
    @State private var tab: PackageDetailTab
    @State private var additions: [String] = []
    @State private var showingThemes: Bool?
    @State private var gallery: ThemeGallery
    @State private var showsLoading = false
    @FocusState private var searching: Bool

    init(store: BarStore, indexURL: URL = PackageIndex.url, selectedPackageID: String? = nil,
         reviewing: WidgetPackageInspection? = nil,
         onEnable: ((WidgetPackageInspection, [String: ConfigurationValue]) throws -> Void)? = nil,
         onAdded: (() -> Void)? = nil, onWorkingChanged: ((Bool) -> Void)? = nil,
         searchTarget: Binding<String?> = .constant(nil)) {
        self.store = store
        self.selectedPackageID = selectedPackageID
        self.reviewing = reviewing
        self.onEnable = onEnable
        self.onAdded = onAdded
        self.onWorkingChanged = onWorkingChanged
        _searchTarget = searchTarget
        _gallery = State(initialValue: ThemeGallery(store: store))
        _tab = State(initialValue: selectedPackageID == nil ? .overview : .settings)
        if reviewing != nil || indexURL != PackageIndex.url {
            let packages = WidgetPackageStore(directory: store.configurationURL.deletingLastPathComponent().appending(path: "packages"))
            _library = State(initialValue: PackageLibrary(store: store, client: PackageStoreClient(packages: packages, indexURL: indexURL), reviewing: reviewing != nil))
        } else {
            _library = State(initialValue: store.packageLibrary)
        }
    }

    var body: some View {
        Group {
            if reviewing != nil {
                detail
            } else {
                VStack(spacing: 0) {
                    topBar
                    Divider()
                    HStack(spacing: 0) {
                        Group {
                            if library.showingStore { storeList } else { list }
                        }
                        .frame(width: 256)
                        .background(SettingsPalette.sidebar)
                        .disabled(library.draft?.working == true || !additions.isEmpty || library.pendingUpdate != nil)
                        Divider()
                        detail
                    }
                }
            }
        }
        .task {
            await library.loadInstalled()
            if let reviewing {
                await library.select(reviewing.directory)
            } else {
                await gallery.refresh()
                if let selectedPackageID {
                    library.showingStore = false
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
                showStore(target == SettingsSearchResult.store.id)
                searchTarget = nil
            }
        }
        .confirmationDialog("Review additional access", isPresented: Binding(get: { library.pendingUpdate != nil }, set: { if !$0 { library.pendingUpdate = nil } }),
                            presenting: library.pendingUpdate) { draft in
            Button("Update package") { Task { await library.confirmUpdate(draft) } }
        } message: { _ in
            Text("This version adds:\n\(library.updateAdditions.joined(separator: "\n"))")
        }
        .onChange(of: store.effectiveDocument) { library.configurationChanged() }
        .onChange(of: selectedPackageID) { _, id in
            if let id {
                tab = .settings
                library.showingStore = false
                Task { await library.selectPackage(id) }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            SettingsSegments(selection: Binding(get: { library.showingStore }, set: { showStore($0) }),
                             options: [(false, "Installed"), (true, "Store")], stretches: false)
                .fixedSize()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                TextField("Search packages", text: $library.search)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onExitCommand { library.search = "" }
            }
            .padding(.horizontal, 8)
            .frame(width: 200, height: 26)
            .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(searching ? Color.accentColor : SettingsPalette.groupBorder,
                                                                     lineWidth: searching ? 2 : 1))
            Spacer()
            ProgressView().controlSize(.small).opacity(library.loadingStore ? 1 : 0)
            Button("Reload Store", systemImage: "arrow.clockwise") { Task { await library.loadStore(reload: true) } }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Reload the Store and check for updates")
                .disabled(library.loadingStore)
            Button("Open a folder…", systemImage: "folder", action: chooseFolder)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .disabled(library.draft?.working == true)
    }

    private var list: some View {
        let packages = library.installedPackages.filter { matches($0.name, $0.description, id: $0.id) }
        let reviewed = library.draft.flatMap { draft in
            library.installed.contains { $0.id == draft.inspection.manifest.id } ? nil : draft
        }
        return VStack(spacing: 0) {
            List(selection: selection) {
                BuiltInRow(themes: gallery.choices.filter(\.isBundled).count).tag(LibraryRow.builtIn)
                if let reviewed {
                    Section("Not installed") {
                        HStack(alignment: .top, spacing: 8) {
                            PackagePreview(screenshotData: reviewed.screenshotData, look: reviewed.themePreview?.light,
                                           widgets: reviewed.inspection.widgets)
                                .frame(width: 128, height: 64).scaleEffect(0.5625).frame(width: 72, height: 36)
                            PackageRow(manifest: reviewed.inspection.manifest)
                        }
                        .tag(LibraryRow.package(reviewed.inspection.manifest.id))
                    }
                }
                rows("Updates available (\(library.updates.count))", packages.filter { library.update(for: $0) != nil })
                rows("On your bar", packages.filter { $0.kind != .theme && library.isActive($0) && library.update(for: $0) == nil })
                rows("Not on your bar", packages.filter { $0.kind != .theme && !library.isActive($0) && library.update(for: $0) == nil })
                rows("Themes", packages.filter { $0.kind == .theme && library.update(for: $0) == nil })
                if library.installed.isEmpty {
                    Text("Nothing installed yet. Get packages from the Store or open a folder.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if packages.isEmpty && !library.search.isEmpty {
                    Text("No packages match your search.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            if library.storeError != nil {
                Text("Store unavailable. Installed packages are still available.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    @ViewBuilder private func rows(_ title: String, _ packages: [WidgetPackageManifest]) -> some View {
        if !packages.isEmpty {
            Section(title) {
                ForEach(packages, id: \.id) { manifest in
                    HStack(alignment: .top, spacing: 8) {
                        PackageListPreview(key: manifest.versionKey) { try await library.preview(manifest) }
                            .frame(width: 128).scaleEffect(0.5625).frame(width: 72, height: 36)
                        PackageRow(manifest: manifest, update: library.update(for: manifest)?.version,
                                   updating: library.updating.contains(manifest.id), inUse: manifest.kind == .theme && library.isActive(manifest)) {
                            Task { await library.update(manifest) }
                        }
                    }
                    .tag(LibraryRow.package(manifest.id))
                }
            }
        }
    }

    private var selection: Binding<LibraryRow?> {
        Binding(get: {
            library.selectedID.map { .package($0) } ?? (library.loading ? nil : .builtIn)
        }, set: { row in
            switch row {
            case let .package(id)?:
                Task {
                    await library.selectPackage(id)
                    tab = .overview
                }
            case .builtIn?: library.deselect()
            case nil: break
            }
        })
    }

    private var storeList: some View {
        let entries = library.entries.filter { entry in
            (showingThemes == nil || showingThemes == (entry.kind == .theme)) && matches(entry.name, entry.description, id: entry.id)
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                SettingsSegments(selection: $showingThemes, options: [(nil, "All"), (false, "Widgets"), (true, "Themes")], stretches: false)
                    .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            if let error = library.storeError {
                SettingsCallout(systemImage: "wifi.exclamationmark",
                                text: Text("Store unavailable. Installed packages are still available.\n") + Text(error).font(.caption))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            List(selection: storeSelection) {
                ForEach(entries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        PackageListPreview(key: "\(entry.id)/\(entry.version)") { try await library.preview(entry) }
                        StoreRow(entry: entry, installed: library.installed.contains { $0.id == entry.id },
                                 getting: library.getting.contains(entry.id) || library.updating.contains(entry.id),
                                 update: library.updates.contains { $0.id == entry.id }) {
                            tab = .overview
                            Task {
                                if let manifest = library.updates.first(where: { $0.id == entry.id }) { await library.update(manifest) }
                                else { await library.get(entry) }
                            }
                        }
                    }
                    .tag(entry.id)
                }
                if entries.isEmpty && !library.search.isEmpty && !library.entries.isEmpty {
                    Text("No packages match your search.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .overlay {
            if library.loadingStore && library.entries.isEmpty { ProgressView("Loading Store…") }
        }
    }

    private var storeSelection: Binding<String?> {
        Binding(get: { library.selectedID }, set: { id in
            if let entry = library.entries.first(where: { $0.id == id }) {
                Task {
                    await library.selectStore(entry)
                    tab = .overview
                }
            }
        })
    }

    private func showStore(_ showing: Bool) {
        library.showingStore = showing
        let ids = showing ? library.entries.map(\.id) : library.installed.map(\.id)
        if let id = library.draft?.inspection.manifest.id, !ids.contains(id) { library.deselect() }
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
            } else if reviewing == nil {
                if library.showingStore {
                    ContentUnavailableView("Select a package", systemImage: "shippingbox",
                                           description: Text("Choose a package from the Store to see its details."))
                } else {
                    BuiltInPackagesView(store: store, gallery: gallery, search: library.search)
                }
            } else {
                Spacer()
            }
            if let error = library.error { errorLabel(error) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func matches(_ name: String, _ description: String?, id: String) -> Bool {
        library.search.isEmpty || "\(name) \(description ?? "") \(id)".localizedCaseInsensitiveContains(library.search)
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
            library.showingStore = false
            Task { await library.select(url) }
        }
    }
}

private enum LibraryRow: Hashable {
    case package(String), builtIn
}

private struct PackageRow: View {
    let manifest: WidgetPackageManifest
    var update: String?
    var updating = false
    var inUse = false
    var onUpdate: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(manifest.name).fontWeight(.medium).foregroundStyle(.primary).lineLimit(1)
            HStack(spacing: 5) {
                Text(manifest.version).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if inUse { PackageTag(title: "In use", tint: SettingsPalette.success) }
            }
            if let update {
                Button(updating ? "Updating…" : "Update to \(update)") { onUpdate?() }
                    .buttonStyle(.borderedProminent).controlSize(.mini)
                    .disabled(updating)
                    .accessibilityLabel("Update \(manifest.name) to \(update)")
                    .padding(.top, 2)
            }
        }
        .frame(height: update == nil ? 36 : 58, alignment: .top)
    }
}

private struct BuiltInRow: View {
    let themes: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 72, height: 36)
                .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text("StableBar Essentials").fontWeight(.medium).foregroundStyle(.primary).lineLimit(1)
                Text("\(WidgetAddCatalog.builtIns.count) widgets · \(themes) themes").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct StoreRow: View {
    let entry: PackageIndex.Entry
    let installed: Bool
    let getting: Bool
    let update: Bool
    let get: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            PackageIcon(id: entry.id, name: entry.name)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).fontWeight(.medium).foregroundStyle(.primary).lineLimit(1)
                Text([entry.kind == .theme ? "Theme" : "Widget", entry.author.map { "by \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if getting {
                Text(update ? "Updating…" : "Getting…").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else if update {
                Button("Update", action: get).buttonStyle(.borderedProminent).controlSize(.small)
                    .accessibilityLabel("Update \(entry.name)")
            } else if installed {
                Label("Installed", systemImage: "checkmark").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                Button("Get", action: get)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityLabel("Get \(entry.name)")
            }
        }
        .padding(.vertical, 3)
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
        ForEach(draft.inspection.manifest.settings.keys.filter {
            includesCredentials || draft.inspection.manifest.settings[$0]!.type != "secret"
        }.sorted(), id: \.self) { name in
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
            TextField(title, text: Binding(get: { text }, set: { value = .string($0) }))
        case let .number(number):
            TextField(title, value: Binding(get: { number }, set: { value = .number($0) }), format: .number)
        case let .bool(enabled):
            Toggle(title, isOn: Binding(get: { enabled }, set: { value = .bool($0) }))
        default:
            EmptyView()
        }
    }
}
