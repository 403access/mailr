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
            Divider()

            content
        }
        .background(.background)
        .navigationTitle(compact ? (model.activeMailbox?.name ?? "Mail") : "")
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

                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .mailrHelp("Refresh Mail (⇧⌘R)")
                .disabled(model.isRefreshing)
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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if !compact {
                    Text(model.activeMailbox?.name ?? "Mail")
                        .font(.title3.weight(.semibold))
                }
                if let mailbox = model.activeMailbox {
                    Text(subtitle(for: mailbox))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if model.isLoadingMessages {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, compact ? 6 : 12)
        .padding(.bottom, compact ? 8 : 10)
    }

    private func subtitle(for mailbox: Mailbox) -> String {
        let count = model.messages.count
        let unread = model.messages.filter(\.isUnread).count
        if count == 0 { return "Empty" }
        if unread == 0 { return "\(count) message\(count == 1 ? "" : "s")" }
        return "\(count) message\(count == 1 ? "" : "s") · \(unread) unread"
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
                        .buttonStyle(.borderedProminent)
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
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 40)
            }
        } else if model.messages.isEmpty {
            if model.isLoadingMessages {
                ProgressView("Loading mail…")
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
                    showsRecipient: showsRecipient
                )
                .tag(message.id)
                .listRowInsets(EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12))
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var compactList: some View {
        List {
            ForEach(model.filteredMessages) { message in
                NavigationLink(value: MessageRoute(messageID: message.id)) {
                    MessageRow(
                        message: message,
                        showsRecipient: showsRecipient
                    )
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
            }
        }
        .listStyle(.plain)
        .navigationDestination(for: MessageRoute.self) { route in
            MessageDetailScreen(messageID: route.messageID)
        }
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(
                    name: message.from.first?.name ?? "",
                    address: message.senderAddress,
                    size: 30
                )
                if message.isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Color.mailrWindowBackground, lineWidth: 1.5))
                        .offset(x: 1, y: 1)
                }
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(senderLine)
                        .font(.system(size: 13, weight: message.isUnread ? .semibold : .regular))
                        .lineLimit(1)

                    if message.isFlagged {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.yellow)
                    }
                    if message.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 4)

                    Text(MailDateFormat.listDate(message.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Text(message.subject)
                    .font(.system(size: 13, weight: message.isUnread ? .medium : .regular))
                    .foregroundStyle(message.isUnread ? .primary : .secondary)
                    .lineLimit(1)

                if !message.snippet.isEmpty {
                    Text(message.snippet)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
        .opacity(message.isUnread ? 1 : 0.88)
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
