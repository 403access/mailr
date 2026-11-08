import Foundation

/// Serves mail that was imported into the local database (for example from a
/// Thunderbird profile). It implements the same protocol as the IMAP service so
/// the rest of the app can browse, flag, move, and delete local mail.
public actor LocalMailService: MailService {
    private let database: MailDatabase
    private let accountID: UUID

    public init(database: MailDatabase, accountID: UUID) {
        self.database = database
        self.accountID = accountID
    }

    public func listMailboxes() async throws -> [Mailbox] {
        Mailbox.sorted(try database.loadMailboxes(accountID: accountID))
    }

    public func fetchMessages(mailbox: String, limit: Int) async throws -> [MessageSummary] {
        try database.loadMessages(accountID: accountID, mailbox: mailbox, limit: limit)
    }

    public func fetchMessage(mailbox: String, uid: UInt32) async throws -> MailMessage {
        guard let message = try database.loadMessage(
            accountID: accountID,
            mailbox: mailbox,
            uid: uid
        ) else {
            throw MailError.commandFailed("That message is no longer available.")
        }
        return message
    }

    public func setFlags(
        mailbox: String,
        uid: UInt32,
        flags: Set<MessageFlag>,
        enabled: Bool
    ) async throws {
        try database.updateFlags(
            accountID: accountID,
            mailbox: mailbox,
            uid: uid,
            isRead: flags.contains(.seen) ? enabled : nil,
            isFlagged: flags.contains(.flagged) ? enabled : nil,
            isAnswered: flags.contains(.answered) ? enabled : nil
        )
    }

    public func move(mailbox: String, uid: UInt32, to destination: String) async throws {
        guard destination != mailbox else { return }
        guard try database.loadMailboxes(accountID: accountID).contains(where: { $0.path == destination }) else {
            throw MailError.commandFailed("No mailbox named \(destination).")
        }
        guard try database.moveMessage(
            accountID: accountID,
            from: mailbox,
            uid: uid,
            to: destination
        ) != nil else {
            throw MailError.commandFailed("That message is no longer available.")
        }
    }

    public func delete(mailbox: String, uid: UInt32) async throws {
        let boxes = try database.loadMailboxes(accountID: accountID)
        if let trash = boxes.first(where: { $0.role == .trash }), trash.path != mailbox {
            try await move(mailbox: mailbox, uid: uid, to: trash.path)
        } else {
            try database.deleteMessage(accountID: accountID, mailbox: mailbox, uid: uid)
        }
    }

    public func send(_ message: OutgoingMessage) async throws {
        throw MailError.notConfigured(
            "This account only contains imported local mail. Choose a mail account to send a message."
        )
    }

    public func close() async {}
}
