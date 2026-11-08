import SwiftUI
import UniformTypeIdentifiers
import MailCore

struct MessageDetailScreen: View {
    @Environment(AppModel.self) private var model
    let messageID: String

    var body: some View {
        MessageDetailView()
            .task {
                if model.selectedMessageID != messageID {
                    model.selectedMessageID = messageID
                }
                await model.openSelectedMessage()
            }
    }
}

struct MessageDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let message = model.currentMessage {
                MessageReaderView(message: message)
            } else if model.isLoadingBody, model.selectedSummary != nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading message…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.selectedSummary != nil {
                EmptyStateView(
                    icon: "envelope",
                    title: "Message Unavailable",
                    message: "This message could not be opened. Try refreshing your mail."
                )
            } else {
                EmptyStateView(
                    icon: "envelope.open",
                    title: "No Message Selected",
                    message: "Select a message to read it, or use compose to write a new one."
                )
            }
        }
        .navigationTitle("")
        .mailrInlineNavigationTitle()
        .background { MailrBackground() }
        .toolbar {
            if let summary = model.currentMessage?.summary ?? model.selectedSummary {
                #if os(iOS)
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        model.replyToCurrentMessage()
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }

                    Menu {
                        Button {
                            model.toggleFlag(summary)
                        } label: {
                            Label(
                                summary.isFlagged ? "Remove Flag" : "Flag",
                                systemImage: summary.isFlagged ? "star.slash" : "star"
                            )
                        }

                        Button {
                            model.markUnread(summary)
                        } label: {
                            Label("Mark as Unread", systemImage: "envelope.badge")
                        }

                        Divider()

                        Button(role: .destructive) {
                            model.delete(summary)
                            dismiss()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
                #else
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        model.replyToCurrentMessage()
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .mailrHelp("Reply (⌘R)")

                    Button {
                        model.toggleFlag(summary)
                    } label: {
                        Label(
                            summary.isFlagged ? "Unflag" : "Flag",
                            systemImage: summary.isFlagged ? "star.fill" : "star"
                        )
                    }
                    .mailrHelp(summary.isFlagged ? "Remove Flag" : "Flag")

                    Button {
                        model.markUnread(summary)
                    } label: {
                        Label("Mark Unread", systemImage: "envelope.badge")
                    }
                    .mailrHelp("Mark as Unread")

                    Button(role: .destructive) {
                        model.delete(summary)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .mailrHelp("Delete (⌘⌫)")
                }
                #endif
            }
        }
    }
}

struct MessageReaderView: View {
    let message: MailMessage
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    @State private var exportDocument: AttachmentDocument?
    @State private var exportFilename = "attachment"
    @State private var exportType: UTType = .data
    @State private var isExporting = false

    private var visibleAttachments: [MailAttachment] {
        message.attachments.filter(\.isVisibleAttachment)
    }

    private var hasRemoteContent: Bool {
        guard let html = message.html else { return false }
        return html.range(
            of: "(?i)(src|background)\\s*=\\s*[\"']?https?://|url\\(\\s*[\"']?https?://",
            options: .regularExpression
        ) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if hasRemoteContent {
                remoteBanner
            }

            bodyContent
                .background(MailrTheme.surfaceStrong)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(MailrTheme.border, lineWidth: 1)
                }
                .shadow(color: MailrTheme.shadow, radius: 14, y: 6)
                .padding(.horizontal, 12)
                .padding(.top, hasRemoteContent ? 8 : 4)
                .padding(.bottom, visibleAttachments.isEmpty ? 12 : 8)

            if !visibleAttachments.isEmpty {
                attachmentBar
            }
        }
        .background { MailrBackground() }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: exportFilename
        ) { result in
            exportDocument = nil
            if case .failure(let error) = result {
                model.errorMessage = "Could not save the attachment: \(error.localizedDescription)"
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(
                    name: message.summary.from.first?.name ?? "",
                    address: message.summary.senderAddress,
                    size: 42
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(message.summary.senderDisplayName)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(MailrTheme.ink)
                    Text(message.summary.senderAddress)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkTertiary)
                        .textSelection(.enabled)
                }

                Spacer()

                Text(MailDateFormat.detailDate(message.summary.date))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(MailrTheme.inkSecondary)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MailrTheme.surfaceSoft, in: Capsule())
            }

            Text(message.summary.subject)
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundStyle(MailrTheme.inkGradient)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            recipientsLine
        }
        .padding(16)
        .mailrCard(radius: 22, shadowRadius: 14)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var recipientsLine: some View {
        var parts: [String] = []
        if !message.summary.to.isEmpty {
            parts.append("To: " + message.summary.to.map(\.displayName).joined(separator: ", "))
        }
        if !message.summary.cc.isEmpty {
            parts.append("Cc: " + message.summary.cc.map(\.displayName).joined(separator: ", "))
        }

        return Text(parts.joined(separator: "   ·   "))
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(MailrTheme.inkTertiary)
            .lineLimit(2)
            .textSelection(.enabled)
    }

    private var remoteBanner: some View {
        HStack(spacing: 9) {
            Image(systemName: model.remoteContentAllowed ? "eye" : "eye.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MailrTheme.amber)
            Text(model.remoteContentAllowed
                 ? "Remote images are visible. They may let the sender know you opened this message."
                 : "Remote images are blocked to protect your privacy.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(MailrTheme.inkSecondary)
                .lineLimit(2)

            Spacer()

            Button(model.remoteContentAllowed ? "Block" : "Load") {
                model.remoteContentAllowed.toggle()
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(MailrTheme.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(MailrTheme.amber.opacity(0.20), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var bodyContent: some View {
        if let html = message.html, !html.isEmpty {
            HTMLMessageView(
                html: html,
                allowRemote: model.remoteContentAllowed,
                colorScheme: colorScheme
            )
        } else if let text = message.text, !text.isEmpty {
            ScrollView {
                Text(text)
                    .font(.system(size: 14.5, weight: .regular, design: .rounded))
                    .foregroundStyle(MailrTheme.ink)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
            }
            .background(MailrTheme.surfaceStrong)
        } else {
            EmptyStateView(
                icon: "doc",
                title: "No Message Body",
                message: "This message has no readable text."
            )
        }
    }

    private var attachmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleAttachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        export(attachment)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background { MailrBarBackground(edge: .top) }
    }

    private func export(_ attachment: MailAttachment) {
        exportDocument = AttachmentDocument(data: attachment.data)
        exportFilename = attachment.filename
        exportType = AttachmentContentType.type(for: attachment)
        isExporting = true
    }
}
