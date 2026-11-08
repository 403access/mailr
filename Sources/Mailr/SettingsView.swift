import SwiftUI
import MailCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var lock
    @Environment(\.dismiss) private var dismiss

    @State private var editingRequest: AccountEditorRequest?
    @State private var pendingDeletion: MailAccount?
    @State private var showSecurity = false

    private struct AccountEditorRequest: Identifiable {
        let id = UUID()
        var account: MailAccount?
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.runtimes.isEmpty {
                List {
                    EmptyStateView(
                        icon: "person.crop.circle.badge.plus",
                        title: "No Accounts",
                        message: "Add an account to start sending and receiving mail."
                    )
                    .frame(height: 240)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    privacySection
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            } else {
                List {
                    Section("Accounts") {
                        ForEach(model.runtimes) { runtime in
                            accountRow(runtime)
                                .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                        }
                    }

                    privacySection
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider()
            footer
        }
        .modifier(SettingsSizing())
        .background(.background)
        .onAppear { lock.refreshBiometry() }
        .sheet(item: $editingRequest) { request in
            AccountEditorView(account: request.account)
                .environment(model)
                .mailrLargeDetent()
        }
        .sheet(isPresented: $showSecurity) {
            SecuritySettingsView()
                .environment(lock)
                .mailrLargeDetent()
        }
        #if DEBUG
        .task {
            guard ProcessInfo.processInfo.environment["MAILR_UI_PREVIEW"] == "account" else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            editingRequest = AccountEditorRequest(account: nil)
        }
        .task {
            guard ProcessInfo.processInfo.environment["MAILR_UI_PREVIEW"] == "security" else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            showSecurity = true
        }
        #endif
        .confirmationDialog(
            "Remove “\(pendingDeletion?.displayName ?? "account")”?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { account in
            Button("Remove Account", role: .destructive) {
                let id = account.id
                pendingDeletion = nil
                Task { await model.deleteAccount(id) }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { account in
            Text("Mailr will remove \(account.emailAddress) and its saved password from this Mac. Messages stay on the server.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Accounts")
                    .font(.title3.weight(.semibold))
                Text("Connect Mailr directly to your mail servers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                editingRequest = AccountEditorRequest(account: nil)
            } label: {
                #if os(iOS)
                Label("Add", systemImage: "plus")
                #else
                Label("Add Account", systemImage: "plus")
                #endif
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var privacySection: some View {
        Section("Privacy") {
            Button {
                showSecurity = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: lock.isEnabled ? "lock.shield.fill" : "lock.shield")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(lock.isEnabled ? Color.accentColor : Color.secondary)
                        .frame(width: 26)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("App Lock")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(securitySubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(lock.isEnabled ? "On" : "Off")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
        }
    }

    private var securitySubtitle: String {
        if lock.isEnabled {
            return "Unlocks with \(lock.biometryName)"
        }
        if lock.canUseBiometrics {
            return "Require \(lock.biometryName) when Mailr opens"
        }
        return "Biometrics aren’t available on this device"
    }

    private func accountRow(_ runtime: AccountRuntime) -> some View {
        HStack(spacing: 12) {
            AvatarView(
                name: runtime.account.displayName,
                address: runtime.account.emailAddress,
                size: 36
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(runtime.account.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    if runtime.account.isDemo {
                        Text("DEMO")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(runtime.account.emailAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if runtime.account.isDemo {
                    Text("Offline demo account")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("\(runtime.account.provider.displayName) · IMAP \(runtime.account.incoming.host.isEmpty ? "not configured" : runtime.account.incoming.host)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if runtime.account.isDemo == false {
                Button("Edit") {
                    editingRequest = AccountEditorRequest(account: runtime.account)
                }
                .controlSize(.small)

                Button {
                    pendingDeletion = runtime.account
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .mailrHelp("Remove account")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            Text(keychainMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var keychainMessage: String {
        #if os(macOS)
        "Passwords are stored in your macOS Keychain."
        #else
        "Passwords are stored in your device Keychain."
        #endif
    }
}
