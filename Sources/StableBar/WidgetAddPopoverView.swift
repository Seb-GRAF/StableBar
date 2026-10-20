import SwiftUI
import Observation

@MainActor @Observable
final class WidgetAddPopoverModel {
    let setup: WidgetSetup
    let position: WidgetPosition
    let before: String?
    var search = "" { didSet { selected = choices.first?.id; pointerLocation = NSEvent.mouseLocation } }
    var selected: String?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private let added: (String) -> Void
    @ObservationIgnored private var pointerLocation = NSEvent.mouseLocation

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
        pointerLocation = NSEvent.mouseLocation
        guard !choices.isEmpty else { selected = nil; return }
        let index = choices.firstIndex { $0.id == selected } ?? 0
        let column = index % columns
        let row = min(max(0, index / columns + offset), (choices.count - 1 - column) / columns)
        selected = choices[row * columns + column].id
    }

    @discardableResult
    func moveColumn(by offset: Int) -> Bool {
        guard search.isEmpty else { return false }
        pointerLocation = NSEvent.mouseLocation
        guard let index = choices.firstIndex(where: { $0.id == selected }),
              (0..<columns).contains(index % columns + offset), choices.indices.contains(index + offset) else { return true }
        selected = choices[index + offset].id
        return true
    }

    func hover(_ id: String, at location: CGPoint) {
        guard location != pointerLocation else { return }
        pointerLocation = location
        selected = id
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
    var measuredChoices: (([String: CGRect]) -> Void)?
    let title = "ADD HERE"
    @FocusState private var searchFocused: Bool
    @State private var addedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            if let review = model.setup.review {
                PackagesView(store: store, reviewing: review.inspection, onEnable: { inspection, settings in
                    addedID = try model.setup.enable(inspection, settings: settings, position: review.position, before: review.before)
                }, onAdded: {
                    if let addedID { model.didAdd(addedID) }
                }, onWorkingChanged: { model.setup.reviewIsWorking = $0 })
                Button("Back", action: model.setup.cancelReview)
                    .disabled(model.setup.reviewIsWorking)
            } else {
                TextField("Search widgets", text: $model.search)
                    .textFieldStyle(.roundedBorder).focused($searchFocused)
                    .accessibilityLabel("Search widgets")
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: model.columns), spacing: 6) {
                            ForEach(model.choices) { choice in
                                choiceButton(choice).id(choice.id)
                                    .background {
                                        if measuredChoices != nil {
                                            GeometryReader { proxy in
                                                Color.clear.preference(key: WidgetAddChoiceFrames.self,
                                                    value: [choice.id: proxy.frame(in: .named("addChoices"))])
                                            }
                                        }
                                    }
                            }
                        }
                        .coordinateSpace(name: "addChoices")
                        .onPreferenceChange(WidgetAddChoiceFrames.self) { measuredChoices?($0) }
                    }
                    .frame(height: min(CGFloat(max(1, model.rowCount)) * 44 + CGFloat(max(0, model.rowCount - 1)) * 6,
                                       max(44, availableSize.height - 140)))
                    .onChange(of: model.selected) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
                .accessibilityIdentifier("Add here choices")
                if model.choices.isEmpty { Text("No widgets found.").font(.callout).foregroundStyle(.secondary) }
                if model.setup.storeUnavailable {
                    Text("Store unavailable. Built-in widgets are ready to add.").font(.caption).foregroundStyle(.secondary)
                    if let error = model.setup.storeError { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    Button("Retry") { Task { await model.setup.load() } }
                }
                if model.setup.isLoading { ProgressView("Loading Store…").controlSize(.small) }
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.name).lineLimit(1)
                    Text(choice.package == nil ? "Built-in" : "Store").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if choice.package != nil {
                    Image(systemName: "arrow.down").font(.caption).accessibilityLabel("Downloads from Store")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).frame(height: 44)
            .contentShape(Rectangle())
            .background(model.selected == choice.id ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(model.setup.requestStarted)
        .onContinuousHover { phase in
            if case .active = phase { model.hover(choice.id, at: NSEvent.mouseLocation) }
        }
        .help(choice.description)
        .accessibilityLabel(choice.name)
        .accessibilityAddTraits(model.selected == choice.id ? [.isSelected] : [])
    }
}

private struct WidgetAddChoiceFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}
