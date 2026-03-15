import SwiftUI

@main
struct GitCountApp: App {
    @State private var store = ContributionStore()
    @State private var refreshTask: Task<Void, Never>?
    @Environment(\.openWindow) private var openWindow

    private let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "."
        return f
    }()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                Text(formattedCount)
            }
            .onAppear {
                startRefreshLoop()
                if store.authorEmails.isEmpty || !GitHubClient.checkAuth() {
                    openWindow(id: "settings")
                }
            }
        }
        .menuBarExtraStyle(.window)

        Window("Day Detail", id: "day-detail") {
            DayDetailView(store: store)
        }
        .defaultSize(width: 600, height: 500)

        Window("Settings", id: "settings") {
            SettingsView(store: store)
        }
        .defaultSize(width: 400, height: 300)
        .windowResizability(.contentSize)
    }

    private var formattedCount: String {
        numberFormatter.string(from: NSNumber(value: store.currentWeekLines)) ?? "0"
    }

    private func startRefreshLoop() {
        guard refreshTask == nil else { return }
        refreshTask = Task {
            await store.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                await store.refresh()
            }
        }
    }
}

struct PopoverView: View {
    @Bindable var store: ContributionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ContributionGridView(
                weeks: store.weeks,
                allValues: store.allDayValues,
                onDayTapped: { day in
                    store.selectedDay = day
                    openWindow(id: "day-detail")
                }
            )

            Divider()

            HStack {
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let last = store.lastRefresh {
                    Text("Updated \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    openWindow(id: "settings")
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button("Refresh") {
                    Task { await store.refresh() }
                }
                .buttonStyle(.borderless)
                .font(.caption)

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .frame(width: 380)
        .task {
            await store.refresh()
        }
    }
}
