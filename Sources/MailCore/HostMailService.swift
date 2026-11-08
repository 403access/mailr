import Foundation

/// A `MailService` that reads and acts through the host server instead of
/// opening IMAP on the client. The host is the only component that talks to
/// the origin mail server.
public actor HostMailService: MailService {
    private let store: any HostMailStore
    private let accountID: UUID

    public init(store: any HostMailStore, accountID: UUID) {
        self.store = store
        self.accountID = accountID
    }

    public func listMailboxes() async throws -> [Mailbox] {
        Mailbox.sorted(try await store.mailboxes(accountID: accountID))
    }

    public func fetchMessages(mailbox: String, limit: Int) async throws -> [MessageSummary] {
        try await store.mailboxSnapshot(
            accountID: accountID,
            mailbox: mailbox,
            limit: limit
        )
    }

    public func fetchMessage(mailbox: String, uid: UInt32) async throws -> MailMessage {
        guard let message = try await store.storedMessage(
            accountID: accountID,
            mailbox: mailbox,
            uid: uid
        ) else {
            throw MailError.commandFailed("The host server does not have that message.")
        }
        return message
    }

    public func setFlags(
        mailbox: String,
        uid: UInt32,
        flags: Set<MessageFlag>,
        enabled: Bool
    ) async throws {
        try await store.updateFlags(
            accountID: accountID,
            mailbox: mailbox,
            uid: uid,
            isRead: flags.contains(.seen) ? enabled : nil,
            isFlagged: flags.contains(.flagged) ? enabled : nil,
            isAnswered: flags.contains(.answered) ? enabled : nil
        )
    }

    public func move(mailbox: String, uid: UInt32, to destination: String) async throws {
        try await store.moveMessage(
            accountID: accountID,
            from: mailbox,
            uid: uid,
            to: destination
        )
    }

    public func delete(mailbox: String, uid: UInt32) async throws {
        try await store.deleteMessage(
            accountID: accountID,
            mailbox: mailbox,
            uid: uid
        )
    }

    public func send(_ message: OutgoingMessage) async throws {
        try await store.send(message, accountID: accountID)
    }

    public func close() async {}
}
