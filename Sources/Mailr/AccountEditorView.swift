import SwiftUI
import MailCore

struct AccountEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var account: MailAccount
    @State private var password = ""
    @State private var errorText: String?
    @State private var testOutcome: TestOutcome?
    @State private var isTesting = false
    @State private var isSaving = false

    private let isNew: Bool

    private struct TestOutcome {
        var success: Bool
        var message: String
    }

    init(account: MailAccount?) {
        self.isNew = account == nil
        _account = State(initialValue: account ?? Self.makeNewAccount())
    }

    static func makeNewAccount() -> MailAccount {
        let provider = ProviderKind.gmail
        return MailAccount(
            displayName: "",
            emailAddress: "",
            provider: provider,
            incoming: provider.incomingDefaults ?? ServerSettings(host: "", port: 993, security: .tls, username: ""),
            outgoing: provider.outgoingDefaults ?? ServerSettings(host: "", port: 465, security: .tls, username: "")
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    accountSection
                    serverSection(
                        title: "Incoming Mail",
                        symbol: "tray.and.arrow.down",
                        settings: $account.incoming
                    )
                    serverSection(
                        title: "Outgoing Mail",
                        symbol: "paperplane",
                        settings: $account.outgoing
                    )

                    if account.incoming.security == .plaintext || account.outgoing.security == .plaintext {
                        Label(
                            "Unencrypted connections are only appropriate for a local mail server. Credentials will be sent without TLS.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.amber)
                        .padding(.horizontal, 2)
                    }
                }
                .padding(16)
            }

            if let testOutcome {
                Rectangle()
                    .fill(MailrTheme.hairline)
                    .frame(height: 1)
                HStack(spacing: 7) {
                    Image(systemName: testOutcome.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(testOutcome.success ? MailrTheme.mint : .red)
                    Text(testOutcome.message)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(MailrTheme.inkSecondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }

            if let errorText {
                Rectangle()
                    .fill(MailrTheme.hairline)
                    .frame(height: 1)
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(errorText)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }

            Rectangle()
                .fill(MailrTheme.hairline)
                .frame(height: 1)
            footer
        }
        .modifier(AccountEditorSizing())
        .background { MailrBackground() }
        .tint(MailrTheme.accent)
        .onChange(of: account.provider) { _, newValue in
            applyPreset(for: newValue)
        }
        .onChange(of: account.emailAddress) { _, newValue in
            applyUsername(newValue)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                MailrSectionLabel(text: "Account")
                Text(isNew ? "Add Account" : "Edit Account")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var accountSection: some View {
        sectionCard(title: "Account", symbol: "person.crop.circle") {
            fieldRow("Name") {
                TextField("Your name", text: $account.displayName)
                    .textFieldStyle(.roundedBorder)
            }

            fieldRow("Email") {
                TextField("you@example.com", text: $account.emailAddress)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.emailAddress)
            }

            fieldRow("Provider") {
                Picker("Provider", selection: $account.provider) {
                    ForEach(ProviderKind.allCases.filter { $0 != .demo }, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            if let note = account.provider.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 84)
            }

            if !account.isDemo {
                fieldRow("Password") {
                    SecureField(
                        isNew ? "App password" : "Leave blank to keep the saved password",
                        text: $password
                    )
                    .textFieldStyle(.roundedBorder)
                }

                Text("Mailr uses direct TLS on IMAP 993 and SMTP 465. Providers that require app passwords will not accept your normal account password.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 84)
            }
        }
    }

    private func serverSection(
        title: String,
        symbol: String,
        settings: Binding<ServerSettings>
    ) -> some View {
        sectionCard(title: title, symbol: symbol) {
            fieldRow("Host") {
                TextField("mail.example.com", text: settings.host)
                    .textFieldStyle(.roundedBorder)
            }

            fieldRow("Port") {
                TextField("Port", value: settings.port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .mailrNumberPad()
                    .frame(width: 90)
                Spacer()
            }

            fieldRow("Security") {
                Picker("Security", selection: settings.security) {
                    ForEach(ServerSecurity.allCases, id: \.self) { security in
                        Text(security.displayName).tag(security)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                Spacer()
            }

            fieldRow("Username") {
                TextField("Usually your email address", text: settings.username)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if isTesting {
                ProgressView()
                    .controlSize(.small)
                    .tint(MailrTheme.accent)
                Text("Testing connection…")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(MailrTheme.inkSecondary)
            }

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))

            Button {
                test()
            } label: {
                Label("Test", systemImage: "bolt.horizontal")
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .disabled(isTesting || isSaving)

            Button {
                save()
            } label: {
                if isSaving {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Saving…")
                    }
                } else {
                    Text("Save")
                }
            }
            .buttonStyle(.mailrPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(isTesting || isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background { MailrBarBackground(edge: .top) }
    }

    private func sectionCard<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(MailrTheme.ink)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .mailrCard(radius: 18, shadowRadius: 10)
    }

    private func fieldRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(MailrTheme.inkSecondary)
                .frame(width: 74, alignment: .trailing)
            content()
        }
    }

    private func applyPreset(for provider: ProviderKind) {
        guard provider != .custom, provider != .demo,
              let incoming = provider.incomingDefaults,
              let outgoing = provider.outgoingDefaults else {
            return
        }
        account.incoming = incoming
        account.outgoing = outgoing
        applyUsername(account.emailAddress)
        testOutcome = nil
    }

    private func applyUsername(_ email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if account.provider != .custom {
            account.incoming.username = trimmed
            account.outgoing.username = trimmed
        } else {
            if account.incoming.username.isEmpty { account.incoming.username = trimmed }
            if account.outgoing.username.isEmpty { account.outgoing.username = trimmed }
        }
    }

    private func normalizedAccount() -> MailAccount {
        var candidate = account
        candidate.displayName = candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.emailAddress = candidate.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)

        if candidate.displayName.isEmpty {
            candidate.displayName = candidate.emailAddress
                .split(separator: "@").first.map(String.init) ?? candidate.emailAddress
        }

        for keyPath in [\MailAccount.incoming, \MailAccount.outgoing] {
            candidate[keyPath: keyPath].host = candidate[keyPath: keyPath].host
                .trimmingCharacters(in: .whitespacesAndNewlines)
            candidate[keyPath: keyPath].username = candidate[keyPath: keyPath].username
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate[keyPath: keyPath].username.isEmpty {
                candidate[keyPath: keyPath].username = candidate.emailAddress
            }
        }

        return candidate
    }

    private func save() {
        guard !isSaving else { return }
        errorText = nil

        let candidate = normalizedAccount()

        guard candidate.emailAddress.contains("@") else {
            errorText = "Enter a valid email address."
            return
        }
        guard !candidate.incoming.host.isEmpty else {
            errorText = "Enter the incoming (IMAP) server host."
            return
        }
        guard !candidate.outgoing.host.isEmpty else {
            errorText = "Enter the outgoing (SMTP) server host."
            return
        }
        guard candidate.incoming.port > 0, candidate.incoming.port <= 65_535,
              candidate.outgoing.port > 0, candidate.outgoing.port <= 65_535 else {
            errorText = "Server ports must be between 1 and 65535."
            return
        }
        if !candidate.isDemo, isNew, password.isEmpty {
            errorText = "Enter the account password."
            return
        }

        isSaving = true
        let secret: String? = password.isEmpty ? nil : password

        Task {
            do {
                try await model.saveAccount(candidate, password: secret)
                dismiss()
            } catch {
                isSaving = false
                errorText = error.localizedDescription
            }
        }
    }

    private func test() {
        guard !isTesting else { return }
        errorText = nil
        testOutcome = nil

        let candidate = normalizedAccount()
        guard candidate.emailAddress.contains("@"),
              !candidate.incoming.host.isEmpty else {
            errorText = "Fill in the email address and incoming server before testing."
            return
        }

        let secret: String
        if !password.isEmpty {
            secret = password
        } else if isNew || candidate.isDemo {
            secret = ""
        } else {
            secret = model.passwordForEditing(candidate.id)
        }

        isTesting = true
        Task {
            do {
                let count = try await model.testAccount(candidate, password: secret)
                testOutcome = TestOutcome(
                    success: true,
                    message: "Connected successfully — \(count) mailbox\(count == 1 ? "" : "es") found."
                )
            } catch {
                testOutcome = TestOutcome(success: false, message: error.localizedDescription)
            }
            isTesting = false
        }
    }
}
