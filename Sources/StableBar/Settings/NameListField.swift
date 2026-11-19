import SwiftUI

/// Saves when editing ends rather than as you type, so a comma typed before the next name stays in the field.
struct NameListField: View {
    let title: String
    let prompt: String
    let names: [String]
    let save: ([String]) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .labelsHidden()
            .frame(width: 220)
            .focused($focused)
            .onSubmit(commit)
            .onAppear { text = names.joined(separator: ", ") }
            .onChange(of: names) { if !focused { text = names.joined(separator: ", ") } }
            .onChange(of: focused) { if !focused { commit() } }
    }

    private func commit() {
        guard text != names.joined(separator: ", ") else { return }
        let typed = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if typed != names { save(typed) }
    }
}
