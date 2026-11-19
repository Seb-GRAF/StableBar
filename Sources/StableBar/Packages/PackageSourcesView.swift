import AppKit
import SwiftUI

/// The Add and Edit forms of a package source. The token stays in memory until the source is saved.
@MainActor @Observable
final class PackageSourceDraft {
    enum State: Equatable {
        case idle, checking, found(widgets: Int, themes: Int), failed(String), duplicate(String)

        /// "Found 3 packages: 2 widgets, 1 theme", leaving out a kind the index doesn't list.
        var summary: String? {
            guard case let .found(widgets, themes) = self else { return nil }
            guard widgets + themes > 0 else { return "Found no packages" }
            let parts = [(widgets, "widget"), (themes, "theme")].filter { $0.0 > 0 }.map { counted($0.0, $0.1) }
            return "Found \(counted(widgets + themes, "package")): \(parts.joined(separator: ", "))"
        }
    }

    /// The source being edited; nil when adding one.
    let editing: PackageSource?
    /// The configured sources, read when needed: they can change while the form is open.
    private let existing: @MainActor () -> [PackageSource]
    var name: String
    /// A new URL or token needs a new check before it can be saved.
    var urlText: String { didSet { if urlText != oldValue { state = .idle } } }
    var token: String { didSet { if token != oldValue { state = .idle } } }
    private(set) var state: State = .idle
    /// True when the form was filled in from a join link, which shows a note to review the source.
    let fromLink: Bool
    /// The id a join link asked for; used while it is valid and free.
    private let linkID: String?

    convenience init(existing: [PackageSource], editing: PackageSource? = nil, link: PackageSourceLink? = nil) {
        self.init(existing: { existing }, editing: editing, link: link)
    }

    /// Judges ids and URLs against the library's configured sources, not the ones its last catalog load listed.
    convenience init(library: PackageLibrary, editing: PackageSource? = nil, link: PackageSourceLink? = nil) {
        self.init(existing: { library.currentSources() }, editing: editing, link: link)
    }

    init(existing: @escaping @MainActor () -> [PackageSource], editing: PackageSource? = nil, link: PackageSourceLink? = nil) {
        self.existing = existing
        self.editing = editing
        name = editing?.name ?? link?.name ?? ""
        urlText = editing?.url.absoluteString ?? link?.url.absoluteString ?? ""
        token = ""
        fromLink = link != nil
        linkID = link?.id
    }

    var id: String {
        if let editing { return editing.id }
        let taken = Set(existing().map(\.id))
        if let linkID, !taken.contains(linkID), linkID != PackageSource.storeID, linkID != PackageSource.localID,
           (try? validatePackageComponent(linkID)) != nil { return linkID }
        return PackageSource.newID(for: name, taken: taken)
    }

    var source: PackageSource? {
        url.flatMap { try? PackageSource.validated(id: id, name: trimmedName, url: $0) }
    }

    var canSave: Bool {
        guard source != nil else { return false }
        if case .found = state { return true }
        // A rename keeps the index that was already loaded.
        return editing != nil && url == editing?.url && newToken == nil && trimmedName != editing?.name
    }

    /// The token typed into the form; nil when the field is blank.
    var newToken: String? {
        token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : token
    }

    /// The host the token would be sent to.
    var host: String? { url?.host() }

    func check(using library: PackageLibrary) async {
        let checkedURL = urlText, checkedToken = token
        guard let url, !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { state = .idle; return }
        if let other = existing().first(where: { $0.id != editing?.id && $0.url == url }) {
            state = .duplicate(other.name)
            return
        }
        let candidate: PackageSource
        do { candidate = try PackageSource.validated(id: id, name: trimmedName.isEmpty ? id : trimmedName, url: url) }
        catch { state = .failed(errorMessage(error)); return }
        state = .checking
        let result: State
        do {
            // Editing without a new token checks with the saved one; adding without one sends none.
            let index = try await library.check(candidate, token: editing != nil && newToken == nil ? nil : token)
            let themes = index.packages.filter { $0.kind == .theme }.count
            result = .found(widgets: index.packages.count - themes, themes: themes)
        } catch {
            let detail = sourceErrorDetail(error)
            result = .failed(detail.prefix(1).uppercased() + detail.dropFirst())
        }
        // A check that finishes after the URL or token changed says nothing about them.
        guard checkedURL == urlText, checkedToken == token else { return }
        state = result
    }

    private var url: URL? { URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Settings › Store › Sources…: the StableBar Store and the private sources, with their forms.
struct PackageSourcesView: View {
    let library: PackageLibrary
    /// A join link to open the Add source form with; cleared once the form is open.
    @Binding var link: PackageSourceLink?
    @State private var form: SourceForm?
    @State private var savedTokens: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    init(library: PackageLibrary, link: Binding<PackageSourceLink?> = .constant(nil)) {
        self.library = library
        _link = link
    }

    private struct SourceForm: Identifiable {
        let id = UUID()
        let draft: PackageSourceDraft
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Package sources").font(.headline)
                Spacer()
                Button("Add source…", systemImage: "plus") { form = SourceForm(draft: PackageSourceDraft(library: library)) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 0) {
                        ForEach(library.sources) { source in
                            row(source).overlay(alignment: .top) {
                                if !source.isStore { SettingsPalette.separator.frame(height: 1) }
                            }
                        }
                    }
                    .background(SettingsPalette.group, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.groupBorder))
                    Text("Saved in config.json, so a team can share this list through an include. Tokens are kept in the login Keychain and sent only to the host of their own source.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 460)
        .background(SettingsPalette.background)
        .task(id: library.sources) { savedTokens = await library.savedTokens() }
        .onAppear(perform: openLink)
        .onChange(of: link) { openLink() }
        .sheet(item: $form) { form in
            let editing = form.draft.editing
            PackageSourceForm(library: library, draft: form.draft,
                              tokenSaved: editing.map { savedTokens.contains($0.id) } ?? false,
                              editable: editing.map(library.isEditable) ?? true,
                              definingFile: editing.flatMap(library.definingFile)) {
                Task { savedTokens = await library.savedTokens() }
            }
        }
    }

    private func openLink() {
        guard let link else { return }
        form = SourceForm(draft: PackageSourceDraft(library: library, link: link))
        self.link = nil
    }

    @ViewBuilder private func row(_ source: PackageSource) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: source.isStore ? "shippingbox.fill" : "lock.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(source.isStore ? Color.accentColor : .secondary)
                .frame(width: 30, height: 30)
                .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).fontWeight(.medium).lineLimit(1)
                if source.isStore {
                    Text("\(source.host) · \(packageCount(source)) packages · read by a maintainer")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(source.url.absoluteString)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let status = status(source) { status.font(.system(size: 11)).lineLimit(2) }
            }
            Spacer(minLength: 8)
            if source.isStore {
                Text("Always on").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                Button("Copy join link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(PackageSourceLink(source: source).link.absoluteString, forType: .string)
                }
                .controlSize(.small)
                .accessibilityLabel("Copy join link for \(source.name)")
                Button("Edit") {
                    form = SourceForm(draft: PackageSourceDraft(library: library, editing: source))
                }
                .controlSize(.small)
                .accessibilityLabel("Edit \(source.name)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func packageCount(_ source: PackageSource) -> Int {
        library.entries.filter { $0.sourceID == source.id }.count
    }

    /// The count or the error, then whether a token is saved and which file defines a read-only source.
    private func status(_ source: PackageSource) -> Text? {
        if source.isStore {
            return library.sourceErrors[source.id].map { Text(sentence($0)).foregroundStyle(.red) }
        }
        var text = if let error = library.sourceErrors[source.id] {
            Text(sentence(error)).foregroundStyle(.red)
        } else if library.loadedSources.contains(source.id) {
            Text(counted(packageCount(source), "package")).foregroundStyle(.secondary)
        } else {
            Text("Not loaded yet").foregroundStyle(.secondary)
        }
        if savedTokens.contains(source.id) { text = text + Text(" · token saved").foregroundStyle(.secondary) }
        if !library.isEditable(source) {
            text = text + Text(" · from \(library.definingFile(source) ?? "an include")").foregroundStyle(.secondary)
        }
        return text
    }

    private func sentence(_ detail: String) -> String {
        detail.prefix(1).uppercased() + detail.dropFirst()
    }
}

private struct PackageSourceForm: View {
    let library: PackageLibrary
    @Bindable var draft: PackageSourceDraft
    let tokenSaved: Bool
    /// False for a source from an include: only its token can change here.
    let editable: Bool
    let definingFile: String?
    let onChange: () -> Void
    @State private var working = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.editing.map { "Edit \($0.name)" } ?? "Add a package source").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("Name", text: $draft.name).labelsHidden()
                        if draft.editing == nil && !draft.name.isEmpty {
                            Text(draft.id).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                }
                .disabled(!editable)
                GridRow {
                    Text("Index URL")
                    TextField("Index URL", text: $draft.urlText, prompt: Text("https://…/index.json")).labelsHidden()
                }
                .disabled(!editable)
                GridRow {
                    Text("Token")
                    VStack(alignment: .leading, spacing: 3) {
                        SecureField("Token", text: $draft.token, prompt: Text(tokenSaved ? "Saved" : "")).labelsHidden()
                        Text(tokenHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if draft.fromLink {
                Label("Opened from a link. Packages from this source can run commands once you review them. Add it only if you trust who publishes it.",
                      systemImage: "link")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !editable {
                Text("From \(definingFile ?? "an include"). Change its name and URL in that file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            status.frame(minHeight: 18, alignment: .leading)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if let source = draft.editing {
                    if tokenSaved {
                        Button("Remove token") { perform { try await library.removeToken(source.id) } }
                    }
                    if editable {
                        Button("Remove source", role: .destructive) { perform { try await library.removeSource(source.id) } }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.editing == nil ? "Add source" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSave || working)
            }
            .disabled(working)
        }
        .padding(24)
        .frame(width: 480)
        .task(id: draft.urlText + draft.token) {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await draft.check(using: library)
        }
    }

    private var tokenHint: String {
        "Optional. Kept in the login Keychain and sent only to \(draft.host ?? "the host of the index URL")."
    }

    @ViewBuilder private var status: some View {
        switch draft.state {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .found:
            Label(draft.state.summary ?? "", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(SettingsPalette.success)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                // The automatic check runs only after an edit, so a failure from a blip or an unpublished index can be retried.
                Button("Check again") { Task { await draft.check(using: library) } }
                    .controlSize(.small)
            }
        case let .duplicate(name):
            Label("You already have this source as \(name).", systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func save() {
        guard let source = draft.source else { return }
        let adding = draft.editing == nil, token = draft.token, newToken = draft.newToken
        perform {
            if adding { try await library.addSource(source, token: token) }
            else { try await library.updateSource(source, token: newToken) }
        }
    }

    /// Runs a change, then closes the form; an error keeps it open.
    private func perform(_ change: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await change()
                onChange()
                dismiss()
            } catch {
                self.error = errorMessage(error)
            }
        }
    }
}

/// "1 package", "2 packages": `count` and the noun, plural unless it's one.
func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}
