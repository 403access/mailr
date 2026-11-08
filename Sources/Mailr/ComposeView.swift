import SwiftUI
import UniformTypeIdentifiers
import MailCore

struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ComposeDraft
    @State private var showCcBcc = false
    @State private var isImporting = false
    @State private var errorText: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case to
        case subject
        case body
    }

    init(draft: ComposeDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)

            VStack(spacing: 10) {
                fields
                    .mailrCard(radius: 18, shadowRadius: 10)

                editor
                    .mailrCard(radius: 18, shadowRadius: 10)

                if !draft.attachments.isEmpty {
                    attachmentStrip
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxHeight: .infinity)

            if let errorText {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(errorText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
            }

            footer
        }
        .modifier(ComposeSizing())
        .background { MailrBackground() }
        .tint(MailrTheme.accent)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .onAppear {
            #if os(macOS)
            DispatchQueue.main.async {
                focusedField = .to
            }
            #endif
        }
        .onDisappear {
            model.composeViewDidDisappear(draft)
        }
    }

    private var titleBar: some View {
        HStack(spacing: 11) {
            MailrLogoMark(size: 34)

            VStack(alignment: .leading, spacing: 1) {
                MailrSectionLabel(text: "Compose")
                Text("New Message")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(MailrTheme.inkGradient)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(MailrIconButtonStyle(size: 32))
            .keyboardShortcut(.cancelAction)
            .mailrHelp("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var fields: some View {
        VStack(spacing: 0) {
            composeRow(label: "From") {
                Picker("From", selection: $draft.accountID) {
                    ForEach(model.runtimes) { runtime in
                        Text("\(runtime.account.displayName) — \(runtime.account.emailAddress)")
                            .tag(runtime.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.regular)
            }

            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)
                .padding(.leading, 70)

            composeRow(label: "To") {
                TextField("", text: $draft.to)
                    .textFieldStyle(.plain)
                    .mailrEmailKeyboard()
                    .focused($focusedField, equals: .to)
                    .overlay(alignment: .leading) {
                        if draft.to.isEmpty {
                            Text("Email address")
                                .foregroundColor(MailrTheme.inkTertiary)
                                .allowsHitTesting(false)
                        }
                    }

                Button(showCcBcc ? "Hide Cc/Bcc" : "Cc/Bcc") {
                    withAnimation(.snappy(duration: 0.16)) {
                        showCcBcc.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(MailrTheme.accent)
            }

            if showCcBcc {
                Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)
                .padding(.leading, 70)
                composeRow(label: "Cc") {
                    TextField("", text: $draft.cc)
                        .textFieldStyle(.plain)
                        .overlay(alignment: .leading) {
                            if draft.cc.isEmpty {
                                Text("Email address")
                                    .foregroundColor(MailrTheme.inkTertiary)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)
                .padding(.leading, 70)
                composeRow(label: "Bcc") {
                    TextField("", text: $draft.bcc)
                        .textFieldStyle(.plain)
                        .overlay(alignment: .leading) {
                            if draft.bcc.isEmpty {
                                Text("Email address")
                                    .foregroundColor(MailrTheme.inkTertiary)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }

            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)
                .padding(.leading, 70)

            composeRow(label: "Subject") {
                TextField("Subject", text: $draft.subject)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .subject)
            }
        }
    }

    private func composeRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(MailrTheme.inkSecondary)
                .frame(width: 58, alignment: .leading)
            content()
        }
        .font(.system(size: 13.5, weight: .regular, design: .rounded))
        .foregroundStyle(MailrTheme.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft.body)
                .font(.system(size: 14.5, weight: .regular, design: .rounded))
                .foregroundStyle(MailrTheme.ink)
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .focused($focusedField, equals: .body)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            if draft.body.isEmpty {
                Text("Write your message…")
                    .font(.system(size: 14.5, weight: .regular, design: .rounded))
                    .foregroundStyle(MailrTheme.inkTertiary)
                    .padding(.horizontal, 19)
                    .padding(.vertical, 20)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MailrTheme.accent)
                        Text(attachment.filename)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(MailrTheme.inkSecondary)
                            .lineLimit(1)
                        Button {
                            draft.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(MailrTheme.inkTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(MailrTheme.surfaceSoft, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(MailrTheme.hairline, lineWidth: 1)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                isImporting = true
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(MailrIconButtonStyle(size: 34))
            .mailrHelp("Attach a file")

            if !draft.attachments.isEmpty {
                Text("\(draft.attachments.count) attachment\(draft.attachments.count == 1 ? "" : "s")")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(MailrTheme.inkTertiary)
            }

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .keyboardShortcut(.cancelAction)

            Button {
                send()
            } label: {
                if draft.isSending {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Sending…")
                    }
                } else {
                    Text("Send")
                }
            }
            .buttonStyle(.mailrPrimary)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(draft.isSending)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background { MailrBarBackground(edge: .top) }
    }

    private func send() {
        guard !draft.isSending else { return }

        let recipients = EmailAddress.parseList(draft.to)
            + EmailAddress.parseList(draft.cc)
            + EmailAddress.parseList(draft.bcc)
        guard !recipients.isEmpty else {
            errorText = "Add at least one recipient."
            focusedField = .to
            return
        }

        errorText = nil
        draft.isSending = true
        let snapshot = draft

        Task {
            let sent = await model.send(snapshot)
            if sent {
                dismiss()
            } else {
                draft.isSending = false
                errorText = model.errorMessage
                model.errorMessage = nil
            }
        }
    }

    private func handleImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing { url.stopAccessingSecurityScopedResource() }
                }

                do {
                    let data = try Data(contentsOf: url)
                    guard data.count <= 30 * 1024 * 1024 else {
                        errorText = "\(url.lastPathComponent) is larger than 30 MB."
                        continue
                    }
                    let type = UTType(filenameExtension: url.pathExtension)
                    draft.attachments.append(
                        OutgoingAttachment(
                            filename: url.lastPathComponent,
                            mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                            data: data
                        )
                    )
                } catch {
                    errorText = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        case .failure(let error):
            errorText = error.localizedDescription
        }
    }
}
