import AppKit
import SwiftUI

struct PackagesView: View {
    let store: BarStore
    var indexURL: URL = PackageIndex.url
    var reviewing: WidgetPackageInspection?
    var onEnable: ((WidgetPackageInspection, [String: ConfigurationValue]) throws -> Void)?
    @State private var installed: [WidgetPackageManifest] = []
    @State private var selections: [WidgetPackageSelection] = []
    @State private var inspection: WidgetPackageInspection?
    @State private var storeEntries: [PackageIndex.Entry] = []
    @State private var storeEntry: PackageIndex.Entry?
    @State private var storeError: String?
    @State private var downloading: String?
    @State private var additions: [String] = []
    @State private var confirmingUninstall = false
    @State private var settings: [String: ConfigurationValue] = [:]
    @State private var secrets: [String: String] = [:]
    @State private var savedSecrets: Set<String> = []
    @State private var error: String?

    private var packages: WidgetPackageStore {
        WidgetPackageStore(directory: store.configurationURL.deletingLastPathComponent().appending(path: "packages"))
    }

    var body: some View {
        VStack(spacing: 0) {
            if reviewing != nil {
                if let inspection {
                    packageDetails(inspection)
                } else if error == nil {
                    ProgressView("Loading package…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).textSelection(.enabled).padding(12)
                }
            } else {
                browser
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            perform {
                try loadInstalled()
                if let reviewing { try select(reviewing.directory) }
            }
        }
        .task { if reviewing == nil { await loadStore() } }
        .onChange(of: store.effectiveDocument) { _, _ in perform(loadInstalled) }
        .onChange(of: settings) { _, values in
            if let inspection {
                perform { self.inspection = try packages.inspect(inspection.directory, settings: values) }
            }
        }
    }

    private var browser: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: Binding(get: { downloading ?? inspection.map { isInstalled($0) ? $0.manifest.versionKey : "store/\($0.manifest.versionKey)" } }, set: { key in
                    if let manifest = installed.first(where: { $0.versionKey == key || "store/\($0.versionKey)" == key }) {
                        downloading = nil
                        perform { try select(packages.directory(id: manifest.id, version: manifest.version)) }
                    } else if let entry = storeEntries.first(where: { "store/\($0.id)/\($0.version)" == key }) {
                        downloading = key
                        Task {
                            do {
                                let directory = try await packages.download(entry, from: indexURL)
                                guard downloading == key else { return }
                                downloading = nil
                                perform { try select(directory, from: entry) }
                            } catch {
                                guard downloading == key else { return }
                                downloading = nil
                                self.error = errorMessage(error)
                            }
                        }
                    }
                })) {
                    Section("Installed") {
                        if installed.isEmpty {
                            Text("No packages installed").foregroundStyle(.secondary)
                        }
                        ForEach(installed, id: \.versionKey) { manifest in
                            Label {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(manifest.name).lineLimit(1)
                                        Text("\(manifest.id) · \(manifest.version)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selections.contains(where: { $0.id == manifest.id && $0.version == manifest.version && $0.enabled }) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Enabled")
                                    }
                                }
                            } icon: {
                                Image(systemName: "shippingbox")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    Section {
                        if let storeError {
                            Label(storeError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(storeEntries, id: \.id) { entry in
                            let installedVersions = installed.filter { $0.id == entry.id }.map(\.version)
                            let tooOld = entry.minimumVersion.map(packages.requiresNewerApp) == true
                            let kind = switch entry.kind {
                            case .theme?: "theme"
                            case .widgets?: "contains no commands"
                            case nil: "runs commands"
                            }
                            Label {
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.name).lineLimit(1)
                                        Text("\(entry.version) · \(kind)").font(.caption).foregroundStyle(.secondary)
                                        if let description = entry.description {
                                            Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                        if tooOld {
                                            Text("Requires StableBar \(entry.minimumVersion!)").font(.caption).foregroundStyle(.orange)
                                        }
                                    }
                                    Spacer()
                                    if installedVersions.contains(entry.version) {
                                        Text("Installed")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.primary.opacity(0.06), in: Capsule())
                                    } else if !installedVersions.isEmpty, installedVersions.allSatisfy({ entry.version.compare($0, options: .numeric) == .orderedDescending }) {
                                        Text("Update")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(Color.accentColor)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                                    }
                                }
                            } icon: {
                                Image(systemName: "arrow.down.circle")
                            }
                            .padding(.vertical, 2)
                            .tag("store/\(entry.id)/\(entry.version)")
                            .selectionDisabled(tooOld)
                        }
                    } header: {
                        HStack {
                            Text("Store")
                            Spacer()
                            Button("Reload Store", systemImage: "arrow.clockwise") { Task { await loadStore() } }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Reload the store")
                        }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack {
                    Button("Review Package Folder…", systemImage: "folder.badge.plus", action: chooseFolder)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(minWidth: 220, maxWidth: 300, maxHeight: .infinity)

            VStack(spacing: 0) {
                if downloading != nil {
                    ProgressView("Downloading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let inspection {
                    packageDetails(inspection)
                } else {
                    ContentUnavailableView {
                        Label("Widget packages", systemImage: "shippingbox")
                    } description: {
                        Text("Choose a package from the store or a local folder to review its settings and commands.")
                    } actions: {
                        Button("Review Package Folder…", action: chooseFolder)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let error {
                    Divider()
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.1))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func packageDetails(_ inspection: WidgetPackageInspection) -> some View {
        let manifest = inspection.manifest
        let isInstalled = self.isInstalled(inspection)
        let isEnabled = selections.contains { $0.id == manifest.id && $0.version == manifest.version && $0.enabled }
        return VStack(spacing: 0) {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "shippingbox.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 40, height: 40)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(manifest.name).font(.title3.weight(.semibold))
                            if let description = manifest.description {
                                Text(description)
                            }
                            Text("\(manifest.id) · Version \(manifest.version)").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(isEnabled ? "Enabled" : isInstalled ? "Installed" : "Not installed")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isEnabled ? .green : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(isEnabled ? Color.green.opacity(0.15) : Color.primary.opacity(0.06), in: Capsule())
                    }
                    LabeledContent(storeEntry == nil ? "Location" : "Source") {
                        HStack {
                            if let storeEntry {
                                Link(storeEntry.source.absoluteString, destination: storeEntry.source)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text(inspection.directory.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(inspection.directory) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help("Open folder in Finder")
                        }
                    }
                    if let author = manifest.author {
                        LabeledContent("Author", value: author)
                    }
                    if let repository = manifest.repository {
                        LabeledContent("Repository") {
                            Link(repository.absoluteString, destination: repository)
                        }
                    }
                    if let screenshot = inspection.screenshot, let image = NSImage(contentsOf: screenshot) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 200)
                    }
                }
                if manifest.minimumVersion != nil || !manifest.requires.isEmpty || !manifest.permissions.isEmpty || !manifest.hosts.isEmpty {
                    Section("Requirements") {
                        if let minimumVersion = manifest.minimumVersion {
                            LabeledContent("StableBar", value: "\(minimumVersion) or later")
                        }
                        if !manifest.requires.isEmpty {
                            LabeledContent("Tools", value: manifest.requires.joined(separator: ", "))
                            let missing = manifest.missingTools(path: shellEnvironment.withLock { $0["PATH", default: ""] })
                            if !missing.isEmpty {
                                Label("Not found on your login shell’s PATH: \(missing.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                        if !manifest.permissions.isEmpty {
                            LabeledContent("Permissions", value: manifest.permissions.map(\.rawValue.capitalized).joined(separator: ", "))
                        }
                        if !manifest.hosts.isEmpty {
                            LabeledContent("Hosts", value: manifest.hosts.joined(separator: ", "))
                        }
                    }
                }
                if !manifest.settings.isEmpty {
                    Section("Settings") {
                        ForEach(manifest.settings.keys.sorted(), id: \.self) { name in
                            if manifest.settings[name]!.type == "secret" {
                                let isSaved = savedSecrets.contains(name) && secrets[name] == nil
                                LabeledContent(manifest.settings[name]!.title ?? name) {
                                    HStack {
                                        SecureField(manifest.settings[name]!.title ?? name,
                                                    text: Binding(get: { secrets[name, default: ""] }, set: { secrets[name] = $0 }),
                                                    prompt: Text(isSaved ? "Saved" : "Not set"))
                                            .labelsHidden()
                                        if isSaved {
                                            Button("Remove") { secrets[name] = "" }
                                                .buttonStyle(.borderless)
                                        }
                                    }
                                }
                            } else {
                                PackageSettingField(title: manifest.settings[name]!.title ?? name,
                                                    value: Binding(get: { settings[name]! }, set: { settings[name] = $0 }))
                            }
                        }
                    }
                }
                if manifest.kind == .widgets {
                    Section("Commands") {
                        Text("This package contains no commands. StableBar rejects any command in a widgets package, so it needs no command review.")
                            .foregroundStyle(.secondary)
                    }
                } else if manifest.kind != .theme {
                    Section {
                        if inspection.commands.isEmpty {
                            Text("This package declares no commands.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(inspection.commands.enumerated()), id: \.offset) { _, command in
                            Text(command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } header: {
                        Text("Commands")
                    } footer: {
                        Text("Review the commands this package can run, including its profiles. Commands run with your account’s access when the package is enabled.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: 10) {
                Text(reviewing != nil ? "Adding enables these widgets after your review." : isInstalled ? "Enabling pins this version. Select an older installed version to roll back." : "Installation copies the package. Enable it separately after review.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if isInstalled {
                    if reviewing == nil { Button("Uninstall…", role: .destructive) { confirmingUninstall = true } }
                    if isEnabled && reviewing == nil {
                        Button("Disable") { perform { try activate(manifest, enabled: false) } }
                    }
                    Button(reviewing != nil ? "Add widget" : isEnabled ? "Save Settings" : "Enable Version \(manifest.version)") {
                        perform { try enable(inspection) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(error != nil)
                } else {
                    Button(reviewing != nil ? "Add widget" : "Install Version \(manifest.version)") {
                        perform {
                            let installed = try packages.install(inspection.directory)
                            self.inspection = try packages.inspect(installed.directory, settings: settings)
                            storeEntry = nil
                            try loadInstalled()
                            if reviewing != nil, let inspection = self.inspection { try enable(inspection) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(error != nil)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .confirmationDialog("Enable \(manifest.name) \(manifest.version)?",
                            isPresented: Binding(get: { !additions.isEmpty }, set: { if !$0 { additions = [] } })) {
            Button("Enable Version \(manifest.version)") { perform { try activate(manifest, enabled: true) } }
        } message: {
            Text("Compared with the enabled version, this version adds:\n\(additions.joined(separator: "\n"))")
        }
        .confirmationDialog("Uninstall \(manifest.name) \(manifest.version)?", isPresented: $confirmingUninstall) {
            Button("Uninstall Version \(manifest.version)", role: .destructive) {
                perform {
                    try store.uninstallPackage(id: manifest.id, version: manifest.version, fromCustomization: true)
                    self.inspection = nil
                    storeEntry = nil
                    try loadInstalled()
                }
            }
        } message: {
            Text("This version’s files will be deleted and it will be disabled if selected. Other versions, saved settings and Keychain secrets will be kept.")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Review package"
        if panel.runModal() == .OK, let url = panel.url {
            downloading = nil
            perform { try select(url) }
        }
    }

    private func select(_ directory: URL, from entry: PackageIndex.Entry? = nil) throws {
        let manifest = try packages.manifest(at: directory)
        let supplied: [String: ConfigurationValue]
        if reviewing != nil {
            supplied = try WidgetSetup(store: store).savedSettings(for: manifest)
        } else {
            supplied = selections.first { $0.id == manifest.id && $0.version == manifest.version }?.settings ?? [:]
        }
        let values = try manifest.values(supplied)
        let reviewed = try packages.inspect(directory, settings: values)
        settings = values
        secrets = [:]
        savedSecrets = Set(manifest.settings.filter { $0.value.type == "secret" && packageSecretIsSaved("\(manifest.id)/\($0.key)") }.keys)
        inspection = reviewed
        storeEntry = entry
    }

    private func isInstalled(_ inspection: WidgetPackageInspection) -> Bool {
        let installedDirectory = packages.directory.appending(path: inspection.manifest.id).appending(path: inspection.manifest.version)
        return inspection.directory.standardizedFileURL == installedDirectory.standardizedFileURL
    }

    private func loadStore() async {
        do {
            storeEntries = try await PackageIndex.load(from: indexURL).packages
            storeError = nil
        } catch {
            storeError = errorMessage(error)
        }
    }

    private func loadInstalled() throws {
        installed = try packages.list()
        selections = try store.effectiveDocument["packages"]?.decoded([WidgetPackageSelection].self) ?? []
        if let theme = store.effectiveDocument["theme"] { selections.append(try theme.decoded(WidgetPackageSelection.self)) }
    }

    private func enable(_ inspection: WidgetPackageInspection) throws {
        if let enabled = selections.first(where: { $0.id == inspection.manifest.id && $0.enabled && $0.version != inspection.manifest.version }),
           let version = enabled.version {
            let previous = try packages.inspect(packages.directory(id: enabled.id, version: version), settings: enabled.settings)
            additions = inspection.additions(since: previous)
            if !additions.isEmpty { return }
        }
        try activate(inspection.manifest, enabled: true)
    }

    private func activate(_ manifest: WidgetPackageManifest, enabled: Bool) throws {
        if let onEnable, enabled, let inspection {
            try onEnable(inspection, settings)
        } else {
            let edit = ConfigurationEdit(action: manifest.kind == .theme ? .theme : .package, properties: [
                "id": .string(manifest.id), "version": .string(manifest.version),
                "enabled": .bool(enabled), "settings": .object(settings)
            ])
            try store.customizationHistory.change(edit)
        }
        if enabled {
            for (name, value) in secrets {
                try savePackageSecret(value, account: "\(manifest.id)/\(name)")
                if value.isEmpty { savedSecrets.remove(name) } else { savedSecrets.insert(name) }
            }
            secrets = [:]
        }
        try loadInstalled()
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = errorMessage(error)
            if reviewing != nil { store.customizationHistory.error = nil }
        }
    }
}

extension WidgetPackageManifest {
    var versionKey: String { "\(id)/\(version)" }
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
