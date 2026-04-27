import Foundation

struct DayContribution: Identifiable, Sendable {
    let id: String // date string yyyy-MM-dd
    let date: Date
    let linesAdded: Int
    let linesDeleted: Int
    let commits: Int

    var totalLines: Int { linesAdded - linesDeleted }
}

struct WeekSummary: Identifiable, Sendable {
    let id: String // week start date
    let weekStart: Date
    let days: [DayContribution]

    var totalLines: Int { days.reduce(0) { $0 + $1.totalLines } }
    var totalCommits: Int { days.reduce(0) { $0 + $1.commits } }
}

struct RepoCommit: Identifiable, Sendable {
    let id: String          // commit hash
    let message: String
    let added: Int
    let deleted: Int
}

struct RepoDayDetail: Identifiable, Sendable {
    let id: String          // repo name
    let repoName: String
    let added: Int
    let deleted: Int
    let commits: [RepoCommit]

    var net: Int { added - deleted }
}

private let authorEmailPattern = #"^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$"#

func normalizedAuthorEmails(_ emails: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []

    for email in emails {
        let candidate = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard candidate.count <= 254,
              candidate.range(
                of: authorEmailPattern,
                options: [.regularExpression, .caseInsensitive]
              ) != nil,
              seen.insert(candidate).inserted else {
            continue
        }
        result.append(candidate)
    }

    return result
}

@Observable
@MainActor
final class ContributionStore {
    private static let emailsKey = "authorEmails"

    var weeks: [WeekSummary] = []
    var isLoading = false
    var lastRefresh: Date?

    var authorEmails: [String] {
        didSet {
            let normalized = normalizedAuthorEmails(authorEmails)
            if normalized != authorEmails {
                authorEmails = normalized
                return
            }
            UserDefaults.standard.set(authorEmails, forKey: Self.emailsKey)
        }
    }

    var isConfigured: Bool {
        !authorEmails.isEmpty && GitHubClient.checkAuth()
    }

    var currentWeekLines: Int {
        weeks.first?.totalLines ?? 0
    }

    var allDayValues: [Int] {
        weeks.flatMap { $0.days }.map { $0.totalLines }
    }

    var selectedDay: DayContribution?
    var dayDetail: [RepoDayDetail]?
    var isLoadingDetail = false

    init() {
        authorEmails = normalizedAuthorEmails(
            UserDefaults.standard.stringArray(forKey: Self.emailsKey) ?? []
        )
        UserDefaults.standard.set(authorEmails, forKey: Self.emailsKey)
    }

    func loadDayDetail(date: String) async {
        dayDetail = nil
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        guard !authorEmails.isEmpty else { return }
        let client = GitHubClient(emails: authorEmails)
        dayDetail = await client.fetchDayDetail(date: date)
    }

    func refresh() async {
        guard !authorEmails.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        let client = GitHubClient(emails: authorEmails)
        let contributions = await client.fetchContributions()
        weeks = buildWeeks(from: contributions)
        lastRefresh = Date()
    }

    private func buildWeeks(from contributions: [String: (added: Int, deleted: Int, commits: Int)]) -> [WeekSummary] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let weekday = calendar.component(.weekday, from: today)
        let daysFromMonday = (weekday + 5) % 7
        guard let currentMonday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today) else {
            return []
        }

        var result: [WeekSummary] = []

        for weekOffset in 0..<4 {
            guard let weekStart = calendar.date(byAdding: .day, value: -weekOffset * 7, to: currentMonday) else { continue }

            var days: [DayContribution] = []
            for dayOffset in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else { continue }
                if date > today { continue }

                let key = formatter.string(from: date)
                let data = contributions[key]
                days.append(DayContribution(
                    id: key,
                    date: date,
                    linesAdded: data?.added ?? 0,
                    linesDeleted: data?.deleted ?? 0,
                    commits: data?.commits ?? 0
                ))
            }

            result.append(WeekSummary(
                id: formatter.string(from: weekStart),
                weekStart: weekStart,
                days: days
            ))
        }

        return result
    }
}
