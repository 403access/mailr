import XCTest
@testable import MailCore

final class HostMailTests: XCTestCase {
    private let accountID = UUID()

    private func summary(
        uid: UInt32,
        mailbox: String = "INBOX",
        isOnMailbox: Bool = true
    ) -> MessageSummary {
        MessageSummary(
            uid: uid,
            mailbox: mailbox,
            subject: "Message \(uid)",
            from: [EmailAddress(address: "sender@example.com", name: "Sender")],
            to: [EmailAddress(address: "me@example.com")],
            date: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + Int(uid))),
            snippet: "Snippet \(uid)",
            size: 100,
            isOnMailbox: isOnMailbox
        )
    }

    private func message(uid: UInt32, text: String = "Hello") -> MailMessage {
        MailMessage(summary: summary(uid: uid), text: text)
    }

    // MARK: Database

    func testSyncMailboxMarksVisibleAndAbsentMessages() throws {
        let database = MailDatabase(inMemory: true)

        try database.syncMailbox(
            [summary(uid: 1), summary(uid: 2)],
            accountID: accountID,
            mailbox: "INBOX"
        )
        try database.syncMailbox(
            [summary(uid: 1)],
            accountID: accountID,
            mailbox: "INBOX",
            absentUIDs: [2]
        )

        let rows = try database.loadMessages(accountID: accountID, mailbox: "INBOX", limit: 10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.uid == 1 })?.isOnMailbox, true)
        XCTAssertEqual(rows.first(where: { $0.uid == 2 })?.isOnMailbox, false)
    }

    func testReplaceMessagesKeepsHostOnlyRows() throws {
        let database = MailDatabase(inMemory: true)

        try database.syncMailbox(
            [summary(uid: 1), summary(uid: 2)],
            accountID: accountID,
            mailbox: "INBOX"
        )
        try database.syncMailbox(
            [summary(uid: 1)],
            accountID: accountID,
            mailbox: "INBOX",
            absentUIDs: [2]
        )

        try database.replaceMessages(
            [summary(uid: 3)],
            accountID: accountID,
            mailbox: "INBOX"
        )

        let rows = try database.loadMessages(accountID: accountID, mailbox: "INBOX", limit: 10)
        XCTAssertEqual(Set(rows.map(\.uid)), [2, 3])
        XCTAssertEqual(rows.first(where: { $0.uid == 2 })?.isOnMailbox, false)
        XCTAssertEqual(rows.first(where: { $0.uid == 3 })?.isOnMailbox, true)
    }

    func testStorageFlagsRoundTrip() throws {
        let database = MailDatabase(inMemory: true)
        let stored = message(uid: 7)
        try database.saveMessage(stored, accountID: accountID)

        XCTAssertTrue(try database.hasMessage(accountID: accountID, mailbox: "INBOX", uid: 7))
        XCTAssertEqual(
            try database.isOnMailbox(accountID: accountID, mailbox: "INBOX", uid: 7),
            true
        )

        try database.markOnMailbox(
            accountID: accountID,
            mailbox: "INBOX",
            uids: [7],
            onMailbox: false
        )

        XCTAssertEqual(
            try database.isOnMailbox(accountID: accountID, mailbox: "INBOX", uid: 7),
            false
        )
        XCTAssertEqual(try database.messageCount(), 1)
    }

    // MARK: Router

    func testRouterSyncsFetchesAndReportsStorage() throws {
        let database = MailDatabase(inMemory: true)
        let router = HostMailRouter(database: database)
        let accountID = self.accountID

        let syncBody = try JSONEncoder().encode(
            HostMailboxSyncRequest(
                accountID: accountID,
                mailbox: "INBOX",
                messages: [summary(uid: 1)]
            )
        )
        let syncResponse = router.handle(
            HostHTTPRequest(method: "POST", path: "/v1/sync/mailbox", body: syncBody)
        )
        XCTAssertEqual(syncResponse.status, 200)

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
        let listed = try JSONDecoder().decode([MessageSummary].self, from: listResponse.body)
        XCTAssertEqual(listed.map(\.uid), [1])

        let storeBody = try JSONEncoder().encode(
            HostMessageEnvelope(accountID: accountID, message: message(uid: 1, text: "Body"))
        )
        let storeResponse = router.handle(
            HostHTTPRequest(method: "POST", path: "/v1/messages", body: storeBody)
        )
        XCTAssertEqual(storeResponse.status, 200)

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
        let fetched = try JSONDecoder().decode(HostMessageResponse.self, from: fetchResponse.body)
        XCTAssertEqual(fetched.message?.text, "Body")

        let storageResponse = router.handle(
            HostHTTPRequest(
                method: "GET",
                path: "/v1/storage",
                query: [
                    "accountID": accountID.uuidString,
                    "mailbox": "INBOX",
                    "uid": "1"
                ]
            )
        )
        let storage = try JSONDecoder().decode(HostStorageResponse.self, from: storageResponse.body)
        XCTAssertTrue(storage.onHost)
        XCTAssertTrue(storage.onMailbox)

        _ = router.handle(
            HostHTTPRequest(
                method: "DELETE",
                path: "/v1/messages",
                query: [
                    "accountID": accountID.uuidString,
                    "mailbox": "INBOX",
                    "uid": "1"
                ]
            )
        )
        let afterDelete = router.handle(
            HostHTTPRequest(
                method: "GET",
                path: "/v1/storage",
                query: [
                    "accountID": accountID.uuidString,
                    "mailbox": "INBOX",
                    "uid": "1"
                ]
            )
        )
        let deletedStorage = try JSONDecoder().decode(
            HostStorageResponse.self,
            from: afterDelete.body
        )
        XCTAssertFalse(deletedStorage.onHost)
    }

    func testRouterHealthAndUnknownRoute() throws {
        let router = HostMailRouter(database: MailDatabase(inMemory: true))

        let health = router.handle(HostHTTPRequest(method: "GET", path: "/health"))
        XCTAssertEqual(health.status, 200)
        let decoded = try JSONDecoder().decode(HostMailHealth.self, from: health.body)
        XCTAssertEqual(decoded.status, "ok")
        XCTAssertEqual(decoded.messageCount, 0)

        let missing = router.handle(HostHTTPRequest(method: "GET", path: "/nope"))
        XCTAssertEqual(missing.status, 404)
    }

    // MARK: Storage placement

    func testStoragePlacementTitles() {
        XCTAssertEqual(
            MessageStorageStatus(onMailbox: true, onHost: true, onDevice: true).placement,
            .both
        )
        XCTAssertEqual(
            MessageStorageStatus(onMailbox: true, onHost: false, onDevice: true).placement,
            .mailbox
        )
        XCTAssertEqual(
            MessageStorageStatus(onMailbox: false, onHost: true, onDevice: true).placement,
            .host
        )
        XCTAssertEqual(
            MessageStorageStatus(onMailbox: false, onHost: false, onDevice: true).placement,
            .device
        )
        XCTAssertEqual(
            MessageStorageStatus(onMailbox: false, onHost: false, onDevice: false).placement,
            .unknown
        )
        XCTAssertEqual(
            MessageStorageStatus(onMailbox: false, onHost: true, onDevice: false).title,
            "Only on host machine"
        )
    }

    // MARK: Configuration

    func testHostConfigurationFromEnvironment() {
        let disabled = HostMailConfiguration.load(
            environment: ["MAILR_HOST_SERVER": "off"],
            candidateURLs: []
        )
        XCTAssertNil(disabled)

        let lan = HostMailConfiguration.load(
            environment: ["MAILR_HOST_SERVER": "192.168.1.20:9000"],
            candidateURLs: []
        )
        XCTAssertEqual(lan?.displayAddress, "http://192.168.1.20:9000")

        let defaulted = HostMailConfiguration.load(environment: [:], candidateURLs: [])
        XCTAssertEqual(defaulted?.baseURL, HostMailConfiguration.defaultBaseURL)
    }

    // MARK: End-to-end

    func testHTTPServerRoundTrip() async throws {
        let database = MailDatabase(inMemory: true)
        let server = HostMailServer(port: 0, database: database)
        try server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.boundPort)
        let client = HTTPHostMailStore(
            configuration: HostMailConfiguration(
                baseURL: URL(string: "http://127.0.0.1:\(port)")!
            )
        )

        let health = try await client.health()
        XCTAssertEqual(health.status, "ok")

        try await client.syncMailbox(
            accountID: accountID,
            mailbox: "INBOX",
            messages: [summary(uid: 1)],
            absentUIDs: []
        )
        try await client.storeMessage(message(uid: 1, text: "Host body"), accountID: accountID)

        let snapshot = try await client.mailboxSnapshot(
            accountID: accountID,
            mailbox: "INBOX",
            limit: 10
        )
        XCTAssertEqual(snapshot.map(\.uid), [1])

        let stored = try await client.storedMessage(
            accountID: accountID,
            mailbox: "INBOX",
            uid: 1
        )
        XCTAssertEqual(stored?.text, "Host body")

        let status = try await client.storageStatus(
            accountID: accountID,
            mailbox: "INBOX",
            uid: 1
        )
        XCTAssertEqual(status?.onHost, true)
        XCTAssertEqual(status?.onMailbox, true)
    }
}
