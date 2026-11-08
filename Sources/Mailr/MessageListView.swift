import SwiftUI
import MailCore

struct MessageRoute: Hashable {
    var messageID: String
}

struct MessageListView: View {
    @Environment(AppModel.self) private var model
    var compact: Bool = false
    var onOpenDrawer: (() -> Void)? = nil

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)

            content
        }
        .navigationTitle("")
        .mailrInlineNavigationTitle()
        .toolbar {
            #if os(iOS)
            if let onOpenDrawer {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenDrawer) {
                        Label("Show Mailboxes", systemImage: "line.3.horizontal")
                    }
                }
            }
            #endif

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.newCompose()
                } label: {
                    Label("New Message", systemImage: "square.and.pencil")
                }
                .mailrHelp("New Message (⌘N)")
            }
        }
        .searchable(
            text: $model.searchText,
            prompt: "Search mail"
        )
        .task(id: model.selection) {
            await model.selectionDidChange()
        }
        .onChange(of: model.selectedMessageID) { _, _ in
            guard !compact else { return }
            Task { await model.openSelectedMessage() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                MailrSectionLabel(text: "Mailbox")

                HStack(spacing: 10) {
                    if let mailbox = model.activeMailbox {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(MailrTheme.accentGradient)
                                .shadow(color: MailrTheme.accent.opacity(0.25), radius: 8, y: 3)
                            Image(systemName: mailbox.role.symbolName)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 34, height: 34)
                    }

                    Text(model.activeMailbox?.name ?? "Mail")
                        .font(.system(size: compact ? 29 : 25, weight: .bold, design: .rounded))
                        .foregroundStyle(MailrTheme.inkGradient)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                if model.activeMailbox != nil, !model.messages.isEmpty {
                    HStack(spacing: 6) {
                        MailrStatChip(
                            systemImage: "envelope",
                            text: messageCountText
                        )

                        let unread = model.messages.filter(\.isUnread).count
                        if unread > 0 {
                            MailrStatChip(
                                systemImage: "circle.fill",
                                text: "\(unread) unread",
                                highlighted: true
                            )
                        }
                    }
                }
            }

            Spacer()

            if model.isLoadingMessages {
                ProgressView()
                    .controlSize(.small)
                    .tint(MailrTheme.accent)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, compact ? 10 : 18)
        .padding(.bottom, compact ? 12 : 16)
    }

    private var messageCountText: String {
        let count = model.messages.count
        return "\(count) message\(count == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var content: some View {
        if model.selection == nil {
            VStack(spacing: 14) {
                EmptyStateView(
                    icon: "tray",
                    title: "No Mailbox Selected",
                    message: "Choose a mailbox to see its messages."
                )

                if let onOpenDrawer {
                    Button("Choose Mailbox", action: onOpenDrawer)
                        .buttonStyle(.mailrPrimary)
                        .padding(.bottom, 40)
                }
            }
        } else if let error = model.messagesError {
            VStack(spacing: 14) {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "Could Not Load Mail",
                    message: error
                )
                Button("Try Again") {
                    Task { await model.loadMessages(preserveSelection: true) }
                }
                .buttonStyle(.mailrPrimary)
                .padding(.bottom, 40)
            }
        } else if model.messages.isEmpty {
            if model.isLoadingMessages {
                ProgressView("Loading mail…")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .tint(MailrTheme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(
                    icon: "envelope.open",
                    title: "No Messages",
                    message: model.activeMailbox?.role == .inbox
                        ? "Your inbox is empty. Enjoy the quiet."
                        : "There is nothing in this mailbox."
                )
            }
        } else if model.filteredMessages.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No Results",
                message: "No messages match “\(model.searchText)”."
            )
        } else if compact {
            compactList
        } else {
            regularList
        }
    }

    private var regularList: some View {
        List(selection: Binding(
            get: { model.selectedMessageID },
            set: { model.selectedMessageID = $0 }
        )) {
            ForEach(model.filteredMessages) { message in
                MessageRow(
                    message: message,
                    showsRecipient: showsRecipient,
                    isSelected: model.selectedMessageID == message.id
                )
                .tag(message.id)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await model.loadMessages(preserveSelection: true)
        }
    }

    private var compactList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(model.filteredMessages) { message in
                    NavigationLink(value: MessageRoute(messageID: message.id)) {
                        MessageRow(
                            message: message,
                            showsRecipient: showsRecipient
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.bottom, 78, for: .scrollContent)
        .refreshable {
            await model.loadMessages(preserveSelection: true)
        }
    }

    private var showsRecipient: Bool {
        model.activeMailbox?.role == .sent || model.activeMailbox?.role == .drafts
    }
}

struct MessageRow: View {
    let message: MessageSummary
    var showsRecipient: Bool = false
    var isSelected: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(
                    name: message.from.first?.name ?? "",
                    address: message.senderAddress,
                    size: 36
                )
                if message.isUnread {
                    Circle()
                        .fill(MailrTheme.accentGradient)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(MailrTheme.baseTop, lineWidth: 2))
                        .offset(x: 1, y: 1)
                }
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(senderLine)
                        .font(.system(
                            size: 13.5,
                            weight: message.isUnread ? .semibold : .medium,
                            design: .rounded
                        ))
                        .foregroundStyle(MailrTheme.ink)
                        .lineLimit(1)

                    if message.isFlagged {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(MailrTheme.amber)
                    }
                    if message.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(MailrTheme.inkTertiary)
                    }
                    if !message.isOnMailbox {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(MailrTheme.amber)
                            .mailrHelp("Only on the host machine")
                    }

                    Spacer(minLength: 4)

                    Text(MailDateFormat.listDate(message.date))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(MailrTheme.inkTertiary)
                        .monospacedDigit()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(MailrTheme.surfaceSoft, in: Capsule())
                }

                Text(message.subject)
                    .font(.system(
                        size: 13.5,
                        weight: message.isUnread ? .semibold : .medium,
                        design: .rounded
                    ))
                    .foregroundStyle(message.isUnread ? MailrTheme.ink : MailrTheme.inkSecondary)
                    .lineLimit(1)

                if !message.snippet.isEmpty {
                    Text(message.snippet)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(MailrTheme.inkTertiary)
                        .lineLimit(2)
                        .lineSpacing(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(message.isUnread ? MailrTheme.unreadGradient : MailrTheme.cardGradient)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isSelected ? MailrTheme.accent.opacity(0.45) : MailrTheme.border,
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
        .overlay(alignment: .leading) {
            if message.isUnread {
                Capsule()
                    .fill(MailrTheme.accentGradient)
                    .frame(width: 3, height: 34)
                    .padding(.leading, 1)
            }
        }
        .contentShape(Rectangle())
    }

    private var senderLine: String {
        if showsRecipient {
            let recipients = message.to.isEmpty ? message.cc : message.to
            if !recipients.isEmpty {
                return "To: " + recipients.map(\.displayName).joined(separator: ", ")
            }
        }
        return message.senderDisplayName
    }
}
