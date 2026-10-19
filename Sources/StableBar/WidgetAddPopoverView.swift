import SwiftUI
import Observation

@MainActor @Observable
final class WidgetAddPopoverModel {
    let setup: WidgetSetup
    let position: WidgetPosition
    let before: String?
    var search = "" { didSet { selected = choices.first?.id } }
    var selected: String?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private let added: (String) -> Void

    init(setup: WidgetSetup, position: WidgetPosition, before: String?, added: @escaping (String) -> Void) {
        self.setup = setup
        self.position = position
        self.before = before
        self.added = added
        selected = setup.choices.first?.id
    }

    var choices: [WidgetAddChoice] { setup.choices.filter { $0.matches(search) } }
    let columns = 2
    var rowCount: Int { min(10, (choices.count + columns - 1) / columns) }

    func move(by offset: Int) {
        guard !choices.isEmpty else { selected = nil; return }
        let index = choices.firstIndex { $0.id == selected } ?? 0
        selected = choices[min(max(0, index + offset), choices.count - 1)].id
    }

    func addSelected() {
        if let choice = choices.first(where: { $0.id == selected }) { add(choice) }
    }

    func add(_ choice: WidgetAddChoice) {
        guard !setup.requestStarted, request == nil else { return }
        request = Task {
            defer { request = nil }
            if let id = await setup.add(choice, to: position, before: before) { added(id) }
        }
    }

    func cancel() { request?.cancel() }
    func didAdd(_ id: String) { added(id) }
}

struct WidgetAddPopoverView: View {
    @Bindable var model: WidgetAddPopoverModel
    let store: BarStore
    var availableSize = CGSize(width: 540, height: 620)
    var changed: () -> Void = {}
    let title = "ADD HERE"
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            if let review = model.setup.review {
                PackagesView(store: store, reviewing: review.inspection) { inspection, settings in
                    if let id = try model.setup.enable(inspection, settings: settings, position: review.position, before: review.before) {
                        model.didAdd(id)
                    }
                }
                Button("Back", action: model.setup.cancelReview)
            } else {
                TextField("Search widgets", text: $model.search)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .accessibilityLabel("Search widgets")
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: model.columns), spacing: 6) {
                            ForEach(model.choices) { choice in
                                choiceButton(choice).id(choice.id)
                            }
                        }
                    }
                    .frame(height: min(CGFloat(max(1, model.rowCount)) * 36 + CGFloat(max(0, model.rowCount - 1)) * 6,
                                       max(36, availableSize.height - 140)))
                    .onChange(of: model.selected) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
                .accessibilityIdentifier("Add here choices")
                if model.choices.isEmpty { Text("No widgets found.").font(.callout).foregroundStyle(.secondary) }
                if model.setup.storeUnavailable {
                    Text("Store unavailable. Built-in widgets are ready to add.").font(.caption).foregroundStyle(.secondary)
                }
                if model.setup.isAdding { ProgressView().controlSize(.small) }
                if let error = model.setup.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .frame(width: min(model.setup.review == nil ? 340 : 540, availableSize.width))
        .frame(height: model.setup.review == nil ? nil : min(540, availableSize.height))
        .frame(maxHeight: availableSize.height)
        .task {
            model.setup.beginSheet()
            searchFocused = true
            await model.setup.load()
            model.selected = model.choices.first?.id
            changed()
        }
        .onChange(of: model.search) { _, _ in changed() }
        .onChange(of: model.setup.review?.id) { _, id in
            if id == nil { searchFocused = true }
            changed()
        }
        .onChange(of: model.setup.error) { _, _ in changed() }
        .onChange(of: model.setup.isAdding) { _, _ in changed() }
    }

    private func choiceButton(_ choice: WidgetAddChoice) -> some View {
        Button { model.add(choice) } label: {
            HStack(spacing: 7) {
                Image(systemName: choice.symbol).frame(width: 18)
                Text(choice.name).lineLimit(1)
                Spacer(minLength: 0)
                if choice.package != nil {
                    Image(systemName: "arrow.down").font(.caption).accessibilityLabel("Downloads from Store")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).frame(height: 36)
            .contentShape(Rectangle())
            .background(model.selected == choice.id ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(model.setup.requestStarted)
        .onHover { if $0 { model.selected = choice.id } }
        .help(choice.description)
        .accessibilityLabel(choice.name)
        .accessibilityAddTraits(model.selected == choice.id ? [.isSelected] : [])
        .contextMenu {
            if let basic = choice.basicChoice { Button(choice.basicActionTitle) { model.add(basic) } }
        }
        .accessibilityActions {
            if let basic = choice.basicChoice { Button(choice.basicActionTitle) { model.add(basic) } }
        }
    }
}
