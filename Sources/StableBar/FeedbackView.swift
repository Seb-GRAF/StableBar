import AppKit
import SwiftUI

extension EnvironmentValues {
    /// What Send feedback shows instead of looking at this Mac, so a scene draws the same pane everywhere.
    @Entry var feedbackSample: FeedbackSample?
}

struct FeedbackSample {
    var report: BugReport
    var account: String?
    var agents: [TriageAgent]
}

/// Settings › Status › Send feedback: a bug or an idea, sent through GitHub's issue form, the GitHub CLI or a coding agent.
struct FeedbackView: View {
    let store: BarStore
    @Binding var feedback: Feedback
    @Environment(\.feedbackSample) private var sample
    @State private var account: String?
    @State private var agents: [TriageAgent] = []
    @State private var found: [FoundIssue]?
    @State private var searching = false
    @State private var confirmsPost = false
    @State private var posting = false
    @State private var posted: URL?
    @State private var notice: String?
    @State private var showsReport = false

    var body: some View {
        Form {
            Section {
                Picker("Kind", selection: $feedback.kind) {
                    Text("Something's wrong").tag(Feedback.Kind.bug)
                    Text("An idea").tag(Feedback.Kind.idea)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                TextField("Title", text: $feedback.title)
                ForEach(feedback.kind.questions, id: \.id) { question in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(question.label)
                        Text(question.hint).font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: Binding(get: { feedback.answers[question.id, default: ""] },
                                                 set: { feedback.answers[question.id] = $0 }))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .frame(height: 72)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                            .accessibilityLabel(question.label)
                    }
                }
            } header: {
                SettingsSectionTitle("Send feedback")
            } footer: {
                Text("Keep it to one problem or idea. Your feedback becomes a public issue on GitHub once you send it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if feedback.kind == .bug {
                Section {
                    if !store.crashReports.reports.isEmpty {
                        Picker("Crash", selection: Binding(get: { feedback.crash?.id }, set: { id in
                            feedback.crash = store.crashReports.reports.first { $0.id == id }
                        })) {
                            Text("None").tag(String?.none)
                            ForEach(store.crashReports.reports) { report in
                                Text("\(report.date.formatted(date: .abbreviated, time: .shortened)) · \(report.exception)").tag(Optional(report.id))
                            }
                        }
                    }
                    if let report = feedback.report {
                        DisclosureGroup("Bug report", isExpanded: $showsReport) {
                            ScrollView([.vertical, .horizontal]) {
                                Text(report.markdown).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                            }
                            .frame(height: 200)
                            .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SettingsPalette.groupBorder))
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } header: {
                    SettingsSectionTitle("Included")
                } footer: {
                    Text("The bug report lists StableBar's version, macOS, your displays, access, theme, packages, problems and crashes from the last 30 days, with your home folder written as ~ and no configuration values. Widget problems show what their scripts printed, so check them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button("Find similar issues", action: search)
                        .disabled(feedback.title.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                    if searching { ProgressView().controlSize(.small) }
                }
                if let found {
                    if found.isEmpty {
                        Text("No issue matches the title's words.").foregroundStyle(.secondary)
                    }
                    ForEach(found) { issue in
                        Link(destination: issue.htmlUrl) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("#\(String(issue.number)) \(issue.title)").multilineTextAlignment(.leading)
                                Spacer()
                                Text(issue.state == "open" ? "Open" : "Closed").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                SettingsSectionTitle("Similar issues")
            } footer: {
                Text("If one of these is your problem or idea, comment on it or add a 👍 instead. The search sends only the title's words to GitHub.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Open on GitHub…") { NSWorkspace.shared.open(feedback.issueURL()) }
                    if let account {
                        Button("Post as @\(account)…") { confirmsPost = true }
                            .disabled(!feedback.isComplete || posting)
                    }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(feedback.markdown, forType: .string)
                        notice = "Copied."
                    }
                    if posting { ProgressView().controlSize(.small) }
                }
                if !agents.isEmpty {
                    HStack {
                        ForEach(agents, id: \.self) { agent in
                            Button("Investigate with \(agent.label)…") { investigate(agent) }
                        }
                    }
                }
                if let posted { Link("Posted \(posted.absoluteString)", destination: posted) }
                if let notice { Text(notice).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            } header: {
                SettingsSectionTitle("Send")
            } footer: {
                Text("Open on GitHub fills in the issue form in your browser, and nothing is sent until you submit it. Post uses the GitHub CLI after you confirm. Investigate opens Terminal on StableBar triage: a coding agent looks into it and asks before posting anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(feedback.kind == .bug && feedback.report == nil)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .confirmationDialog("Post this issue on GitHub as @\(account ?? "")?", isPresented: $confirmsPost) {
            Button("Post", action: post)
        } message: {
            Text("Everyone can read it. Check the title, your answers and the bug report first.")
        }
        .task {
            if let sample {
                feedback.report = sample.report
                account = sample.account
                agents = sample.agents
                return
            }
            agents = TriageAgent.installed(path: shellEnvironment.withLock { $0["PATH", default: ""] }).map(\.agent)
            await store.crashReports.refresh()
            feedback.report = await store.bugReport()
            account = await Feedback.gitHubAccount()
        }
    }

    private func search() {
        searching = true
        Task {
            do {
                found = try await feedback.similarIssues()
                notice = nil
            } catch {
                found = nil
                notice = "GitHub's search didn't answer: \(error.localizedDescription)"
            }
            searching = false
        }
    }

    private func post() {
        posting = true
        notice = nil
        Task {
            do {
                posted = try await feedback.post()
                feedback.title = ""
                feedback.answers = [:]
                feedback.crash = nil
                found = nil
            } catch {
                notice = "Couldn't post: \(error.localizedDescription)"
            }
            posting = false
        }
    }

    private func investigate(_ agent: TriageAgent) {
        do {
            try Triage.openInTerminal(agent, configuration: store.configurationURL, notes: feedback.markdown)
            notice = "\(agent.label) is starting in Terminal."
        } catch {
            notice = "Couldn't open Terminal: \(error.localizedDescription)"
        }
    }
}
