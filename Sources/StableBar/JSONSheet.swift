import SwiftUI

/// Edits a widget's or a profile's properties as JSON. `apply` returns the editor's error, nil once applied.
struct JSONSheet: View {
    let title: String
    let apply: ([String: ConfigurationValue]) -> String?
    let close: () -> Void
    @State private var text: String
    @State private var error: String?
    @State private var controller = JSONEditorController()

    init(title: String, text: String, apply: @escaping ([String: ConfigurationValue]) -> String?,
         close: @escaping () -> Void) {
        self.title = title
        self.apply = apply
        self.close = close
        _text = State(initialValue: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            JSONEditor(text: $text, controller: controller)
                .frame(minWidth: 480, idealWidth: 528, maxWidth: .infinity,
                       minHeight: 280, idealHeight: 300, maxHeight: .infinity)
                .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SettingsPalette.groupBorder))
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack(spacing: 8) {
                Text("Removing a property clears it. Includes and templates stay as they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // SwiftUI takes Escape before the editor, so the find bar would never get it to close.
                Button("Cancel", action: close).keyboardShortcut(controller.isFindBarVisible ? nil : .cancelAction)
                Button("Apply", action: applyText).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func applyText() {
        do {
            error = apply(try JSONDecoder().decode([String: ConfigurationValue].self, from: Data(text.utf8)))
        } catch {
            if let problem = jsonSyntaxProblem(error, in: text) {
                self.error = problem.message
                controller.selectLine(problem.line)
            } else {
                self.error = errorMessage(error)
            }
        }
        if error == nil { close() }
    }
}
