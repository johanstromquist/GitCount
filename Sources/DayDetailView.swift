import SwiftUI

struct DayDetailView: View {
    @Bindable var store: ContributionStore

    private let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        return f
    }()

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let day = store.selectedDay {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(dateFormatter.string(from: day.date))
                        .font(.system(size: 16, weight: .semibold))

                    if let details = store.dayDetail {
                        let added = details.reduce(0) { $0 + $1.added }
                        let deleted = details.reduce(0) { $0 + $1.deleted }
                        let commits = details.reduce(0) { $0 + $1.commits.count }
                        HStack(spacing: 16) {
                            Text("Net: \(fmt(added - deleted))")
                                .font(.system(size: 13, weight: .medium))
                            Text("+\(fmt(added))")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.green)
                            Text("-\(fmt(deleted))")
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.red)
                            Text("\(commits) commit\(commits == 1 ? "" : "s")")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()

                Divider()

                // Content
                if store.isLoadingDetail {
                    VStack {
                        Spacer()
                        ProgressView("Scanning repos...")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if let details = store.dayDetail, !details.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(details) { repo in
                                RepoDetailRow(repo: repo, numberFormatter: numberFormatter)
                                Divider()
                            }
                        }
                    }
                } else if store.dayDetail != nil {
                    VStack {
                        Spacer()
                        Text("No contributions found")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
        }
        .frame(minWidth: 500, idealWidth: 600, minHeight: 400, idealHeight: 500)
        .task(id: store.selectedDay?.id) {
            NSApp.activate(ignoringOtherApps: true)
            if let day = store.selectedDay {
                await store.loadDayDetail(date: day.id)
            }
        }
    }

    private func fmt(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

struct RepoDetailRow: View {
    let repo: RepoDayDetail
    let numberFormatter: NumberFormatter
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    Text(repo.repoName)
                        .font(.system(size: 13, weight: .semibold))

                    Spacer()

                    Text("+\(fmt(repo.added))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.green)
                    Text("-\(fmt(repo.deleted))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.red)
                    Text("(\(repo.commits.count)c)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(repo.commits) { commit in
                        HStack(spacing: 8) {
                            Text(commit.id)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)

                            Text(commit.message)
                                .font(.system(size: 12))
                                .lineLimit(1)

                            Spacer()

                            Text("+\(fmt(commit.added))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.green)
                            Text("-\(fmt(commit.deleted))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                        .padding(.horizontal)
                        .padding(.leading, 22)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func fmt(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
