import Foundation

actor GitHubClient {
    private let emails: [String]
    private let graphqlBatchSize = 30

    init(emails: [String]) {
        self.emails = emails
    }

    // MARK: - Public API

    func fetchContributions() async -> [String: (added: Int, deleted: Int, commits: Int)] {
        guard !emails.isEmpty else { return [:] }

        let since = fourWeeksAgoISO()
        let commits = await searchAllCommits(since: since)
        guard !commits.isEmpty else { return [:] }

        // Fetch stats via GraphQL in batches
        let withStats = await fetchStats(for: commits)

        // Aggregate by date
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFrac = ISO8601DateFormatter()
        isoFormatterNoFrac.formatOptions = [.withInternetDateTime]

        var combined: [String: (added: Int, deleted: Int, commits: Int)] = [:]

        for c in withStats {
            let date: Date? = isoFormatter.date(from: c.date) ?? isoFormatterNoFrac.date(from: c.date)
            guard let d = date else { continue }
            let key = dateFormatter.string(from: d)
            let existing = combined[key] ?? (0, 0, 0)
            combined[key] = (existing.added + c.added, existing.deleted + c.deleted, existing.commits + 1)
        }

        return combined
    }

    func fetchDayDetail(date: String) async -> [RepoDayDetail] {
        guard !emails.isEmpty else { return [] }

        let since = fourWeeksAgoISO()
        let commits = await searchAllCommits(since: since)
        let withStats = await fetchStats(for: commits)

        // Filter to target date and group by repo
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFrac = ISO8601DateFormatter()
        isoFormatterNoFrac.formatOptions = [.withInternetDateTime]

        var repoDetails: [String: (added: Int, deleted: Int, commits: [RepoCommit])] = [:]

        for c in withStats {
            let parsed: Date? = isoFormatter.date(from: c.date) ?? isoFormatterNoFrac.date(from: c.date)
            guard let d = parsed else { continue }
            let key = dateFormatter.string(from: d)
            guard key == date else { continue }

            let repoName = c.repo.split(separator: "/").last.map(String.init) ?? c.repo
            var entry = repoDetails[repoName] ?? (0, 0, [])
            entry.added += c.added
            entry.deleted += c.deleted
            entry.commits.append(RepoCommit(
                id: String(c.sha.prefix(8)),
                message: c.message,
                added: c.added,
                deleted: c.deleted
            ))
            repoDetails[repoName] = entry
        }

        return repoDetails.map { name, detail in
            RepoDayDetail(id: name, repoName: name, added: detail.added, deleted: detail.deleted, commits: detail.commits)
        }.sorted { abs($0.added - $0.deleted) > abs($1.added - $1.deleted) }
    }

    // MARK: - Search API (all branches)

    private struct SearchCommit {
        let sha: String
        let repo: String // owner/name
        let date: String
        let message: String
    }

    private struct StatsCommit {
        let sha: String
        let repo: String
        let date: String
        let message: String
        let added: Int
        let deleted: Int
    }

    private func searchAllCommits(since: String) async -> [SearchCommit] {
        var allCommits: [SearchCommit] = []
        var seenSHAs = Set<String>()

        // Search per-week to stay under the 1000-result API cap
        let weekRanges = buildWeekRanges(since: since)

        for email in emails {
            for range in weekRanges {
                var page = 1
                while true {
                    let query = "author-email:\(email)+author-date:\(range)"
                    let endpoint = "/search/commits?q=\(query)&per_page=100&page=\(page)&sort=author-date&order=desc"
                    guard let output = runGh(["api", endpoint, "-H", "Accept: application/vnd.github+json"]) else { break }

                    let commits = parseSearchResults(output)
                    if commits.isEmpty { break }

                    for c in commits where !seenSHAs.contains(c.sha) {
                        seenSHAs.insert(c.sha)
                        allCommits.append(c)
                    }

                    if commits.count < 100 { break }
                    page += 1
                    if page > 10 { break }
                }
            }
        }

        return allCommits
    }

    private func buildWeekRanges(since: String) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let startDate = formatter.date(from: since) else { return [">\(since)"] }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var ranges: [String] = []
        var current = startDate

        while current < today {
            let weekEnd = min(calendar.date(byAdding: .day, value: 7, to: current)!, today)
            let from = formatter.string(from: current)
            let to = formatter.string(from: weekEnd)
            ranges.append("\(from)..\(to)")
            current = calendar.date(byAdding: .day, value: 7, to: current)!
        }

        return ranges
    }

    // MARK: - GraphQL batch stats

    private func fetchStats(for commits: [SearchCommit]) async -> [StatsCommit] {
        var results: [StatsCommit] = []
        let batchSize = 50

        for batchStart in stride(from: 0, to: commits.count, by: batchSize) {
            let end = min(batchStart + batchSize, commits.count)
            let batch = Array(commits[batchStart..<end])

            // Group this batch by repo for the query structure
            var repoMap: [String: [(index: Int, commit: SearchCommit)]] = [:]
            for (i, c) in batch.enumerated() {
                repoMap[c.repo, default: []].append((i, c))
            }

            var fragments: [String] = []
            var lookups: [(alias: String, commit: SearchCommit)] = []

            for (ri, (repo, entries)) in repoMap.enumerated() {
                let parts = repo.split(separator: "/")
                guard parts.count == 2 else { continue }

                var objectFragments: [String] = []
                for (ci, entry) in entries.enumerated() {
                    let alias = "c\(ri)_\(ci)"
                    objectFragments.append("""
                      \(alias): object(expression: "\(entry.commit.sha)") {
                        ... on Commit { additions deletions }
                      }
                    """)
                    lookups.append((alias, entry.commit))
                }

                fragments.append("""
                  r\(ri): repository(owner: "\(parts[0])", name: "\(parts[1])") {
                    \(objectFragments.joined(separator: "\n"))
                  }
                """)
            }

            let query = "{ \(fragments.joined(separator: "\n")) }"
            guard let output = runGraphQL(query) else { continue }

            guard let data = output.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = root["data"] as? [String: Any] else { continue }

            // Match lookups back to results
            for (ri, (_, entries)) in repoMap.enumerated() {
                guard let repoObj = dataObj["r\(ri)"] as? [String: Any] else { continue }
                for (ci, entry) in entries.enumerated() {
                    guard let commitObj = repoObj["c\(ri)_\(ci)"] as? [String: Any],
                          let added = commitObj["additions"] as? Int,
                          let deleted = commitObj["deletions"] as? Int else { continue }
                    results.append(StatsCommit(
                        sha: entry.commit.sha,
                        repo: entry.commit.repo,
                        date: entry.commit.date,
                        message: entry.commit.message,
                        added: added,
                        deleted: deleted
                    ))
                }
            }
        }

        return results
    }

    // MARK: - Process execution

    private static let ghPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    private func runGh(_ args: [String]) -> String? {
        guard let gh = Self.ghPath else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func runGraphQL(_ query: String) -> String? {
        guard let gh = Self.ghPath else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["api", "graphql", "-f", "query=\(query)"]

        // For large queries, write to a temp file and use --input
        // But first try direct argument
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            // Query too large for args -- use stdin
            return runGraphQLViaStdin(query)
        }
        return String(data: data, encoding: .utf8)
    }

    private func runGraphQLViaStdin(_ query: String) -> String? {
        guard let gh = Self.ghPath else { return nil }

        // Write query as JSON body to temp file
        let body: [String: String] = ["query": query]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        let tmpFile = "/tmp/gitcount-gql-\(UUID().uuidString).json"
        FileManager.default.createFile(atPath: tmpFile, contents: bodyData)
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["api", "graphql", "--input", tmpFile]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - JSON parsing

    private func parseSearchResults(_ json: String) -> [SearchCommit] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let sha = item["sha"] as? String,
                  let repo = item["repository"] as? [String: Any],
                  let repoName = repo["full_name"] as? String,
                  let commit = item["commit"] as? [String: Any],
                  let author = commit["author"] as? [String: Any],
                  let date = author["date"] as? String,
                  let message = commit["message"] as? String else {
                return nil
            }
            let firstLine = message.components(separatedBy: "\n").first ?? message
            return SearchCommit(sha: sha, repo: repoName, date: date, message: firstLine)
        }
    }

    // MARK: - Helpers

    private func fourWeeksAgoISO() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = Calendar.current.date(byAdding: .weekOfYear, value: -4, to: Date())!
        return formatter.string(from: date)
    }

    static func checkAuth() -> Bool {
        guard let gh = ghPath else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["auth", "status"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
