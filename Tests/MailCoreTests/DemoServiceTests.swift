import XCTest
@testable import MailCore

final class DemoServiceTests: XCTestCase {
    func testSeedMailboxesAndMessages() async throws {
        let service = DemoMailService()
        let boxes = try await service.listMailboxes()
        XCTAssertEqual(boxes.first?.role, .inbox)
        XCTAssertTrue(boxes.contains { $0.role == .sent })
        XCTAssertTrue(boxes.contains { $0.role == .trash })

        let messages = try await service.fetchMessages(mailbox: "INBOX", limit: 100)
        XCTAssertEqual(messages.count, 6)
        XCTAssertEqual(messages.first?.subject, "Welcome to Mailr")
        XCTAssertEqual(messages.filter(\.isUnread).count, 2)
        XCTAssertFalse(messages.first?.snippet.isEmpty ?? true)
    }

    func testFetchMessageBodyAndAttachment() async throws {
        let service = DemoMailService()
        let messages = try await service.fetchMessages(mailbox: "INBOX", limit: 100)
        let review = try XCTUnwrap(messages.first { $0.subject.contains("Design review") })
        let message = try await service.fetchMessage(mailbox: "INBOX", uid: review.uid)

        XCTAssertNotNil(message.html)
        XCTAssertTrue(message.html?.contains("Aurora composer") == true)
        XCTAssertEqual(message.attachments.count, 1)
        XCTAssertEqual(message.attachments.first?.filename, "Aurora-notes.md")
    }

    func testFlagUpdatesUnreadCount() async throws {
        let service = DemoMailService()
        let before = try await service.listMailboxes()
        let inboxBefore = try XCTUnwrap(before.first { $0.role == .inbox })
        XCTAssertEqual(inboxBefore.unreadCount, 2)

        let messages = try await service.fetchMessages(mailbox: "INBOX", limit: 100)
        let unread = try XCTUnwrap(messages.first(where: \.isUnread))
        try await service.setFlags(mailbox: "INBOX", uid: unread.uid, flags: [.seen], enabled: true)

        let after = try await service.listMailboxes()
        XCTAssertEqual(after.first { $0.role == .inbox }?.unreadCount, 1)
    }

    func testSendAppendsToSent() async throws {
        let service = DemoMailService()
        let before = try await service.fetchMessages(mailbox: "Sent", limit: 100).count

        let outgoing = OutgoingMessage(
            from: EmailAddress(address: "demo@mailr.app", name: "Mailr Demo"),
            to: [EmailAddress(address: "test@example.com", name: "Test Person")],
            subject: "Hello from a test",
            text: "This is a test message."
        )
        try await service.send(outgoing)

        let after = try await service.fetchMessages(mailbox: "Sent", limit: 100)
        XCTAssertEqual(after.count, before + 1)
        XCTAssertEqual(after.first?.subject, "Hello from a test")
        let body = try await service.fetchMessage(mailbox: "Sent", uid: try XCTUnwrap(after.first?.uid))
        XCTAssertEqual(body.text, "This is a test message.")
    }

    func testDeleteMovesToTrash() async throws {
        let service = DemoMailService()
        let messages = try await service.fetchMessages(mailbox: "INBOX", limit: 100)
        let target = try XCTUnwrap(messages.last)

        try await service.delete(mailbox: "INBOX", uid: target.uid)

        let inbox = try await service.fetchMessages(mailbox: "INBOX", limit: 100)
        XCTAssertFalse(inbox.contains { $0.uid == target.uid })

        let trash = try await service.fetchMessages(mailbox: "Trash", limit: 100)
        XCTAssertTrue(trash.contains { $0.uid == target.uid })

        // Deleting from Trash removes the message permanently.
        try await service.delete(mailbox: "Trash", uid: target.uid)
        let emptied = try await service.fetchMessages(mailbox: "Trash", limit: 100)
        XCTAssertFalse(emptied.contains { $0.uid == target.uid })
    }
}

final class AccountStoreTests: XCTestCase {
    func testSaveAndLoadRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailrTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(fileURL: directory.appendingPathComponent("accounts.json"))
        XCTAssertEqual(try store.load(), [])

        let account = MailAccount(
            displayName: "Test",
            emailAddress: "test@example.com",
            provider: .custom,
            incoming: ServerSettings(host: "imap.example.com", port: 993, security: .tls, username: "test"),
            outgoing: ServerSettings(host: "smtp.example.com", port: 465, security: .tls, username: "test")
        )
        try store.save([account])

        let loaded = try store.load()
        XCTAssertEqual(loaded, [account])
        XCTAssertEqual(loaded.first?.incoming.host, "imap.example.com")
    }
}
