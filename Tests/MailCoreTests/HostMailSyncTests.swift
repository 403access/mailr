import XCTest
@testable import MailCore

final class HostMailSyncTests: XCTestCase {
    private let accountID = UUID()

    private func summary(uid: UInt32 = 1, isOnMailbox: Bool = true) -> MessageSummary {
        MessageSummary(
            uid: uid,
            mailbox: "INBOX",
            subject: "Subject \(uid)",
            from: [EmailAddress(address: "sender@example.com")],
            to: [EmailAddress(address: "me@example.com")],
            date: Date(timeIntervalSince1970: 1_700_000_000),
            snippet: "Snippet",
            size: 100,
            isOnMailbox: isOnMailbox
        )
    }

    private func account(provider: ProviderKind = .custom) -> MailAccount {
        MailAccount(
            id: accountID,
            displayName: "Host Account",
            emailAddress: "host@example.com",
            provider: provider,
            incoming: ServerSettings(host: "imap.example.com", port: 993, security: .tls, username: "host@example.com"),
            outgoing: ServerSettings(host: "smtp.example.com", port: 465, security: .tls, username: "host@example.com")
        )
    }

    // MARK: Router

    func testAccountsEndpointReturnsNonDemoAccounts() throws {
        let database = MailDatabase(inMemory: true)
        let account = account()
        try database.saveAccounts([.demo, account])

        let router = HostMailRouter(database: database)
        let response = router.handle(HostHTTPRequest(method: "GET", path: "/v1/accounts"))

        XCTAssertEqual(response.status, 200)
        let accounts = try JSONDecoder().decode([MailAccount].self, from: response.body)
        XCTAssertEqual(accounts, [account])
    }

    func testRouterProxiesSendAndRefreshesThroughActions() throws {
        let database = MailDatabase(inMemory: true)
        let actions = RecordingActions(database: database)
        let router = HostMailRouter(database: database, actions: actions)

        let message = OutgoingMessage(
            from: EmailAddress(address: "me@example.com"),
            to: [EmailAddress(address: "you@example.com")],
            subject: "Hello",
            text: "Body"
        )
        let sendBody = try JSONEncoder().encode(
            HostSendRequest(accountID: accountID, message: message)
        )
        let sendResponse = router.handle(
            HostHTTPRequest(method: "POST", path: "/v1/send", body: sendBody)
        )
        XCTAssertEqual(sendResponse.status, 200)
        XCTAssertEqual(actions.sendCount, 1)

        let listResponse = router.handle(
            HostHTTPRequest(
                method: "GET",
                path: "/v1/messages/list",
                query: [
                    "accountID": accountID.uuidString,
                    "mailbox": "INBOX",
                    "limit": "10"
                ]
            )
        )
        XCTAssertEqual(listResponse.status, 200)
        XCTAssertEqual(actions.refreshCount, 1)
        let listed = try JSONDecoder().decode([MessageSummary].self, from: listResponse.body)
        XCTAssertEqual(listed.map(\.uid), [1])

        let fetchResponse = router.handle(
            HostHTTPRequest(
                method: "GET",
                path: "/v1/messages",
                query: [
                    "accountID": accountID.uuidString,
                    "mailbox": "INBOX",
                    "uid": "1"
                ]
            )
        )
        XCTAssertEqual(fetchResponse.status, 200)
        XCTAssertEqual(actions.fetchCount, 1)
        let fetched = try JSONDecoder().decode(HostMessageResponse.self, from: fetchResponse.body)
        XCTAssertEqual(fetched.message?.text, "Fetched from origin")
    }

    func testRouterFallsBackToDatabaseWithoutActions() throws {
        let database = MailDatabase(inMemory: true)
        try database.saveMessage(
            MailMessage(summary: summary(), text: "Local body"),
            accountID: accountID
        )
        let router = HostMailRouter(database: database)

        let response = router.handle(
            HostHTTPRequest(
                method: "GET",
                path: "/v1/messages",
                query: [
                    "accountID": accountID.uuidString,
                    "mailbox": "INBOX",
                    "uid": "1"
                ]
            )
        )
        let decoded = try JSONDecoder().decode(HostMessageResponse.self, from: response.body)
        XCTAssertEqual(decoded.message?.text, "Local body")
    }

    // MARK: HostMailService

    func testHostMailServiceUsesHostEndpoints() async throws {
        let store = RecordingHostStore()
        store.mailboxes = [Mailbox(path: "INBOX", name: "Inbox", role: .inbox)]
        store.messages = [summary()]
        store.message = MailMessage(summary: summary(), text: "Host body")

        let service = HostMailService(store: store, accountID: accountID)
        let boxes = try await service.listMailboxes()
        XCTAssertEqual(boxes.map(\.path), ["INBOX"])

        let messages = try await service.fetchMessages(mailbox: "INBOX", limit: 10)
        XCTAssertEqual(messages.count, 1)

        let message = try await service.fetchMessage(mailbox: "INBOX", uid: 1)
        XCTAssertEqual(message.text, "Host body")

        try await service.setFlags(mailbox: "INBOX", uid: 1, flags: [.seen], enabled: true)
        try await service.move(mailbox: "INBOX", uid: 1, to: "Archive")
        try await service.delete(mailbox: "Archive", uid: 1)
        try await service.send(
            OutgoingMessage(
                from: EmailAddress(address: "me@example.com"),
                to: [EmailAddress(address: "you@example.com")],
                subject: "Hi",
                text: "Body"
            )
        )

        XCTAssertEqual(store.flagCalls, 1)
        XCTAssertEqual(store.moveCalls, 1)
        XCTAssertEqual(store.deleteCalls, 1)
        XCTAssertEqual(store.sendCalls, 1)
    }
}

// MARK: - Test doubles

private final class RecordingActions: HostMailActions, @unchecked Sendable {
    let database: MailDatabase
    private(set) var sendCount = 0
    private(set) var refreshCount = 0
    private(set) var fetchCount = 0

    init(database: MailDatabase) {
        self.database = database
    }

    func syncNow() async {}

    func refreshMailboxes(accountID: UUID) async throws -> [Mailbox] {
        try database.loadMailboxes(accountID: accountID)
    }

    func refreshMailbox(
        accountID: UUID,
        mailbox: String,
        limit: Int
    ) async throws -> [MessageSummary] {
        refreshCount += 1
        let summary = MessageSummary(
            uid: 1,
            mailbox: mailbox,
            subject: "Subject 1",
            from: [EmailAddress(address: "sender@example.com")],
            to: [EmailAddress(address: "me@example.com")],
            date: Date(timeIntervalSince1970: 1_700_000_000),
            isOnMailbox: true
        )
        try database.syncMailbox([summary], accountID: accountID, mailbox: mailbox)
        return [summary]
    }

    func fetchMessage(accountID: UUID, mailbox: String, uid: UInt32) async throws -> MailMessage {
        fetchCount += 1
        return MailMessage(
            summary: MessageSummary(
                uid: uid,
                mailbox: mailbox,
                subject: "Subject 1",
                from: [EmailAddress(address: "sender@example.com")],
                date: Date(timeIntervalSince1970: 1_700_000_000),
                isOnMailbox: true
            ),
            text: "Fetched from origin"
        )
    }

    func setFlags(
        accountID: UUID,
        mailbox: String,
        uid: UInt32,
        flags: Set<MessageFlag>,
        enabled: Bool
    ) async throws {}

    func move(accountID: UUID, from source: String, uid: UInt32, to destination: String) async throws {}

    func delete(accountID: UUID, mailbox: String, uid: UInt32) async throws {}

    func send(_ message: OutgoingMessage, accountID: UUID) async throws {
        sendCount += 1
    }

    func statusSnapshot() async -> HostMailSyncStatus {
        HostMailSyncStatus()
    }
}

private final class RecordingHostStore: HostMailStore, @unchecked Sendable {
    var mailboxes: [Mailbox] = []
    var messages: [MessageSummary] = []
    var message: MailMessage?
    private(set) var flagCalls = 0
    private(set) var moveCalls = 0
    private(set) var deleteCalls = 0
    private(set) var sendCalls = 0

    func health() async throws -> HostMailHealth {
        HostMailHealth(status: "ok", messageCount: 0, databasePath: ":memory:")
    }

    func accounts() async throws -> [MailAccount] { [] }

    func requestSync() async throws {}

    func send(_ message: OutgoingMessage, accountID: UUID) async throws {
        sendCalls += 1
    }

    func mailboxes(accountID: UUID) async throws -> [Mailbox] {
        mailboxes
    }

    func syncMailbox(
        accountID: UUID,
        mailbox: String,
        messages: [MessageSummary],
        absentUIDs: [UInt32]
    ) async throws {}

    func mailboxSnapshot(
        accountID: UUID,
        mailbox: String,
        limit: Int
    ) async throws -> [MessageSummary] {
        messages
    }

    func storeMessage(_ message: MailMessage, accountID: UUID) async throws {}

    func storedMessage(accountID: UUID, mailbox: String, uid: UInt32) async throws -> MailMessage? {
        message
    }

    func storageStatus(
        accountID: UUID,
        mailbox: String,
        uid: UInt32
    ) async throws -> HostStorageResponse? {
        nil
    }

    func deleteMessage(accountID: UUID, mailbox: String, uid: UInt32) async throws {
        deleteCalls += 1
    }

    func moveMessage(
        accountID: UUID,
        from source: String,
        uid: UInt32,
        to destination: String
    ) async throws {
        moveCalls += 1
    }

    func updateFlags(
        accountID: UUID,
        mailbox: String,
        uid: UInt32,
        isRead: Bool?,
        isFlagged: Bool?,
        isAnswered: Bool?
    ) async throws {
        flagCalls += 1
    }

    func saveMailboxes(_ mailboxes: [Mailbox], accountID: UUID) async throws {}
}
