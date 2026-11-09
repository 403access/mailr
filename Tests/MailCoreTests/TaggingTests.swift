import XCTest
@testable import MailCore

final class TaggingTests: XCTestCase {
    private let accountID = UUID()

    private func summary(uid: UInt32 = 1, subject: String = "Invoice", snippet: String = "") -> MessageSummary {
        MessageSummary(
            uid: uid,
            mailbox: "INBOX",
            subject: subject,
            from: [EmailAddress(address: "billing@example.com", name: "Billing")],
            to: [EmailAddress(address: "me@example.com")],
            date: Date(timeIntervalSince1970: 1_700_000_000),
            snippet: snippet,
            size: 100,
            isOnMailbox: true
        )
    }

    private func message(subject: String, text: String) -> MailMessage {
        MailMessage(summary: summary(uid: 1, subject: subject), text: text)
    }

    // MARK: Database

    func testDefaultTagsAreSeededOnce() throws {
        let database = MailDatabase(inMemory: true)
        let tags = try database.loadTags()
        XCTAssertEqual(tags.count, MailTag.defaults.count)
        XCTAssertEqual(Set(tags.map(\.id)), Set(MailTag.defaults.map(\.id)))

        try database.deleteTag(id: tags[0].id)
        XCTAssertEqual(try database.loadTags().count, tags.count - 1)
    }

    func testAutomaticAndManualTagsRoundTrip() throws {
        let database = MailDatabase(inMemory: true)
        let tags = try database.loadTags()
        let receipt = tags.first { $0.name == "Receipt/Invoice" }!
        let work = tags.first { $0.name == "Work" }!

        try database.saveClassification(
            [MailTagClassification(tagID: receipt.id, confidence: 0.8)],
            accountID: accountID,
            mailbox: "INBOX",
            uid: 1,
            classifier: "keywords"
        )

        var tagged = try database.loadTaggedMessages(
            accountID: accountID,
            mailbox: "INBOX",
            uids: [1]
        )
        XCTAssertEqual(tagged.first?.tags.map(\.tagID), [receipt.id])
        XCTAssertEqual(tagged.first?.tags.first?.source, .automatic)

        try database.setMessageTag(
            accountID: accountID,
            mailbox: "INBOX",
            uid: 1,
            tagID: work.id,
            tagged: true
        )
        tagged = try database.loadTaggedMessages(accountID: accountID, mailbox: "INBOX", uids: [1])
        XCTAssertEqual(Set(tagged.first?.tags.map(\.tagID) ?? []), [receipt.id, work.id])
    }

    func testManualRemovalSurvivesReclassification() throws {
        let database = MailDatabase(inMemory: true)
        let receipt = try database.loadTags().first { $0.name == "Receipt/Invoice" }!

        try database.saveClassification(
            [MailTagClassification(tagID: receipt.id, confidence: 0.9)],
            accountID: accountID,
            mailbox: "INBOX",
            uid: 1,
            classifier: "keywords"
        )
        try database.setMessageTag(
            accountID: accountID,
            mailbox: "INBOX",
            uid: 1,
            tagID: receipt.id,
            tagged: false
        )
        try database.saveClassification(
            [MailTagClassification(tagID: receipt.id, confidence: 0.9)],
            accountID: accountID,
            mailbox: "INBOX",
            uid: 1,
            classifier: "keywords"
        )

        let tagged = try database.loadTaggedMessages(
            accountID: accountID,
            mailbox: "INBOX",
            uids: [1]
        )
        XCTAssertTrue(tagged.isEmpty)
    }

    func testClassificationStatePreventsRepeatWork() throws {
        let database = MailDatabase(inMemory: true)
        let tag = try database.loadTags()[0]

        XCTAssertEqual(
            try database.unclassifiedUIDs(accountID: accountID, mailbox: "INBOX", uids: [1, 2]),
            [1, 2]
        )

        try database.saveClassification(
            [MailTagClassification(tagID: tag.id, confidence: 0.8)],
            accountID: accountID,
            mailbox: "INBOX",
            uid: 1,
            classifier: "keywords"
        )

        XCTAssertEqual(
            try database.unclassifiedUIDs(accountID: accountID, mailbox: "INBOX", uids: [1, 2]),
            [2]
        )
        XCTAssertEqual(
            try database.unclassifiedUIDs(
                accountID: accountID,
                mailbox: "INBOX",
                uids: [1, 2],
                force: true
            ),
            [1, 2]
        )
    }

    func testMovingAndDeletingMessagesMovesTheirTags() throws {
        let database = MailDatabase(inMemory: true)
        let tag = try database.loadTags()[0]
        try database.saveMessage(
            MailMessage(summary: summary(uid: 7)),
            accountID: accountID
        )
        try database.setMessageTag(
            accountID: accountID,
            mailbox: "INBOX",
            uid: 7,
            tagID: tag.id,
            tagged: true
        )

        try database.moveMessage(
            accountID: accountID,
            from: "INBOX",
            uid: 7,
            to: "Archive"
        )
        XCTAssertEqual(
            try database.loadTaggedMessages(accountID: accountID, mailbox: "Archive", uids: [7]).count,
            1
        )

        try database.deleteMessage(accountID: accountID, mailbox: "Archive", uid: 7)
        XCTAssertTrue(
            try database.loadTaggedMessages(accountID: accountID, mailbox: "Archive", uids: [7]).isEmpty
        )
    }

    // MARK: Router

    func testTagRoutesRoundTrip() throws {
        let database = MailDatabase(inMemory: true)
        let router = HostMailRouter(database: database)

        let listResponse = router.handle(HostHTTPRequest(method: "GET", path: "/v1/tags"))
        XCTAssertEqual(listResponse.status, 200)
        let initial = try JSONDecoder().decode([MailTag].self, from: listResponse.body)
        XCTAssertEqual(initial.count, MailTag.defaults.count)

        var tag = initial[0]
        tag.name = "Needs Attention"
        let saveBody = try JSONEncoder().encode(HostTagRequest(tag: tag))
        let saveResponse = router.handle(
            HostHTTPRequest(method: "POST", path: "/v1/tags", body: saveBody)
        )
        XCTAssertEqual(saveResponse.status, 200)

        let messageTagBody = try JSONEncoder().encode(HostMessageTagRequest(
            accountID: accountID,
            mailbox: "INBOX",
            uid: 9,
            tagID: tag.id,
            tagged: true
        ))
        let assignResponse = router.handle(
            HostHTTPRequest(method: "POST", path: "/v1/messages/tags", body: messageTagBody)
        )
        XCTAssertEqual(assignResponse.status, 200)

        let taggedResponse = router.handle(HostHTTPRequest(
            method: "GET",
            path: "/v1/messages/tags",
            query: [
                "accountID": accountID.uuidString,
                "mailbox": "INBOX",
                "uids": "9"
            ]
        ))
        XCTAssertEqual(taggedResponse.status, 200)
        let tagged = try JSONDecoder().decode(
            HostTaggedMessagesResponse.self,
            from: taggedResponse.body
        )
        XCTAssertEqual(tagged.messages.first?.tags.first?.tagID, tag.id)

        let deleteResponse = router.handle(HostHTTPRequest(
            method: "DELETE",
            path: "/v1/tags",
            query: ["id": tag.id.uuidString]
        ))
        XCTAssertEqual(deleteResponse.status, 200)
        let remaining = try JSONDecoder().decode([MailTag].self, from: deleteResponse.body)
        XCTAssertFalse(remaining.contains { $0.id == tag.id })
    }

    // MARK: Classifier

    func testParserAcceptsIDsNamesAndConfidenceCutoff() throws {
        let tags = MailTag.defaults
        let work = tags.first { $0.name == "Work" }!
        let receipt = tags.first { $0.name == "Receipt/Invoice" }!

        let byID = """
        {"tags":[{"id":"\(work.id.uuidString)","confidence":0.91}]}
        """
        let parsedByID = EmailTagClassifier.parse(
            response: byID,
            tags: tags,
            configuration: TaggingConfiguration()
        )
        XCTAssertEqual(parsedByID?.first?.tagID, work.id)

        let byName = """
        ```json
        {"tags":[{"name":"Receipt/Invoice","confidence":0.7}]}
        ```
        """
        let parsedByName = EmailTagClassifier.parse(
            response: byName,
            tags: tags,
            configuration: TaggingConfiguration()
        )
        XCTAssertEqual(parsedByName?.first?.tagID, receipt.id)

        let low = """
        {"tags":[{"id":"\(work.id.uuidString)","confidence":0.1}]}
        """
        XCTAssertEqual(
            EmailTagClassifier.parse(
                response: low,
                tags: tags,
                configuration: TaggingConfiguration()
            ),
            []
        )

        // Small models are much better at copying short aliases than UUIDs.
        let byAlias = """
        {"tags":[{"id":"T2","confidence":0.9},{"id":"T6","confidence":0.01}]}
        """
        let parsedByAlias = EmailTagClassifier.parse(
            response: byAlias,
            tags: tags,
            configuration: TaggingConfiguration()
        )
        XCTAssertEqual(parsedByAlias?.map(\.tagID), [tags[1].id])

        let singleObject = #"{"id":"T3","confidence":0.8}"#
        XCTAssertEqual(
            EmailTagClassifier.parse(
                response: singleObject,
                tags: tags,
                configuration: TaggingConfiguration()
            )?.first?.tagID,
            tags[2].id
        )
    }

    func testKeywordFallbackMatchesInvoiceMail() {
        let tags = MailTag.defaults
        let invoice = message(
            subject: "Your invoice is ready",
            text: "Thanks for your order. The total is $42 and your receipt is attached."
        )
        let results = EmailTagClassifier.keywordClassifications(
            for: invoice,
            tags: tags,
            configuration: TaggingConfiguration()
        )
        XCTAssertTrue(results.contains { result in
            tags.first { $0.id == result.tagID }?.name == "Receipt/Invoice"
        })
    }

    func testConfigurationReadsEnvironmentOverrides() {
        let configuration = TaggingConfiguration.load(environment: [
            "MAILR_CLASSIFY": "off",
            "MAILR_OLLAMA_URL": "http://127.0.0.1:11435",
            "MAILR_OLLAMA_MODEL": "small-model",
            "MAILR_TAG_CONFIDENCE": "0.6",
            "MAILR_TAG_MAX": "3"
        ])
        XCTAssertFalse(configuration.enabled)
        XCTAssertEqual(configuration.baseURL.absoluteString, "http://127.0.0.1:11435")
        XCTAssertEqual(configuration.model, "small-model")
        XCTAssertEqual(configuration.minimumConfidence, 0.6)
        XCTAssertEqual(configuration.maximumTags, 3)
    }
}
