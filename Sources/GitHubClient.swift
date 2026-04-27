import Foundation

actor GitHubClient {
    private let emails: [String]
    private let repoBatchSize = 10

    init(emails: [String]) {
        self.emails = normalizedAuthorEmails(emails)
    }

    // MARK: - Data types

    private struct CommitInfo: Sendable {
        let sha: String
        let repo: String
        let date: String
        let message: String
        let added: Int
        let deleted: Int
    }

    // MARK: - Public API

    func fetchContributions() async -> [String: (added: Int, deleted: Int, commits: Int)] {
        guard !emails.isEmpty else { return [:] }

        let commits = await fetchAllCommits()

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterPlain = ISO8601DateFormatter()

        var combined: [String: (added: Int, deleted: Int, commits: Int)] = [:]

        for c in commits {
            guard let d = isoFormatter.date(from: c.date) ?? isoFormatterPlain.date(from: c.date) else { continue }
            let key = dateFormatter.string(from: d)
            let existing = combined[key] ?? (0, 0, 0)
            combined[key] = (existing.added + c.added, existing.deleted + c.deleted, existing.commits + 1)
        }

        return combined
    }

    func fetchDayDetail(date: String) async -> [RepoDayDetail] {
        guard !emails.isEmpty else { return [] }

        let commits = await fetchAllCommits()

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterPlain = ISO8601DateFormatter()

        var repoDetails: [String: (added: Int, deleted: Int, commits: [RepoCommit])] = [:]

        for c in commits {
            guard let d = isoFormatter.date(from: c.date) ?? isoFormatterPlain.date(from: c.date) else { continue }
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

    // MARK: - Core: GraphQL-only approach

    private func fetchAllCommits() async -> [CommitInfo] {
        let repos = fetchRepos()
        guard !repos.isEmpty, !emails.isEmpty else { return [] }

        let since = fourWeeksAgoISO()
        var allCommits: [CommitInfo] = []
        var seenSHAs = Set<String>()

        // Query repos in batches
        for batchStart in stride(from: 0, to: repos.count, by: repoBatchSize) {
            let end = min(batchStart + repoBatchSize, repos.count)
            let batch = Array(repos[batchStart..<end])

            var fragments: [String] = []
            var repoNames: [Int: String] = [:]

            for (ri, repo) in batch.enumerated() {
                let parts = repo.nameWithOwner.split(separator: "/")
                guard parts.count == 2 else { continue }
                repoNames[ri] = repo.nameWithOwner

                // Always query default branch
                var branchQueries = """
                  defaultBranch: defaultBranchRef {
                    target {
                      ... on Commit {
                        history(since: $since, author: {emails: $emails}, first: 100) {
                          nodes { oid additions deletions committedDate messageHeadline }
                        }
                      }
                    }
                  }
                """

                // Also query dev branch if it exists and isn't the default
                if repo.hasDevBranch && repo.defaultBranch != "dev" {
                    branchQueries += """

                      devBranch: ref(qualifiedName: "refs/heads/dev") {
                        target {
                          ... on Commit {
                            history(since: $since, author: {emails: $emails}, first: 100) {
                              nodes { oid additions deletions committedDate messageHeadline }
                            }
                          }
                        }
                      }
                    """
                }

                fragments.append("""
                  r\(ri): repository(owner: "\(parts[0])", name: "\(parts[1])") {
                    \(branchQueries)
                  }
                """)
            }

            let query = "query($since: GitTimestamp!, $emails: [String!]) { \(fragments.joined(separator: "\n")) }"
            guard let output = runGraphQL(query, variables: ["since": since, "emails": emails]) else { continue }

            guard let data = output.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = root["data"] as? [String: Any] else { continue }

            for (ri, repoName) in repoNames {
                guard let repoObj = dataObj["r\(ri)"] as? [String: Any] else { continue }

                // Collect commits from default branch
                if let branch = repoObj["defaultBranch"] as? [String: Any] {
                    parseHistoryNodes(branch, repoName: repoName, into: &allCommits, seen: &seenSHAs)
                }

                // Collect commits from dev branch (deduped by SHA)
                if let branch = repoObj["devBranch"] as? [String: Any] {
                    parseHistoryNodes(branch, repoName: repoName, into: &allCommits, seen: &seenSHAs)
                }
            }
        }

        return allCommits
    }

    private func parseHistoryNodes(_ branchObj: [String: Any], repoName: String, into commits: inout [CommitInfo], seen: inout Set<String>) {
        guard let target = branchObj["target"] as? [String: Any],
              let history = target["history"] as? [String: Any],
              let nodes = history["nodes"] as? [[String: Any]] else { return }

        for node in nodes {
            guard let sha = node["oid"] as? String,
                  !seen.contains(sha),
                  let added = node["additions"] as? Int,
                  let deleted = node["deletions"] as? Int,
                  let date = node["committedDate"] as? String else { continue }

            seen.insert(sha)
            let message = node["messageHeadline"] as? String ?? ""
            commits.append(CommitInfo(sha: sha, repo: repoName, date: date, message: message, added: added, deleted: deleted))
        }
    }

    // MARK: - Repo discovery

    private struct RepoInfo {
        let nameWithOwner: String
        let defaultBranch: String
        let hasDevBranch: Bool
    }

    private func fetchRepos() -> [RepoInfo] {
        let query = """
        {
          viewer {
            repositories(first: 100, orderBy: {field: PUSHED_AT, direction: DESC}, affiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER]) {
              nodes {
                nameWithOwner
                defaultBranchRef { name }
                devRef: ref(qualifiedName: "refs/heads/dev") { name }
              }
            }
            repositoriesContributedTo(first: 100, orderBy: {field: PUSHED_AT, direction: DESC}, contributionTypes: [COMMIT]) {
              nodes {
                nameWithOwner
                defaultBranchRef { name }
                devRef: ref(qualifiedName: "refs/heads/dev") { name }
              }
            }
          }
        }
        """

        guard let output = runGraphQL(query),
              let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = root["data"] as? [String: Any],
              let viewer = dataObj["viewer"] as? [String: Any] else {
            return []
        }

        var seen = Set<String>()
        var results: [RepoInfo] = []

        let owned = (viewer["repositories"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let contributed = (viewer["repositoriesContributedTo"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []

        for node in owned + contributed {
            guard let nameWithOwner = node["nameWithOwner"] as? String,
                  !seen.contains(nameWithOwner) else { continue }
            seen.insert(nameWithOwner)

            let defaultBranch = (node["defaultBranchRef"] as? [String: Any])?["name"] as? String ?? "main"
            let hasDevBranch = node["devRef"] != nil && !(node["devRef"] is NSNull)

            results.append(RepoInfo(nameWithOwner: nameWithOwner, defaultBranch: defaultBranch, hasDevBranch: hasDevBranch))
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

    private func runGraphQL(_ query: String, variables: [String: Any] = [:]) -> String? {
        guard let gh = Self.ghPath else { return nil }
        if !variables.isEmpty {
            return runGraphQLViaFile(query, variables: variables)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["api", "graphql", "-f", "query=\(query)"]

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
            return runGraphQLViaFile(query, variables: variables)
        }
        return String(data: data, encoding: .utf8)
    }

    private func runGraphQLViaFile(_ query: String, variables: [String: Any] = [:]) -> String? {
        guard let gh = Self.ghPath else { return nil }

        var body: [String: Any] = ["query": query]
        if !variables.isEmpty {
            body["variables"] = variables
        }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        let tmpFile = "/tmp/gitcount-gql-\(UUID().uuidString).json"
        FileManager.default.createFile(atPath: tmpFile, contents: bodyData)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmpFile)
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

    // MARK: - Helpers

    private func fourWeeksAgoISO() -> String {
        let formatter = ISO8601DateFormatter()
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
