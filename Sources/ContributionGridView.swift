import SwiftUI

struct ContributionGridView: View {
    let weeks: [WeekSummary]
    let allValues: [Int]
    var onDayTapped: ((DayContribution) -> Void)?

    @State private var hoveredDay: DayContribution?

    private let cellSize: CGFloat = 20
    private let cellSpacing: CGFloat = 4
    private let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private let hoverDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMM d"
        return f
    }()

    private let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            Text("Contributions")
                .font(.system(size: 14, weight: .semibold))

            // Grid
            Grid(horizontalSpacing: cellSpacing, verticalSpacing: cellSpacing) {
                // Day labels header
                GridRow {
                    Color.clear
                        .frame(width: 56, height: 1)
                    ForEach(Array(dayLabels.enumerated()), id: \.offset) { _, day in
                        Text(day)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: cellSize)
                    }
                    Color.clear
                        .frame(width: 120, height: 1)
                }

                // Week rows (newest first)
                ForEach(weeks) { week in
                    GridRow {
                        Text(weekLabel(for: week))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)

                        ForEach(0..<7, id: \.self) { dayIndex in
                            cellView(for: dayForIndex(dayIndex, in: week))
                        }

                        Text(weekSummaryText(week))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .leading)
                            .lineLimit(1)
                    }
                }
            }

            // Hover detail
            if let day = hoveredDay {
                HStack(spacing: 6) {
                    let level = ColorScale.level(for: day.totalLines, allValues: allValues)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ColorScale.color(for: level))
                        .frame(width: 10, height: 10)
                    Text(hoverDetailText(for: day))
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
                .transition(.opacity)
            } else {
                // Legend
                HStack(spacing: 5) {
                    Text("Less")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    ForEach(0..<5, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(ColorScale.color(for: level))
                            .frame(width: 12, height: 12)
                    }
                    Text("More")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .animation(.easeInOut(duration: 0.15), value: hoveredDay?.id)
    }

    private func weekLabel(for week: WeekSummary) -> String {
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: now)
        let daysFromMonday = (weekday + 5) % 7
        guard let currentMonday = calendar.date(byAdding: .day, value: -daysFromMonday, to: now) else {
            return dateFormatter.string(from: week.weekStart)
        }

        if calendar.isDate(week.weekStart, inSameDayAs: currentMonday) {
            return "This wk"
        }
        if let lastMonday = calendar.date(byAdding: .day, value: -7, to: currentMonday),
           calendar.isDate(week.weekStart, inSameDayAs: lastMonday) {
            return "Last wk"
        }
        return dateFormatter.string(from: week.weekStart)
    }

    private func dayForIndex(_ index: Int, in week: WeekSummary) -> DayContribution? {
        let calendar = Calendar.current
        return week.days.first { day in
            let dayWeekday = calendar.component(.weekday, from: day.date)
            let mondayBased = (dayWeekday + 5) % 7
            return mondayBased == index
        }
    }

    @ViewBuilder
    private func cellView(for day: DayContribution?) -> some View {
        if let day {
            let level = ColorScale.level(for: day.totalLines, allValues: allValues)
            RoundedRectangle(cornerRadius: 4)
                .fill(ColorScale.color(for: level))
                .frame(width: cellSize, height: cellSize)
                .onHover { hovering in
                    hoveredDay = hovering ? day : nil
                }
                .onTapGesture {
                    onDayTapped?(day)
                }
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.sRGB, red: 0.15, green: 0.15, blue: 0.17, opacity: 1))
                .frame(width: cellSize, height: cellSize)
        }
    }

    private func hoverDetailText(for day: DayContribution) -> String {
        let dateStr = hoverDateFormatter.string(from: day.date)
        if day.totalLines == 0 {
            return "\(dateStr) -- no contributions"
        }
        let added = formatNumber(day.linesAdded)
        let deleted = formatNumber(day.linesDeleted)
        return "\(dateStr) -- +\(added) -\(deleted), \(day.commits) commit\(day.commits == 1 ? "" : "s")"
    }

    private func weekSummaryText(_ week: WeekSummary) -> String {
        let loc = formatNumber(week.totalLines)
        return "\(loc) / \(week.totalCommits)c"
    }

    private func formatNumber(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
