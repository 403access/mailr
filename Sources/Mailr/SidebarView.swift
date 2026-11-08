import SwiftUI
import MailCore

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selection) {
            Section {
                HStack(spacing: 10) {
                    MailrLogoMark(size: 32)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("MAILR")
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                            .tracking(2.4)
                            .foregroundStyle(MailrTheme.inkGradient)
                        Text("Secure messaging")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(MailrTheme.inkTertiary)
                    }

                    Spacer()
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(model.runtimes) { runtime in
                Section {
                    if !model.isMailboxSectionCollapsed(runtime.id) {
                        ForEach(runtime.mailboxes) { mailbox in
                            MailboxRow(
                                mailbox: mailbox,
                                isSelected: model.selection == MailboxSelection(
                                    accountID: runtime.id,
                                    mailboxPath: mailbox.path
                                )
                            )
                            .tag(MailboxSelection(accountID: runtime.id, mailboxPath: mailbox.path))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        }

                        if runtime.mailboxes.isEmpty {
                            HStack(spacing: 8) {
                                if runtime.isLoadingMailboxes {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(MailrTheme.amber)
                                }
                                Text(runtime.isLoadingMailboxes ? "Connecting…" : "No mailboxes available")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(MailrTheme.inkTertiary)
                            }
                            .padding(.vertical, 2)
                            .listRowBackground(Color.clear)
                        }
                    }
                } header: {
                    AccountHeader(
                        runtime: runtime,
                        isHost: model.isHostAccount(runtime.id),
                        isCollapsed: model.isMailboxSectionCollapsed(runtime.id),
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                model.toggleMailboxSection(runtime.id)
                            }
                        }
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .navigationTitle("")
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
            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)

            HStack(spacing: 8) {
                Button {
                    model.newCompose()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.mailrIcon)
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
                    .buttonStyle(.mailrIcon)
                    .mailrHelp("Refresh Mail (⇧⌘R)")
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.toggleAllMailboxSections()
                    }
                } label: {
                    Image(systemName: model.allMailboxSectionsCollapsed
                          ? "rectangle.expand.vertical"
                          : "rectangle.compress.vertical")
                }
                .buttonStyle(.mailrIcon)
                .disabled(!model.hasMailboxSections)
                .mailrHelp(model.allMailboxSectionsCollapsed ? "Expand All Mailboxes" : "Collapse All Mailboxes")

                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.mailrIcon)
                .mailrHelp("Accounts & Settings")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background { MailrBarBackground(edge: .top) }
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
            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)
            mailboxList
            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            MailrLogoMark(size: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text("MAILR")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .tracking(2.8)
                    .foregroundStyle(MailrTheme.inkGradient)
                if let account = model.activeAccount {
                    Text(account.emailAddress)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(MailrIconButtonStyle(size: 32))
            .accessibilityLabel("Close menu")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var mailboxList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if model.runtimes.isEmpty {
                    VStack(spacing: 14) {
                        EmptyStateView(
                            icon: "envelope",
                            title: "No Accounts",
                            message: "Add an account to start reading and sending mail."
                        )
                        .frame(height: 220)

                        Button {
                            model.showSettings = true
                            onClose()
                        } label: {
                            Label("Add Account", systemImage: "plus")
                        }
                        .buttonStyle(.mailrPrimary)
                    }
                    .frame(maxWidth: .infinity)
                }

                ForEach(model.runtimes) { runtime in
                    VStack(alignment: .leading, spacing: 4) {
                        AccountHeader(
                            runtime: runtime,
                            isHost: model.isHostAccount(runtime.id),
                            isCollapsed: model.isMailboxSectionCollapsed(runtime.id),
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    model.toggleMailboxSection(runtime.id)
                                }
                            }
                        )
                        .padding(.horizontal, 8)

                        if !model.isMailboxSectionCollapsed(runtime.id) {
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
                                            .foregroundStyle(MailrTheme.amber)
                                    }
                                    Text(runtime.isLoadingMailboxes ? "Connecting…" : "No mailboxes available")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(MailrTheme.inkTertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func mailboxButton(runtime: AccountRuntime, mailbox: Mailbox) -> some View {
        let selection = MailboxSelection(accountID: runtime.id, mailboxPath: mailbox.path)
        let isSelected = model.selection == selection

        return Button {
            onSelect(selection)
        } label: {
            HStack(spacing: 8) {
                MailboxRow(mailbox: mailbox, isSelected: isSelected)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MailrTheme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.newCompose()
                onClose()
            } label: {
                Label("New Message", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.mailrPrimary)
            .accessibilityLabel("New Message")

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    model.toggleAllMailboxSections()
                }
            } label: {
                Image(systemName: model.allMailboxSectionsCollapsed
                      ? "rectangle.expand.vertical"
                      : "rectangle.compress.vertical")
            }
            .buttonStyle(.mailrIcon)
            .disabled(!model.hasMailboxSections)
            .accessibilityLabel(model.allMailboxSectionsCollapsed ? "Expand All Mailboxes" : "Collapse All Mailboxes")

            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 38, height: 38)
            } else {
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.mailrIcon)
                .accessibilityLabel("Refresh Mail")
            }

            Button {
                model.showSettings = true
                onClose()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.mailrIcon)
            .accessibilityLabel("Accounts & Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background { MailrBarBackground(edge: .top) }
    }
}

// MARK: - Rows

struct AccountHeader: View {
    let runtime: AccountRuntime
    var isHost: Bool = false
    var isCollapsed: Bool = false
    var onToggle: (() -> Void)?

    var body: some View {
        if let onToggle {
            Button(action: onToggle) {
                headerContent
            }
            .buttonStyle(.plain)
            .mailrHelp(isCollapsed ? "Expand Mailboxes" : "Collapse Mailboxes")
            .accessibilityLabel(
                "\(runtime.account.displayName), \(isCollapsed ? "collapsed" : "expanded")"
            )
            .accessibilityHint("Expand or collapse mailboxes")
        } else {
            headerContent
        }
    }

    private var headerContent: some View {
        HStack(spacing: 8) {
            AvatarView(
                name: runtime.account.displayName,
                address: runtime.account.emailAddress,
                size: 21
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(runtime.account.displayName.uppercased())
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(MailrTheme.inkTertiary)
                    .lineLimit(1)
                if isHost {
                    Text("HOST SERVER")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(MailrTheme.accent.opacity(0.70))
                } else if runtime.account.isDemo {
                    Text("OFFLINE DEMO")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(MailrTheme.accent.opacity(0.70))
                } else if runtime.account.provider == .local {
                    Text("LOCAL MAIL")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .tracking(1)
                        .foregroundStyle(MailrTheme.accent.opacity(0.70))
                }
            }

            Spacer()

            if let error = runtime.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MailrTheme.amber)
                    .mailrHelp(error)
            }

            if onToggle != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MailrTheme.inkTertiary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(.easeInOut(duration: 0.18), value: isCollapsed)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .padding(.top, 8)
        .padding(.bottom, 2)
        .textCase(nil)
    }
}

struct MailboxRow: View {
    let mailbox: Mailbox
    var isSelected: Bool = false

    private var iconIsProminent: Bool {
        mailbox.role == .inbox || mailbox.unreadCount > 0
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        iconIsProminent
                            ? AnyShapeStyle(MailrTheme.accentGradient)
                            : AnyShapeStyle(MailrTheme.surfaceSoft)
                    )
                Image(systemName: mailbox.role.symbolName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(iconIsProminent ? Color.white : MailrTheme.inkSecondary)
            }
            .frame(width: 26, height: 26)

            Text(mailbox.name)
                .font(.system(
                    size: 13,
                    weight: mailbox.unreadCount > 0 ? .semibold : .medium,
                    design: .rounded
                ))
                .foregroundStyle(isSelected ? MailrTheme.accentDeep : MailrTheme.ink)
                .lineLimit(1)

            Spacer(minLength: 4)

            if mailbox.unreadCount > 0 {
                CountBadge(count: mailbox.unreadCount)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(MailrTheme.selectionGradient) : AnyShapeStyle(Color.clear))
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(MailrTheme.accent.opacity(0.18), lineWidth: 1)
            }
        }
    }
}
