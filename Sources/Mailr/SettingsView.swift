import SwiftUI
import MailCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var lock
    @Environment(\.dismiss) private var dismiss

    @State private var editingRequest: AccountEditorRequest?
    @State private var pendingDeletion: MailAccount?
    @State private var showSecurity = false
    @State private var hostPasswordAccount: MailAccount?

    private struct AccountEditorRequest: Identifiable {
        let id = UUID()
        var account: MailAccount?
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)

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
                    hostArchiveSection
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                List {
                    Section {
                        ForEach(model.runtimes) { runtime in
                            accountRow(runtime)
                                .mailrCard(radius: 16, shadowRadius: 8)
                                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } header: {
                        MailrSectionLabel(text: "Accounts")
                            .padding(.leading, 4)
                    }

                    privacySection
                    hostArchiveSection
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)
            footer
        }
        .modifier(SettingsSizing())
        .background { MailrBackground() }
        .tint(MailrTheme.accent)
        .onAppear { lock.refreshBiometry() }
        .task { await model.refreshHostArchiveStatus() }
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
        .sheet(item: $hostPasswordAccount) { account in
            HostPasswordView(account: account)
                .environment(model)
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
            if account.provider == .local {
                Text("Mailr will remove \(account.displayName) and the imported mail stored on this device.")
            } else {
                Text("Mailr will remove \(account.emailAddress) and its saved password from this Mac. Messages stay on the server.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            MailrLogoMark(size: 38)

            VStack(alignment: .leading, spacing: 3) {
                MailrSectionLabel(text: "Settings")
                Text("Accounts")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(MailrTheme.inkGradient)
                Text("Connect Mailr directly to your mail servers.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(MailrTheme.inkSecondary)
            }

            Spacer()

            if model.isHostMode {
                Text("Managed by host server")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(MailrTheme.inkTertiary)
            } else {
                Button {
                    editingRequest = AccountEditorRequest(account: nil)
                } label: {
                    #if os(iOS)
                    Label("Add", systemImage: "plus")
                    #else
                    Label("Add Account", systemImage: "plus")
                    #endif
                }
                .buttonStyle(.mailrPrimary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var privacySection: some View {
        Section {
            Button {
                showSecurity = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(
                                lock.isEnabled
                                    ? AnyShapeStyle(MailrTheme.accentGradient)
                                    : AnyShapeStyle(MailrTheme.surfaceSoft)
                            )
                        Image(systemName: lock.isEnabled ? "lock.shield.fill" : "lock.shield")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(lock.isEnabled ? Color.white : MailrTheme.inkSecondary)
                    }
                    .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("App Lock")
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(MailrTheme.ink)
                        Text(securitySubtitle)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(MailrTheme.inkSecondary)
                    }

                    Spacer()

                    Text(lock.isEnabled ? "ON" : "OFF")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(lock.isEnabled ? MailrTheme.accentDeep : MailrTheme.inkTertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            lock.isEnabled ? MailrTheme.accent.opacity(0.10) : MailrTheme.surfaceSoft,
                            in: Capsule()
                        )

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MailrTheme.inkTertiary)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .mailrCard(radius: 16, shadowRadius: 8)
            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 4, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } header: {
            MailrSectionLabel(text: "Privacy")
                .padding(.leading, 4)
        }
    }

    private var hostArchiveSection: some View {
        Section {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            model.hostArchiveHealth == nil
                                ? AnyShapeStyle(MailrTheme.surfaceSoft)
                                : AnyShapeStyle(MailrTheme.accentGradient)
                        )
                    Image(systemName: model.hostArchiveHealth == nil ? "externaldrive" : "externaldrive.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(
                            model.hostArchiveHealth == nil ? MailrTheme.inkSecondary : Color.white
                        )
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Host server")
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(MailrTheme.ink)

                    if let address = model.hostArchiveAddress {
                        Text(address)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(MailrTheme.inkTertiary)
                            .lineLimit(1)
                    } else {
                        Text("Disabled with MAILR_HOST_SERVER=off")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(MailrTheme.inkTertiary)
                    }

                    if model.isHostArchiveEnabled {
                        Text(hostArchiveDetail)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(MailrTheme.inkSecondary)
                    }
                }

                Spacer()

                if model.isHostArchiveEnabled {
                    Text(model.hostArchiveHealth == nil ? "OFFLINE" : "ONLINE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(
                            model.hostArchiveHealth == nil ? MailrTheme.amber : MailrTheme.accentDeep
                        )
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            (model.hostArchiveHealth == nil ? MailrTheme.amber : MailrTheme.accent)
                                .opacity(0.10),
                            in: Capsule()
                        )
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .mailrCard(radius: 16, shadowRadius: 8)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 12, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        } header: {
            MailrSectionLabel(text: "Host server")
                .padding(.leading, 4)
        }
    }

    private var hostArchiveDetail: String {
        if model.isCheckingHostArchive {
            return "Checking the host server…"
        }
        if let health = model.hostArchiveHealth {
            return "\(health.messageCount) messages cached on the host"
        }
        return "Not reachable — check the host server"
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
        let isHostAccount = model.isHostAccount(runtime.id)

        return HStack(spacing: 12) {
            AvatarView(
                name: runtime.account.displayName,
                address: runtime.account.emailAddress,
                size: 38
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(runtime.account.displayName)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(MailrTheme.ink)
                    if runtime.account.isDemo {
                        Text("DEMO")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(MailrTheme.accentDeep)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(MailrTheme.accent.opacity(0.10), in: Capsule())
                    }
                }
                Text(runtime.account.emailAddress)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(MailrTheme.inkTertiary)
                if isHostAccount {
                    Text("Host server · \(runtime.mailboxes.count) mailbox\(runtime.mailboxes.count == 1 ? "" : "es")")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkTertiary)
                        .lineLimit(1)
                } else if runtime.account.isDemo {
                    Text("Offline demo account")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkTertiary)
                } else if runtime.account.provider == .local {
                    Text("Local mail archive · \(runtime.mailboxes.count) mailbox\(runtime.mailboxes.count == 1 ? "" : "es")")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkTertiary)
                        .lineLimit(1)
                } else {
                    Text("\(runtime.account.provider.displayName) · IMAP \(runtime.account.incoming.host.isEmpty ? "not configured" : runtime.account.incoming.host)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isHostAccount {
                #if os(macOS)
                Button("Password") {
                    hostPasswordAccount = runtime.account
                }
                .controlSize(.small)
                #endif
            }

            if runtime.account.isDemo == false && !isHostAccount {
                if runtime.account.provider != .local {
                    Button("Edit") {
                        editingRequest = AccountEditorRequest(account: runtime.account)
                    }
                    .controlSize(.small)
                }

                Button {
                    pendingDeletion = runtime.account
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(MailrTheme.inkTertiary)
                .mailrHelp("Remove account")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(MailrTheme.accent)
            Text(keychainMessage)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(MailrTheme.inkSecondary)

            Spacer()

            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background { MailrBarBackground(edge: .top) }
    }

    private var keychainMessage: String {
        #if os(macOS)
        "Passwords are stored in your macOS Keychain."
        #else
        "Passwords are stored in your device Keychain."
        #endif
    }
}
