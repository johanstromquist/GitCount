import SwiftUI

struct SettingsView: View {
    @Bindable var store: ContributionStore
    @State private var newEmail = ""
    @State private var ghAuthenticated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.system(size: 16, weight: .semibold))

            // GitHub CLI status
            VStack(alignment: .leading, spacing: 4) {
                Text("GitHub CLI")
                    .font(.system(size: 13, weight: .medium))

                HStack(spacing: 6) {
                    Image(systemName: ghAuthenticated ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(ghAuthenticated ? .green : .red)
                        .font(.system(size: 14))
                    if ghAuthenticated {
                        Text("Authenticated via gh")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not authenticated. Run: gh auth login")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // Author emails
            VStack(alignment: .leading, spacing: 8) {
                Text("Author emails")
                    .font(.system(size: 13, weight: .medium))
                Text("Git commit emails to match as yours.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    ForEach(store.authorEmails, id: \.self) { email in
                        HStack {
                            Text(email)
                                .font(.system(size: 13, design: .monospaced))
                            Spacer()
                            Button {
                                store.authorEmails.removeAll { $0 == email }
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.5))
                        .cornerRadius(4)
                    }
                }

                HStack {
                    TextField("Add email...", text: $newEmail)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .onSubmit { addEmail() }

                    Button("Add") { addEmail() }
                        .disabled(newEmail.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Save & Refresh") {
                    Task { await store.refresh() }
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ghAuthenticated || store.authorEmails.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400, height: 340)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            ghAuthenticated = GitHubClient.checkAuth()
        }
    }

    private func addEmail() {
        let trimmed = newEmail.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !store.authorEmails.contains(trimmed) else { return }
        store.authorEmails.append(trimmed)
        newEmail = ""
    }
}
