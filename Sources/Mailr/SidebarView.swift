import SwiftUI
import MailCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selection) {
            ForEach(model.runtimes) { runtime in
                Section {
                    ForEach(runtime.mailboxes) { mailbox in
                        MailboxRow(mailbox: mailbox)
                            .tag(MailboxSelection(accountID: runtime.id, mailboxPath: mailbox.path))
                    }

                    if runtime.mailboxes.isEmpty {
                        HStack(spacing: 8) {
                            if runtime.isLoadingMailboxes {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                            Text(runtime.isLoadingMailboxes ? "Connecting…" : "No mailboxes available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    AccountHeader(runtime: runtime)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Mailr")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
        .overlay {
            if model.runtimes.isEmpty {
                EmptyStateView(
                    icon: "envelope",
                    title: "No Accounts",
                    message: "Add a mail account to get started."
                )
            }
        }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 4) {
                Button {
                    model.newCompose()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .mailrHelp("New Message (⌘N)")

                Spacer()

                if model.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 2)
                } else {
                    Button {
                        Task { await model.refreshAll() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .mailrHelp("Refresh Mail (⇧⌘R)")
                }

                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .mailrHelp("Accounts & Settings")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(.bar)
    }
}

// MARK: - iPhone / compact drawer

struct MailboxDrawer: View {
    @Environment(AppModel.self) private var model
    let onSelect: (MailboxSelection) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            mailboxList
            Divider()
            footer
        }
        .background(Color.mailrWindowBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Mailr")
                    .font(.title3.weight(.bold))
                if let account = model.activeAccount {
                    Text(account.emailAddress)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close menu")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var mailboxList: some View {
        List {
            if model.runtimes.isEmpty {
                Section {
                    VStack(spacing: 14) {
                        EmptyStateView(
                            icon: "envelope",
                            title: "No Accounts",
                            message: "Add an account to start reading and sending mail."
                        )

                        Button {
                            model.showSettings = true
                            onClose()
                        } label: {
                            Label("Add Account", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }

            ForEach(model.runtimes) { runtime in
                Section {
                    ForEach(runtime.mailboxes) { mailbox in
                        mailboxButton(runtime: runtime, mailbox: mailbox)
                    }

                    if runtime.mailboxes.isEmpty {
                        HStack(spacing: 8) {
                            if runtime.isLoadingMailboxes {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                            Text(runtime.isLoadingMailboxes ? "Connecting…" : "No mailboxes available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    AccountHeader(runtime: runtime)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func mailboxButton(runtime: AccountRuntime, mailbox: Mailbox) -> some View {
        let selection = MailboxSelection(accountID: runtime.id, mailboxPath: mailbox.path)
        let isSelected = model.selection == selection

        return Button {
            onSelect(selection)
        } label: {
            HStack(spacing: 8) {
                MailboxRow(mailbox: mailbox)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                model.newCompose()
                onClose()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("New Message")

            Spacer()

            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 4)
            } else {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh Mail")
            }

            Button {
                model.showSettings = true
                onClose()
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Accounts & Settings")
        }
        .font(.system(size: 18))
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - Rows

struct AccountHeader: View {
    let runtime: AccountRuntime

    var body: some View {
        HStack(spacing: 7) {
            AvatarView(
                name: runtime.account.displayName,
                address: runtime.account.emailAddress,
                size: 20
            )

            VStack(alignment: .leading, spacing: 0) {
                Text(runtime.account.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                if runtime.account.isDemo {
                    Text("Offline demo")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if let error = runtime.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .mailrHelp(error)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .textCase(nil)
    }
}

struct MailboxRow: View {
    let mailbox: Mailbox

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: mailbox.role.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(mailbox.role == .inbox ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            Text(mailbox.name)
                .font(.system(size: 13, weight: mailbox.unreadCount > 0 ? .semibold : .regular))
                .lineLimit(1)

            Spacer(minLength: 4)

            if mailbox.unreadCount > 0 {
                CountBadge(count: mailbox.unreadCount)
            }
        }
        .padding(.vertical, 1)
    }
}
