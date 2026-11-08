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
            Divider()
            fields
            Divider()
            editor
            if !draft.attachments.isEmpty {
                Divider()
                attachmentStrip
            }
            if let errorText {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 7)
            }
            Divider()
            footer
        }
        .modifier(ComposeSizing())
        .background(.background)
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
        HStack {
            Text("New Message")
                .font(.headline)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .mailrHelp("Close")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
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

            Divider().padding(.leading, 70)

            composeRow(label: "To") {
                TextField("name@example.com", text: $draft.to)
                    .textFieldStyle(.plain)
                    .textContentType(.emailAddress)
                    .focused($focusedField, equals: .to)

                Button(showCcBcc ? "Hide Cc/Bcc" : "Cc/Bcc") {
                    withAnimation(.snappy(duration: 0.16)) {
                        showCcBcc.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if showCcBcc {
                Divider().padding(.leading, 70)
                composeRow(label: "Cc") {
                    TextField("name@example.com", text: $draft.cc)
                        .textFieldStyle(.plain)
                }
                Divider().padding(.leading, 70)
                composeRow(label: "Bcc") {
                    TextField("name@example.com", text: $draft.bcc)
                        .textFieldStyle(.plain)
                }
            }

            Divider().padding(.leading, 70)

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
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            content()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $draft.body)
                .font(.system(size: 14))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .focused($focusedField, equals: .body)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)

            if draft.body.isEmpty {
                Text("Write your message…")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(attachment.filename)
                            .font(.caption)
                            .lineLimit(1)
                        Button {
                            draft.attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                isImporting = true
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.borderless)
            .mailrHelp("Attach a file")

            if !draft.attachments.isEmpty {
                Text("\(draft.attachments.count) attachment\(draft.attachments.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel") {
                dismiss()
            }
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
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(draft.isSending)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
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
