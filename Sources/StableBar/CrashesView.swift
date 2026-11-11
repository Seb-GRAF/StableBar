import AppKit
import SwiftUI

/// Settings › Status › Crashes: StableBar's crashes from the last 30 days, from the reports macOS keeps on this Mac.
struct CrashesView: View {
    let crashes: CrashReports
    @State private var newIDs: Set<String> = []
    @State private var shownID: String?
    @State private var copiedID: String?

    var body: some View {
        Form {
            Section {
                if crashes.reports.isEmpty {
                    Label("No crashes in the last 30 days", systemImage: "checkmark.circle.fill").foregroundStyle(SettingsPalette.success)
                }
            } header: {
                SettingsSectionTitle("Crashes")
            } footer: {
                Text("macOS saves a report each time StableBar quits unexpectedly. StableBar lists the last 30 days of them and sends nothing. Report on GitHub opens the bug report form with the crash filled in, for you to check before submitting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(crashes.reports) { report in
                Section {
                    LabeledContent("Exception", value: [report.exception, report.subtype].compactMap { $0 }.joined(separator: ", "))
                    if let location = report.location {
                        LabeledContent("Where") {
                            Text(location).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).multilineTextAlignment(.trailing)
                        }
                    }
                    if let message = report.message {
                        Text(message).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    }
                    HStack {
                        Button("Copy report") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report.markdown, forType: .string)
                            copiedID = report.id
                        }
                        Button("Report on GitHub…") { NSWorkspace.shared.open(report.issueURL()) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([report.file]) }
                        Spacer()
                        Button("Dismiss") { crashes.dismiss(report) }
                    }
                    if copiedID == report.id {
                        Text("Report copied. Paste it into a GitHub issue.").font(.callout).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Report", isExpanded: Binding(get: { shownID == report.id }, set: { shownID = $0 ? report.id : nil })) {
                        ScrollView([.vertical, .horizontal]) {
                            Text(report.markdown).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                        .frame(height: 240)
                        .background(SettingsPalette.field, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(SettingsPalette.groupBorder))
                    }
                } header: {
                    HStack(spacing: 6) {
                        SettingsSectionTitle("\(report.date.formatted(date: .abbreviated, time: .shortened)) · StableBar \(report.versionName)")
                        if newIDs.contains(report.id) {
                            Text("New").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.red, in: Capsule())
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task {
            await crashes.refresh()
            newIDs = Set(crashes.unseen.map(\.id))
            crashes.markSeen()
        }
    }
}
