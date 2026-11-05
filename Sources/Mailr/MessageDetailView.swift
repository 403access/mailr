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

            Divider()

            if hasRemoteContent {
                remoteBanner
                Divider()
            }

            bodyContent

            if !visibleAttachments.isEmpty {
                Divider()
                attachmentBar
            }
        }
        .background(.background)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                AvatarView(
                    name: message.summary.from.first?.name ?? "",
                    address: message.summary.senderAddress,
                    size: 38
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(message.summary.senderDisplayName)
                        .font(.system(size: 14, weight: .semibold))
                    Text(message.summary.senderAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                Text(MailDateFormat.detailDate(message.summary.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            Text(message.summary.subject)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            recipientsLine
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
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
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .textSelection(.enabled)
    }

    private var remoteBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: model.remoteContentAllowed ? "eye" : "eye.slash")
                .foregroundStyle(.secondary)
            Text(model.remoteContentAllowed
                 ? "Remote images are visible. They may let the sender know you opened this message."
                 : "Remote images are blocked to protect your privacy.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()

            Button(model.remoteContentAllowed ? "Block" : "Load") {
                model.remoteContentAllowed.toggle()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
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
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
            }
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
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .background(.bar)
    }

    private func export(_ attachment: MailAttachment) {
        exportDocument = AttachmentDocument(data: attachment.data)
        exportFilename = attachment.filename
        exportType = AttachmentContentType.type(for: attachment)
        isExporting = true
    }
}
