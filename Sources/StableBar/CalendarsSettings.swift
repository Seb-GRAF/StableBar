import EventKit
import SwiftUI

extension EnvironmentValues {
    /// Calendar titles by account that the Calendars control lists instead of asking EventKit, so a scene draws the same page everywhere.
    @Entry var calendarsSample: [String: [String]]?
}

/// The calendars a calendar provider reads. Its `calendars` names them by title, and an empty list reads every calendar.
struct CalendarsSettings: View {
    let editor: ConfigurationEditor
    let widget: WidgetConfiguration
    let selected: [String]
    @Environment(\.calendarsSample) private var sample
    @State private var accounts: [String: [String]]?

    var body: some View {
        Group {
            if let accounts {
                let titles = Set(accounts.values.joined()).sorted()
                let shown = selected.isEmpty ? titles : selected
                SettingRow(title: "All calendars", hint: "Includes calendars you add later") {
                    Toggle("All calendars", isOn: Binding(get: { selected.isEmpty }, set: { write($0 ? [] : titles) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                ForEach(accounts.keys.sorted(), id: \.self) { account in
                    calendarList(account, titles: accounts[account]!, shown: shown)
                }
                let missing = selected.filter { !titles.contains($0) }
                if !missing.isEmpty {
                    calendarList("Not found on this Mac", titles: missing, shown: shown)
                }
            } else {
                SourcePermissionList(permissions: [.calendars]) { load() }.groupRow()
            }
        }
        .task { load() }
    }

    private func calendarList(_ title: String, titles: [String], shown: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            ForEach(titles, id: \.self) { calendar in
                Toggle(calendar, isOn: Binding(get: { shown.contains(calendar) }, set: {
                    write($0 ? shown + [calendar] : shown.filter { $0 != calendar })
                }))
                .toggleStyle(.checkbox)
            }
        }
        .labeledContentStyle(.automatic)
        .groupRow()
    }

    private func write(_ titles: [String]) {
        editor.setProvider(["calendars": titles.isEmpty ? .null : .array(titles.map(ConfigurationValue.string))], for: widget)
    }

    private func load() {
        accounts = sample ?? (EKEventStore.authorizationStatus(for: .event) == .fullAccess
            ? Dictionary(grouping: EKEventStore().calendars(for: .event)) { $0.source.title }.mapValues { Set($0.map(\.title)).sorted() }
            : nil)
    }
}
