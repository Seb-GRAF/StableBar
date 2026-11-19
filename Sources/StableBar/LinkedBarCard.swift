import SwiftUI

struct LinkedBarCard: View {
    let candidate: BarLinkCandidate
    let editor: ConfigurationEditor
    var screen: ScreenKind? = nil
    var everyBar = false
    @State private var barWidth: CGFloat = 0

    private var store: BarStore { editor.store }
    private var trying: Bool { candidate.state == .trying }
    private var chosen: Bool { candidate.appliesLook || candidate.replacesWidgets }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "menubar.rectangle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("A shared bar").font(.system(size: 14, weight: .semibold))
                    Text("Pick what to bring to your bar.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Label(trying ? "Trying on your bar" : "From a link", systemImage: trying ? "eye" : "link")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(trying ? Color.accentColor : .secondary)
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss the shared bar")
            }
            preview
            choices
            switch candidate.state {
            case .ready, .trying:
                HStack(spacing: 10) {
                    Text(trying ? "Cancel returns to your bar." : note)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 10)
                    if trying {
                        Button("Cancel", action: candidate.cancelTrial)
                            .accessibilityLabel("Cancel trying the shared bar")
                        Button("Keep", action: use)
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("Keep the shared bar")
                    } else {
                        Button("Try on Bar") { Task { await candidate.tryOnBar(on: screen) } }
                            .disabled(candidate.entries == nil || !chosen)
                        Button("Use this bar", action: use).buttonStyle(.borderedProminent)
                            .disabled(candidate.entries == nil || !chosen)
                    }
                }
            case let .failed(message):
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            case .used: EmptyView()
            }
        }
        .padding(14)
        .modifier(LinkedThemeCardStyle())
        .disabled(candidate.working)
        .task { await candidate.loadStore() }
        // With a review, Use this bar finishes after it, so the card goes when the bar is used rather than when the button returns.
        .onChange(of: candidate.state) { if candidate.state == .used { dismiss() } }
        .sheet(isPresented: Binding(get: { !candidate.reviews.isEmpty }, set: { _ in })) {
            BarLinkReview(candidate: candidate, store: store)
                .frame(width: 540, height: 540)
        }
    }

    private var note: String {
        switch (candidate.appliesLook, candidate.replacesWidgets) {
        case (true, true): "Replaces your widgets and look. Undo brings your bar back."
        case (false, true): "Replaces your widgets. Undo brings your bar back."
        case (true, false): "Replaces your look. Undo brings your bar back."
        case (false, false): "Tick the look or a widget to bring it to your bar."
        }
    }

    private var choices: some View {
        let widgets = candidate.widgets
        return VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Bindable(candidate).appliesLook) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Look: \(candidate.look.choice.manifest.name)")
                    let fonts = candidate.missingFonts
                    if candidate.appliesLook, !fonts.isEmpty {
                        Text(fonts.count == 1
                             ? "Uses the font \(fonts[0]), which isn’t on this Mac. Your bar shows the system font until you install it."
                             : "Uses the fonts \(fonts.formatted(.list(type: .and))), which aren’t on this Mac. Your bar shows the system font until you install them.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    builtIns(widgets).frame(maxWidth: .infinity, alignment: .leading)
                    storeWidgets(widgets).frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 12) {
                    builtIns(widgets)
                    storeWidgets(widgets)
                }
            }
        }
        .font(.system(size: 12))
        .toggleStyle(.checkbox)
        .disabled(trying)
    }

    @ViewBuilder private func builtIns(_ widgets: [BarLinkCandidate.Widget]) -> some View {
        let builtIns = widgets.filter { $0.source == .builtIn }
        if !builtIns.isEmpty {
            section("Built in") { ForEach(builtIns, content: row) }
        }
    }

    @ViewBuilder private func storeWidgets(_ widgets: [BarLinkCandidate.Widget]) -> some View {
        if !candidate.link.packages.isEmpty {
            section("From the Store") {
                ForEach(widgets.filter { $0.source != .builtIn }, content: row)
                if candidate.entries == nil, candidate.state == .ready {
                    Text("Checking the Store…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            rows()
        }
    }

    private func row(_ widget: BarLinkCandidate.Widget) -> some View {
        Toggle(isOn: Binding(get: { widget.source != .unlisted && !candidate.unticked.contains(widget.id) },
                             set: { if $0 { candidate.unticked.remove(widget.id) } else { candidate.unticked.insert(widget.id) } })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(widget.name)
                switch widget.source {
                case .builtIn: EmptyView()
                case let .store(summary):
                    Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).help(summary)
                case .unlisted:
                    Text("No longer in the Store").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(widget.source == .unlisted)
    }

    private var preview: some View {
        let appearance = editor.gallery.previewAppearance
        let look = candidate.appliesLook ? candidate.preview.configuration(for: appearance)
            : store.configuration.map { configuration in screen.map(configuration.onScreen) ?? configuration }
        return GeometryReader { geometry in
            if let look {
                let scale = min(0.8, geometry.size.width / barWidth)
                ThemeSampleBar(look: look, widgets: candidate.previewWidgets)
                    .frame(width: geometry.size.width / scale)
                    .scaleEffect(scale)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background {
                        ThemeSampleBar(look: look, widgets: candidate.previewWidgets)
                            .fixedSize()
                            .hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { barWidth = $0 }
                    }
            }
        }
        .frame(height: 56)
        .background(SampleWallpaper())
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SettingsPalette.groupBorder))
        .environment(\.colorScheme, appearance.colorScheme)
        .accessibilityHidden(true)
    }

    private func use() {
        Task { await candidate.use(on: screen, everyBar: everyBar) }
    }

    private func dismiss() {
        candidate.discard()
        if store.pendingLinks.bar === candidate { store.pendingLinks.bar = nil }
    }
}

/// The Store's review of every package the shared bar's ticked widgets need that runs commands or needs permissions,
/// hosts, tools or secrets, with one button that adds them all.
struct BarLinkReview: View {
    let candidate: BarLinkCandidate
    let store: BarStore
    @State private var library: PackageLibrary
    @State private var drafts: [PackageDraft] = []
    @State private var working = false

    init(candidate: BarLinkCandidate, store: BarStore) {
        self.candidate = candidate
        self.store = store
        _library = State(initialValue: PackageLibrary(store: store, reviewing: true))
    }

    var body: some View {
        let trial = if case .tryOnBar? = candidate.pending { true } else { false }
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.reviews.count == 1 ? "Add \(candidate.reviews[0].manifest.name) from the Store?"
                     : "Add \(candidate.reviews.count) widgets from the Store?")
                    .font(.system(size: 15, weight: .semibold))
                Text(intro).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Form {
                ForEach(drafts, id: \.inspection.manifest.id) { draft in
                    PackageDetailView(store: store, library: library, draft: draft, reviewing: true, reviewingWithOthers: true,
                                      tab: .constant(.overview), additions: .constant([]))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            if let error = library.error ?? drafts.compactMap({ $0.error ?? $0.credentialsError }).first {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .textSelection(.enabled).font(.callout)
            }
            HStack {
                Button("Cancel", action: candidate.cancelReview)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(trial ? "Add and Try" : "Add and Use this bar", action: add)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(drafts.count < candidate.reviews.count)
            }
        }
        .padding(14)
        .disabled(working)
        .task {
            await library.loadInstalled()
            for inspection in candidate.reviews {
                await library.select(inspection.directory, sourceID: PackageSource.storeID, settings: candidate.settings(for: inspection.manifest))
                guard library.error == nil, let draft = library.draft else { return }
                drafts.append(draft)
            }
        }
    }

    /// What the packages will run, reach and need, between them.
    private var intro: String {
        let reviews = candidate.reviews
        let commands = reviews.reduce(0) { $0 + $1.commands.count }
        let hosts = Set(reviews.flatMap(\.manifest.hosts)).sorted()
        let permissions = Set(reviews.flatMap(\.manifest.permissions)).map(\.rawValue.capitalized).sorted()
        var parts: [String] = []
        if commands > 0 { parts.append(commands == 1 ? "run a script" : "run \(commands) commands") }
        if !hosts.isEmpty { parts.append("connect to \(hosts.formatted(.list(type: .and)))") }
        if !permissions.isEmpty { parts.append("need \(permissions.formatted(.list(type: .and))) access") }
        if parts.isEmpty { return "Check what \(reviews.count == 1 ? "it needs" : "they need") before adding \(reviews.count == 1 ? "it" : "them")." }
        return "\(reviews.count == 1 ? "It" : "They") will \(parts.formatted(.list(type: .and)))."
    }

    private func add() {
        working = true
        Task {
            for draft in drafts {
                await library.add(draft, onEnable: { candidate.reviewed($0, settings: $1) })
                guard draft.error == nil, draft.credentialsError == nil else {
                    working = false
                    return
                }
            }
            await candidate.resume()
        }
    }
}
