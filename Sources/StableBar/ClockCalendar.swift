import SwiftUI

struct ClockMonth {
    let calendar: Calendar
    let month: Date
    let days: [Date?]

    init(date: Date, offset: Int, timeZone: TimeZone) {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = timeZone
        self.calendar = calendar
        let month = calendar.date(byAdding: .month, value: offset, to: calendar.dateInterval(of: .month, for: date)!.start)!
        self.month = month
        let leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: month)!.count
        days = (0..<42).map { index in
            (leading..<(leading + count)).contains(index) ? calendar.date(byAdding: .day, value: index - leading, to: month) : nil
        }
    }
}

struct ClockCalendar: View {
    let timeZone: String?
    let appearance: WidgetAppearance
    let openCalendar: () -> Void
    @State private var offset = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.fixedDate) private var fixedDate

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = fixedDate ?? context.date
            let zone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
            let month = ClockMonth(date: now, offset: offset, timeZone: zone)
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(formatted(now, in: zone, pattern: nil))
                        .font(.system(size: 34, weight: .medium, design: .rounded)).monospacedDigit()
                    Text(formatted(now, in: zone, pattern: "EEEE, d MMMM yyyy"))
                        .font(.system(size: 12)).opacity(0.6)
                    if timeZone != nil {
                        Text(zone.identifier.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(appearance.accent)
                    }
                }
                Divider().overlay(appearance.foreground.opacity(0.12))
                HStack {
                    Text(formatted(month.month, in: zone, pattern: "MMMM yyyy")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button { offset -= 1 } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                        .help("Previous month").accessibilityLabel("Previous month")
                    Button { offset += 1 } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24) }
                        .help("Next month").accessibilityLabel("Next month")
                }
                .buttonStyle(.borderless)
                VStack(spacing: 5) {
                    HStack(spacing: 0) {
                        ForEach(0..<7) { index in
                            Text(month.calendar.veryShortStandaloneWeekdaySymbols[(month.calendar.firstWeekday - 1 + index) % 7])
                                .font(.system(size: 10, weight: .medium)).opacity(0.45).frame(maxWidth: .infinity)
                        }
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 3) {
                        ForEach(0..<42) { index in
                            if let date = month.days[index] {
                                let today = month.calendar.isDate(date, inSameDayAs: now)
                                Text(String(month.calendar.component(.day, from: date)))
                                    .font(.system(size: 12, weight: today ? .semibold : .regular)).monospacedDigit()
                                    .foregroundStyle(today ? appearance.accentText : appearance.foreground)
                                    .frame(width: 28, height: 28)
                                    .background(today ? appearance.accent : .clear, in: Circle())
                            } else {
                                Color.clear.frame(height: 28)
                            }
                        }
                    }
                    .id(offset).transition(.opacity)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: offset)
                Divider().overlay(appearance.foreground.opacity(0.12))
                HStack {
                    Button("Today") { offset = 0 }.disabled(offset == 0)
                    Spacer()
                    Button(action: openCalendar) { Label("Open Calendar", systemImage: "arrow.up.right") }
                }
                .buttonStyle(.borderless).font(.system(size: 12, weight: .medium))
            }
        }
    }

    private func formatted(_ date: Date, in zone: TimeZone, pattern: String?) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        if let pattern { formatter.dateFormat = pattern } else { formatter.timeStyle = .short }
        return formatter.string(from: date)
    }
}
