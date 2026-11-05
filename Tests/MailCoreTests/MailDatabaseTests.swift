import XCTest
@testable import MailCore

final class MailDatabaseTests: XCTestCase {
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MailrDBTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeAccount() -> MailAccount {
        MailAccount(
            displayName: "Test",
            emailAddress: "test@example.com",
            provider: .custom,
            incoming: ServerSettings(host: "imap.example.com", port: 993, security: .tls, username: "test"),
            outgoing: ServerSettings(host: "smtp.example.com", port: 465, security: .tls, username: "test")
        )
    }

    func testAccountsMailboxesAndMessagesRoundTrip() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mailr.sqlite3")
        let account = makeAccount()

        do {
            let database = MailDatabase(fileURL: url)
            try database.saveAccounts([account])
            try database.saveMailboxes(
                [
                    Mailbox(path: "INBOX", name: "Inbox", role: .inbox, unreadCount: 99, totalCount: 99),
                    Mailbox(path: "Sent", name: "Sent", role: .sent)
                ],
                accountID: account.id
            )

            let summary = MessageSummary(
                uid: 42,
                mailbox: "INBOX",
                subject: "Hello",
                from: [EmailAddress(address: "sender@example.com", name: "Sender")],
                to: [EmailAddress(address: account.emailAddress)],
                date: Date(timeIntervalSince1970: 1_700_000_000),
                snippet: "A snippet",
                size: 1234,
                isRead: false,
                isFlagged: true,
                hasAttachments: true,
                messageID: "<hello@example.com>",
                inReplyTo: "<parent@example.com>",
                references: ["<parent@example.com>"]
            )
            let attachment = MailAttachment(
                filename: "notes.txt",
                mimeType: "text/plain",
                data: Data("attached bytes".utf8)
            )
            try database.saveMessage(
                MailMessage(summary: summary, text: "Plain body", html: "<p>HTML body</p>", attachments: [attachment]),
                accountID: account.id
            )
        }

        // Reopen the file to verify the data really is persisted.
        let reopened = MailDatabase(fileURL: url)
        XCTAssertEqual(try reopened.loadAccounts(), [account])

        let boxes = try reopened.loadMailboxes(accountID: account.id)
        XCTAssertEqual(boxes.first { $0.path == "INBOX" }?.unreadCount, 1)
        XCTAssertEqual(boxes.first { $0.path == "INBOX" }?.totalCount, 1)

        let message = try XCTUnwrap(reopened.loadMessage(accountID: account.id, mailbox: "INBOX", uid: 42))
        XCTAssertEqual(message.summary.subject, "Hello")
        XCTAssertEqual(message.summary.from.first?.name, "Sender")
        XCTAssertEqual(message.summary.references, ["<parent@example.com>"])
        XCTAssertEqual(message.text, "Plain body")
        XCTAssertEqual(message.html, "<p>HTML body</p>")
        XCTAssertEqual(message.attachments.first?.filename, "notes.txt")
        XCTAssertEqual(message.attachments.first?.data, Data("attached bytes".utf8))
    }

    func testFlagsAndDeletionUpdateCachedState() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mailr.sqlite3")
        let account = makeAccount()
        let database = MailDatabase(fileURL: url)
        let summary = MessageSummary(
            uid: 7,
            mailbox: "INBOX",
            subject: "Flag me",
            from: [EmailAddress(address: "a@example.com")],
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try database.saveMessage(MailMessage(summary: summary, text: "Body"), accountID: account.id)

        try database.updateFlags(accountID: account.id, mailbox: "INBOX", uid: 7, isRead: true, isFlagged: true)
        let updated = try XCTUnwrap(database.loadMessages(accountID: account.id, mailbox: "INBOX").first)
        XCTAssertTrue(updated.isRead)
        XCTAssertTrue(updated.isFlagged)

        try database.deleteMessage(accountID: account.id, mailbox: "INBOX", uid: 7)
        XCTAssertTrue(try database.loadMessages(accountID: account.id, mailbox: "INBOX").isEmpty)
        XCTAssertNil(try database.loadMessage(accountID: account.id, mailbox: "INBOX", uid: 7))
    }

    func testDemoMailboxPersistsAcrossRelaunch() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mailr.sqlite3")

        do {
            let database = MailDatabase(fileURL: url)
            let service = DemoMailService(database: database)
            let before = try await service.listMailboxes().first { $0.role == .inbox }
            let messages = try await service.fetchMessages(mailbox: "INBOX", limit: 100)
            let unread = try XCTUnwrap(messages.first(where: \.isUnread))
            try await service.setFlags(mailbox: "INBOX", uid: unread.uid, flags: [.seen], enabled: true)

            let outgoing = OutgoingMessage(
                from: EmailAddress(address: "demo@mailr.app"),
                to: [EmailAddress(address: "friend@example.com")],
                subject: "Persisted send",
                text: "This should survive."
            )
            try await service.send(outgoing)

            XCTAssertEqual(before?.unreadCount, 2)
        }

        // A fresh database handle and service simulate an app relaunch.
        let reopened = MailDatabase(fileURL: url)
        let service = DemoMailService(database: reopened)
        let inbox = try await service.listMailboxes().first { $0.role == .inbox }
        XCTAssertEqual(inbox?.unreadCount, 1)

        let sent = try await service.fetchMessages(mailbox: "Sent", limit: 100)
        XCTAssertTrue(sent.contains { $0.subject == "Persisted send" })
    }

    func testLegacyAccountsJSONIsImportedOnce() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let account = makeAccount()
        let json = try JSONEncoder().encode([account])
        let legacyURL = directory.appendingPathComponent("accounts.json")
        try json.write(to: legacyURL)

        let databaseURL = directory.appendingPathComponent("mailr.sqlite3")
        let database = MailDatabase(fileURL: databaseURL)
        XCTAssertEqual(try database.loadAccounts(), [account])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.appendingPathExtension("migrated").path))

        // Opening again must not duplicate or re-import anything.
        let reopened = MailDatabase(fileURL: databaseURL)
        XCTAssertEqual(try reopened.loadAccounts(), [account])
    }
}
