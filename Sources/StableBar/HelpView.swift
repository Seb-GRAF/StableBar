import AppKit
import SwiftUI

enum HelpSelection: Hashable {
    case questions, feedback
}

extension EnvironmentValues {
    /// What Star on GitHub shows instead of asking `gh`, so a scene draws the same sidebar everywhere.
    @Entry var starRequestSample: StarRequest.State?
}

/// Settings › Help: the guide's questions, Send feedback, and links to the guide, setup and the repository.
struct HelpView: View {
    @Bindable var editor: ConfigurationEditor
    @Environment(\.starRequestSample) private var sample
    @State private var starRequest = StarRequest(defaults: nil)

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 216)
            Divider()
            switch editor.helpSelection {
            case .questions: QuestionsView(editor: editor)
            case .feedback: FeedbackView(editor: editor)
            }
        }
        .task(id: editor.searchTarget) {
            switch editor.searchTarget {
            case SettingsSearchResult.help.id: editor.helpSelection = .questions
            case SettingsSearchResult.feedback.id: editor.helpSelection = .feedback
            default: return
            }
            editor.searchTarget = nil
        }
    }

    private var sidebar: some View {
        List(selection: $editor.helpSelection) {
            Label("Questions", systemImage: "questionmark.circle").foregroundStyle(.primary).tag(HelpSelection.questions)
            Label("Send feedback", systemImage: "text.bubble").foregroundStyle(.primary).tag(HelpSelection.feedback)
            Section {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Seb-GRAF/StableBar/blob/main/docs/README.md")!)
                } label: {
                    Label("User guide", systemImage: "book")
                }
                Button {
                    NSApp.sendAction(#selector(AppDelegate.showSetup), to: NSApp.delegate, from: nil)
                } label: {
                    Label("Run setup again", systemImage: "sparkles")
                }
                Button {
                    Task { await starRequest.star() }
                } label: {
                    Label {
                        Text(isStarred ? "Starred on GitHub" : "Star on GitHub")
                    } icon: {
                        if starRequest.isStarring {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: isStarred ? "star.fill" : "star")
                        }
                    }
                }
                .disabled(starRequest.isStarring || starRequest.state == .checking)
                .help(starRequest.help)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(SettingsPalette.sidebar)
        .task {
            if let sample {
                starRequest = StarRequest(sample: sample)
            } else {
                await starRequest.refresh()
            }
        }
    }

    /// A request without defaults is answered only by a star.
    private var isStarred: Bool {
        switch starRequest.state {
        case .thanked, .answered: true
        default: false
        }
    }
}

/// Settings › Help › Questions: the guide's Questions page, searchable, one answer open at a time.
private struct QuestionsView: View {
    @Bindable var editor: ConfigurationEditor
    @State private var search = ""

    var body: some View {
        let shown = HelpQuestion.all.filter { $0.matches(search) }
        ScrollViewReader { proxy in
            Form {
                Section {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                        TextField("Search questions", text: $search)
                            .textFieldStyle(.plain)
                            .onExitCommand { search = "" }
                    }
                    ForEach(shown) { question in
                        DisclosureGroup(question.question, isExpanded: Binding(
                            get: { editor.expandedQuestion == question.id },
                            set: { editor.expandedQuestion = $0 ? question.id : nil })) {
                            HelpAnswer(markdown: question.answer)
                        }
                        .id(question.id)
                    }
                    if shown.isEmpty {
                        Text("No question matches \u{201C}\(search)\u{201D}.").foregroundStyle(.secondary)
                    }
                } header: {
                    SettingsSectionTitle("Questions")
                } footer: {
                    Text("Short answers from the user guide's Questions page, for this version of StableBar. Each links to the guide's full section.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Not answered here?") {
                        Button("Send feedback…", action: editor.showFeedback)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .onAppear {
                if let id = editor.expandedQuestion { proxy.scrollTo(id) }
            }
        }
    }
}

/// An answer from the Questions page: paragraphs, one-line bullet lists and fenced code, with inline Markdown.
private struct HelpAnswer: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdown.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, block in
                if block.hasPrefix("```") {
                    Text(block.split(separator: "\n").dropFirst().prefix { !$0.hasPrefix("```") }.joined(separator: "\n"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 6))
                } else if block.hasPrefix("- ") {
                    ForEach(Array(block.split(separator: "\n").enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            Self.inline(String(item.dropFirst(2)))
                        }
                    }
                } else {
                    Self.inline(block)
                }
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }

    /// Links to the guide's pages point at the guide on GitHub.
    private static func inline(_ text: String) -> some View {
        let linked = text.replacingOccurrences(of: #"\]\(([a-z-]+\.md)"#, with: "](https://github.com/Seb-GRAF/StableBar/blob/main/docs/$1",
                                               options: .regularExpression)
        return Text((try? AttributedString(markdown: linked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(linked))
            .fixedSize(horizontal: false, vertical: true)
    }
}
