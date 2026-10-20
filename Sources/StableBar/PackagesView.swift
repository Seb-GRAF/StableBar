import AppKit
import SwiftUI

struct PackagesView: View {
    let store: BarStore
    var selectedPackageID: String?
    var reviewing: WidgetPackageInspection?
    var onEnable: ((WidgetPackageInspection, [String: ConfigurationValue]) throws -> Void)?
    var onAdded: (() -> Void)?
    var onWorkingChanged: ((Bool) -> Void)?
    @State private var library: PackageLibrary
    @State private var additions: [String] = []
    @State private var confirmingUninstall = false
    @State private var confirmingRemoval = false

    init(store: BarStore, indexURL: URL = PackageIndex.url, selectedPackageID: String? = nil,
         reviewing: WidgetPackageInspection? = nil,
         onEnable: ((WidgetPackageInspection, [String: ConfigurationValue]) throws -> Void)? = nil,
         onAdded: (() -> Void)? = nil, onWorkingChanged: ((Bool) -> Void)? = nil) {
        self.store = store
        self.selectedPackageID = selectedPackageID
        self.reviewing = reviewing
        self.onEnable = onEnable
        self.onAdded = onAdded
        self.onWorkingChanged = onWorkingChanged
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
                details
            } else {
                HSplitView {
                    browser.frame(minWidth: 230, maxWidth: 300)
                        .disabled(library.draft?.working == true || !additions.isEmpty)
                    details.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task {
            await library.loadInstalled()
            if let reviewing {
                await library.select(reviewing.directory)
            } else {
                if let selectedPackageID { await library.selectPackage(selectedPackageID) }
                await library.loadStore()
                if let selectedPackageID, library.draft?.inspection.manifest.id != selectedPackageID {
                    await library.selectPackage(selectedPackageID)
                }
            }
        }
        .onChange(of: store.effectiveDocument) { library.configurationChanged() }
        .onChange(of: selectedPackageID) { _, id in
            if let id { Task { await library.selectPackage(id) } }
        }
    }

    private var browser: some View {
        let installed = library.installedPackages.filter { matches($0.name, $0.description, id: $0.id) }
        let entries = library.entries.filter { entry in
            entry.kind != .theme && !library.installed.contains { $0.id == entry.id }
                && matches(entry.name, entry.description, id: entry.id)
        }
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Widget library").font(.headline)
                Text("Widgets appear on your bar. A package supplies widgets, settings and updates.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Search packages", text: $library.search).textFieldStyle(.roundedBorder)
                Picker("Show", selection: $library.showingInstalled) {
                    Text("Browse").tag(false)
                    Text("Installed").tag(true)
                }.pickerStyle(.segmented)
            }.padding(12)
            List(selection: Binding(get: { library.draft?.inspection.manifest.id }, set: { id in
                if let id { Task { await library.selectPackage(id) } }
            })) {
                Section("Installed") {
                    ForEach(installed, id: \.id) { manifest in
                        let update = library.entries.contains { $0.id == manifest.id && $0.version.compare(manifest.version, options: .numeric) == .orderedDescending }
                        packageRow(name: manifest.name, description: manifest.description,
                                   status: update ? "Update available" : manifest.kind == .theme ? "Theme" : "Installed",
                                   active: library.selections.contains { $0.id == manifest.id && $0.enabled })
                            .tag(manifest.id)
                    }
                    if library.installed.isEmpty {
                        Text("No packages installed").foregroundStyle(.secondary)
                    }
                }
                if !library.showingInstalled {
                    Section("Store") {
                        ForEach(entries, id: \.id) { entry in
                            packageRow(name: entry.name, description: entry.description,
                                       status: "Store · \(entry.version)", active: false)
                                .tag(entry.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            if !library.search.isEmpty && installed.isEmpty && (library.showingInstalled || entries.isEmpty) {
                Text("No packages match your search.").font(.caption).foregroundStyle(.secondary).padding(10)
            }
            if library.loadingStore { ProgressView("Loading Store…").controlSize(.small).padding(8) }
            if let error = library.storeError {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Store unavailable. Installed packages are still available.").font(.caption)
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.padding(10)
            }
            Divider()
            HStack {
                Button("Open package folder…", systemImage: "folder.badge.plus", action: chooseFolder)
                Spacer()
                Button("Reload Store", systemImage: "arrow.clockwise") { Task { await library.loadStore(reload: true) } }
                    .labelStyle(.iconOnly).help("Reload Store")
            }.buttonStyle(.borderless).padding(10)
        }
    }

    private func matches(_ name: String, _ description: String?, id: String) -> Bool {
        library.search.isEmpty || "\(name) \(description ?? "") \(id)".localizedCaseInsensitiveContains(library.search)
    }

    private func packageRow(name: String, description: String?, status: String, active: Bool) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).lineLimit(1)
                if let description { Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Text(active ? "In use · \(status)" : status).font(.caption).foregroundStyle(.secondary)
            }
        } icon: { Image(systemName: "shippingbox") }
        .padding(.vertical, 4)
    }

    private var details: some View {
        VStack(spacing: 0) {
            if library.loading {
                ProgressView("Loading package…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let draft = library.draft {
                packageDetails(draft)
            } else {
                ContentUnavailableView("Choose a package", systemImage: "shippingbox",
                    description: Text("Browse widgets, configure installed packages, or open a package folder."))
            }
            if let error = library.error ?? store.customizationHistory.error {
                errorLabel(error)
            }
        }
    }

    private func packageDetails(_ draft: PackageDraft) -> some View {
        let manifest = draft.inspection.manifest
        let active = library.isActive(draft)
        let installed = library.isInstalled(draft)
        let state: String
        if active {
            let count = library.shownWidgets(draft)
            state = manifest.kind == .theme ? "Current theme" : count == 1 ? "1 widget turned on" : "\(count) widgets turned on"
        } else if installed {
            state = manifest.kind == .theme ? "Installed · Not selected" : "Installed · Not on the bar"
        } else {
            state = "Not installed"
        }
        return VStack(spacing: 0) {
            Form {
                Section {
                    Text(manifest.name).font(.title2.weight(.semibold))
                    if let description = manifest.description { Text(description) }
                    Text("Version \(manifest.version)").font(.caption).foregroundStyle(.secondary)
                    Text(state).foregroundStyle(.secondary)
                    if let entry = library.entries.first(where: { entry in
                        entry.id == manifest.id && entry.version.compare(manifest.version, options: .numeric) == .orderedDescending
                    }) {
                        Button("Review update \(entry.version)") { Task { await library.selectStore(entry) } }
                    }
                    if let data = draft.screenshotData, let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 180)
                    }
                }
                if !draft.inspection.widgets.isEmpty {
                    Section("Included widgets") {
                        ForEach(draft.inspection.widgets) { widget in
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(WidgetDisplayName.title(for: widget.content))
                                    Text(widget.id).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: widget.content.symbol) }
                        }
                        if draft.inspection.widgets.count > 1 {
                            Text("This package includes \(draft.inspection.widgets.count) widgets. Some may depend on the active profile. Show or hide individual widgets in Your bar.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !manifest.settings.isEmpty {
                    Section("Setup") {
                        PackageSettingsFields(draft: draft, set: { name, value in library.setSetting(name, value: value, in: draft) })
                        if active && reviewing == nil {
                            Text("Settings save automatically.").font(.caption).foregroundStyle(.secondary)
                            if manifest.settings.values.contains(where: { $0.type == "secret" }) {
                                Text("Credentials need Save credentials.").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Settings apply when you add this package. Your draft stays here while you browse.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                requirements(manifest)
                if manifest.kind != .theme {
                    Section("Access review") {
                        if draft.inspection.commands.isEmpty {
                            Text("This package declares no commands.").foregroundStyle(.secondary)
                        } else {
                            Text("These commands run with your account’s access when the package is on your bar.")
                                .font(.callout).foregroundStyle(.secondary)
                            ForEach(draft.inspection.commands, id: \.self) { command in
                                Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                }
                Section {
                    DisclosureGroup("Versions and technical details") {
                        versionPicker(draft)
                        LabeledContent("Package ID", value: manifest.id).textSelection(.enabled)
                        LabeledContent("Location") {
                            Text(draft.inspection.directory.path).textSelection(.enabled).lineLimit(2)
                        }
                        Button("Open in Finder") { NSWorkspace.shared.open(draft.inspection.directory) }
                        if let author = manifest.author { LabeledContent("Author", value: author) }
                        if let repository = manifest.repository { Link("Package source", destination: repository) }
                        if installed && reviewing == nil {
                            Button("Uninstall this version…", role: .destructive) { confirmingUninstall = true }
                        }
                    }
                }
            }.formStyle(.grouped)
                .disabled(draft.working)
            if let error = draft.error ?? draft.credentialsError { errorLabel(error) }
            Divider()
            HStack(spacing: 10) {
                if draft.working || draft.checking { ProgressView().controlSize(.small) }
                Text(status(draft)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if active && reviewing == nil {
                    if !draft.secrets.isEmpty {
                        Button("Save credentials") { Task { await library.saveCredentials(draft) } }
                            .buttonStyle(.borderedProminent)
                    }
                    Button(manifest.kind == .theme ? "Use Built-in" : "Remove from bar…") { confirmingRemoval = true }
                    if manifest.kind != .theme && library.shownWidgets(draft) == 0 {
                        Button("Show widgets") { requestAdd(draft) }.buttonStyle(.borderedProminent)
                    }
                } else {
                    Button(manifest.kind == .theme ? "Use theme" : "Add to bar") {
                        requestAdd(draft)
                    }.buttonStyle(.borderedProminent)
                }
            }
            .disabled(draft.working || draft.checking)
            .padding(12)
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
        .confirmationDialog("Uninstall \(manifest.name) \(manifest.version)?", isPresented: $confirmingUninstall) {
            Button("Uninstall version", role: .destructive) { Task { await library.uninstall(draft) } }
        } message: {
            Text("This version’s files will be deleted and its widgets removed from the bar if active. Other versions, settings and saved credentials are kept. This cannot be undone.")
        }
    }

    private func status(_ draft: PackageDraft) -> String {
        if draft.error != nil || draft.credentialsError != nil { return "Changes need attention" }
        if !draft.secrets.isEmpty { return "Credentials not saved" }
        if draft.checking { return "Checking settings…" }
        if library.isActive(draft) && reviewing == nil {
            return store.customizationHistory.hasPendingChanges ? "Saving settings…" : "Settings saved"
        }
        return "Ready to review and add"
    }

    private func versionPicker(_ draft: PackageDraft) -> some View {
        let manifest = draft.inspection.manifest
        let installed = library.installed.filter { $0.id == manifest.id }
            .sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        return VStack(alignment: .leading) {
            Picker("Version", selection: Binding(get: { manifest.version }, set: { version in
                if let selected = installed.first(where: { $0.version == version }) {
                    Task { await library.selectInstalled(selected) }
                }
            })) {
                ForEach(installed, id: \.version) { Text($0.version).tag($0.version) }
                if !installed.contains(where: { $0.version == manifest.version }) { Text(manifest.version).tag(manifest.version) }
            }
            Text("Versions stay pinned until you choose another. Your compatible settings carry over.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func requirements(_ manifest: WidgetPackageManifest) -> some View {
        if manifest.minimumVersion != nil || !manifest.requires.isEmpty || !manifest.permissions.isEmpty || !manifest.hosts.isEmpty {
            Section("Requirements") {
                if let minimum = manifest.minimumVersion { LabeledContent("StableBar", value: "\(minimum) or later") }
                if !manifest.requires.isEmpty {
                    LabeledContent("Tools", value: manifest.requires.joined(separator: ", "))
                    let missing = manifest.missingTools(path: shellEnvironment.withLock { $0["PATH", default: ""] })
                    if !missing.isEmpty {
                        Label("Install these tools first: \(missing.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                if !manifest.permissions.isEmpty { LabeledContent("Permissions", value: manifest.permissions.map(\.rawValue.capitalized).joined(separator: ", ")) }
                if !manifest.hosts.isEmpty { LabeledContent("Connects to", value: manifest.hosts.joined(separator: ", ")) }
            }
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

    private func errorLabel(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            .textSelection(.enabled).font(.callout).padding(12)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Review package"
        if panel.runModal() == .OK, let url = panel.url { Task { await library.select(url) } }
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
