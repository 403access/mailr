import Foundation

/// Connects the generic IMAP/SMTP clients to a configured account.
public actor IMAPMailService: MailService {
    private let account: MailAccount
    private let password: String
    private var client: IMAPClient?
    private var cachedMailboxes: [Mailbox]?

    public init(account: MailAccount, password: String) {
        self.account = account
        self.password = password
    }

    public func listMailboxes() async throws -> [Mailbox] {
        let boxes = try await withClient { client in
            try await client.listMailboxes()
        }
        cachedMailboxes = boxes
        return boxes
    }

    public func fetchMessages(mailbox: String, limit: Int) async throws -> [MessageSummary] {
        try await withClient { client in
            try await client.fetchSummaries(mailbox: mailbox, limit: limit)
        }
    }

    public func fetchMessage(mailbox: String, uid: UInt32) async throws -> MailMessage {
        try await withClient { client in
            try await client.fetchMessage(mailbox: mailbox, uid: uid)
        }
    }

    public func setFlags(
        mailbox: String,
        uid: UInt32,
        flags: Set<MessageFlag>,
        enabled: Bool
    ) async throws {
        try await withClient { client in
            try await client.setFlags(mailbox: mailbox, uid: uid, flags: flags, enabled: enabled)
        }
    }

    public func move(mailbox: String, uid: UInt32, to destination: String) async throws {
        try await withClient { client in
            try await client.move(mailbox: mailbox, uid: uid, to: destination)
        }
    }

    public func delete(mailbox: String, uid: UInt32) async throws {
        try await withClient { client in
            let boxes = try await cachedOrLoadedMailboxes(client: client)

            if let trash = boxes.first(where: { $0.role == .trash }), trash.path != mailbox {
                try await client.move(mailbox: mailbox, uid: uid, to: trash.path)
            } else {
                try await client.deletePermanently(mailbox: mailbox, uid: uid)
            }
        }
    }

    public func send(_ message: OutgoingMessage) async throws {
        guard !account.outgoing.host.isEmpty else {
            throw MailError.notConfigured("The outgoing mail server is not configured for \(account.displayName).")
        }
        guard !password.isEmpty else {
            throw MailError.authentication("Add a password for \(account.emailAddress) in Settings.")
        }

        let raw = MessageBuilder.build(message)
        let smtp = SMTPClient(
            host: account.outgoing.host,
            port: account.outgoing.port,
            security: account.outgoing.security,
            username: account.outgoing.username.isEmpty ? account.emailAddress : account.outgoing.username,
            password: password
        )
        try await smtp.send(
            raw,
            from: message.from.address,
            recipients: message.allRecipients.map(\.address)
        )

        // Best effort: keep a copy in the Sent folder.
        do {
            try await withClient { client in
                let boxes = try await cachedOrLoadedMailboxes(client: client)
                if let sent = boxes.first(where: { $0.role == .sent }) {
                    try await client.append(raw, to: sent.path, flags: ["\\Seen"])
                    cachedMailboxes = nil
                }
            }
        } catch {
            // The message was sent; failing to save a copy must not make the
            // send look unsuccessful.
        }
    }

    public func close() async {
        await client?.disconnect()
        client = nil
        cachedMailboxes = nil
    }

    // MARK: - Connection management

    private func withClient<T>(
        _ operation: (IMAPClient) async throws -> T
    ) async throws -> T {
        let client = try await connectedClient()
        do {
            return try await operation(client)
        } catch {
            if let mailError = error as? MailError {
                switch mailError {
                case .connection, .protocolViolation:
                    // A suspended iOS app or a sleeping Mac will lose its
                    // socket. Drop it so the next call reconnects cleanly.
                    await client.disconnect()
                    self.client = nil
                    self.cachedMailboxes = nil
                default:
                    break
                }
            }
            throw error
        }
    }

    private func connectedClient() async throws -> IMAPClient {
        if let client { return client }
        guard !password.isEmpty else {
            throw MailError.authentication(
                "No password is saved for \(account.emailAddress). Add one in Settings."
            )
        }
        guard !account.incoming.host.isEmpty else {
            throw MailError.notConfigured("The incoming mail server is not configured for \(account.displayName).")
        }

        let client = IMAPClient(
            host: account.incoming.host,
            port: account.incoming.port,
            security: account.incoming.security,
            username: account.incoming.username.isEmpty ? account.emailAddress : account.incoming.username,
            password: password
        )

        do {
            try await client.connect()
        } catch {
            await client.disconnect()
            throw error
        }

        self.client = client
        return client
    }

    private func cachedOrLoadedMailboxes(client: IMAPClient) async throws -> [Mailbox] {
        if let cachedMailboxes { return cachedMailboxes }
        let boxes = try await client.listMailboxes()
        cachedMailboxes = boxes
        return boxes
    }
}
