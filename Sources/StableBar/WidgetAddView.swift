import SwiftUI

struct WidgetAddView: View {
    @Bindable var setup: WidgetSetup
    let store: BarStore
    let position: WidgetPosition
    let added: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selected: String?

    private var choices: [WidgetAddChoice] { setup.choices.filter { $0.matches(search) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add widget").font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if let review = setup.review {
                PackagesView(store: store, reviewing: review.inspection) { inspection, settings in
                    if let id = try setup.enable(inspection, settings: settings, position: review.position, before: review.before) { added(id) }
                }
                Divider()
                HStack {
                    Button("Back", action: setup.cancelReview)
                    Spacer()
                }.padding(12)
            } else {
                TextField("Search widgets", text: $search).textFieldStyle(.roundedBorder).padding(12)
                List(selection: $selected) {
                    Section("Widgets") {
                        ForEach(choices.filter { !$0.isScript }) { choice in row(choice) }
                    }
                    Section("Script") {
                        ForEach(choices.filter(\.isScript)) { choice in row(choice) }
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let choice = choices.first(where: { ids.contains($0.id) }), let basic = choice.basicChoice {
                        Button(choice.basicActionTitle) { add(basic) }
                    }
                } primaryAction: { ids in
                    if let choice = choices.first(where: { ids.contains($0.id) }) { add(choice) }
                }
                if let error = setup.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        .textSelection(.enabled).padding(12)
                }
                Divider()
                HStack {
                    if setup.storeUnavailable { Text("Store unavailable. Built-in widgets are ready to add.").font(.callout).foregroundStyle(.secondary) }
                    if setup.isAdding { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Add widget") {
                        if let choice = choices.first(where: { $0.id == selected }) { add(choice) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.requestStarted || !choices.contains { $0.id == selected })
                }.padding(16)
            }
        }
        .frame(width: 680, height: 620)
        .task { setup.beginSheet(); await setup.load() }
    }

    private func row(_ choice: WidgetAddChoice) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(choice.name)
                    if choice.package != nil { Text("Store").font(.caption).foregroundStyle(.secondary) }
                }
                Text(choice.description).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        } icon: { Image(systemName: choice.symbol).frame(width: 24) }
        .padding(.vertical, 4)
        .tag(choice.id)
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let basic = choice.basicChoice {
                Button(choice.basicActionTitle) { add(basic) }
            }
        }
    }

    private func add(_ choice: WidgetAddChoice) {
        Task { if let id = await setup.add(choice, to: position) { added(id) } }
    }
}
