import XCTest
@testable import MailCore

final class ThunderbirdPrefsTests: XCTestCase {
    func testParsesStringsIntegersAndBooleans() {
        let prefs = ThunderbirdPrefs.parse(
            """
            // Mozilla User Preferences
            user_pref("mail.accountmanager.accounts", "account1,account2");
            user_pref("mail.server.server1.port", 993);
            user_pref("mail.server.server1.socketType", 3);
            user_pref("mail.identity.id1.valid", true);
            user_pref("mail.identity.id1.fullName", "Test \\"Person\\"");
            user_pref("mail.server.server1.name", "Wörk");
            """
        )

        XCTAssertEqual(prefs.string("mail.accountmanager.accounts"), "account1,account2")
        XCTAssertEqual(prefs.integer("mail.server.server1.port"), 993)
        XCTAssertEqual(prefs.integer("mail.server.server1.socketType"), 3)
        XCTAssertEqual(prefs.boolean("mail.identity.id1.valid"), true)
        XCTAssertEqual(prefs.string("mail.identity.id1.fullName"), "Test \"Person\"")
        XCTAssertEqual(prefs.string("mail.server.server1.name"), "Wörk")
    }

    func testIgnoresUnrelatedLines() {
        let prefs = ThunderbirdPrefs.parse(
            """
            # a comment
            user_pref("mail.server.server1.port", 143);
            this is not a pref
            pref("mail.server.server1.hostname", "ignored");
            """
        )

        XCTAssertEqual(prefs.integer("mail.server.server1.port"), 143)
        XCTAssertNil(prefs.string("mail.server.server1.hostname"))
    }
}

final class ThunderbirdProfilesTests: XCTestCase {
    func testDiscoversProfilesAndDefaultFromIni() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("Profiles/first.default")
        let second = root.appendingPathComponent("Profiles/second.default")
        try makeProfile(at: first)
        try makeProfile(at: second, prefs: "user_pref(\"ignored\", true);")

        try """
        [Profile0]
        Name=First
        IsRelative=1
        Path=Profiles/first.default
        Default=1

        [Profile1]
        Name=Second
        IsRelative=1
        Path=Profiles/second.default
        """.write(
            to: root.appendingPathComponent("profiles.ini"),
            atomically: true,
            encoding: .utf8
        )

        let profiles = try ThunderbirdProfiles.discover(root: root)

        XCTAssertEqual(profiles.map(\.name), ["First", "Second"])
        XCTAssertTrue(profiles[0].isDefault)
        XCTAssertEqual(profiles[0].path.standardizedFileURL, first.standardizedFileURL)
    }

    func testScansProfilesDirectoryWhenIniIsMissing() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeProfile(at: root.appendingPathComponent("Profiles/only.default"))

        let profiles = try ThunderbirdProfiles.discover(root: root)

        XCTAssertEqual(profiles.count, 1)
        XCTAssertTrue(profiles[0].isDefault)
    }

    func testTreatsProfileDirectoryAsSingleProfile() throws {
        let profile = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: profile) }
        try makeProfile(at: profile)

        let profiles = try ThunderbirdProfiles.discover(root: profile)

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].path.standardizedFileURL, profile.standardizedFileURL)
    }
}

final class ThunderbirdAccountReaderTests: XCTestCase {
    func testReadsIMAPAndSMTPSettings() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let localFolders = root.appendingPathComponent("Mail/Local Folders")
        try FileManager.default.createDirectory(at: localFolders, withIntermediateDirectories: true)

        let prefs = ThunderbirdPrefs.parse(
            """
            user_pref("mail.account.account1.identities", "id1,id2");
            user_pref("mail.account.account1.server", "server1");
            user_pref("mail.accountmanager.accounts", "account1");
            user_pref("mail.identity.id1.fullName", "Test Person");
            user_pref("mail.identity.id1.useremail", "person@fastmail.com");
            user_pref("mail.identity.id1.smtpServer", "smtp1");
            user_pref("mail.identity.id2.useremail", "alias@fastmail.com");
            user_pref("mail.server.server1.hostname", "imap.fastmail.com");
            user_pref("mail.server.server1.port", 993);
            user_pref("mail.server.server1.socketType", 3);
            user_pref("mail.server.server1.type", "imap");
            user_pref("mail.server.server1.userName", "person@fastmail.com");
            user_pref("mail.server.server1.directory-rel", "ImapMail/imap.fastmail.com");
            user_pref("mail.server.server2.hostname", "Local Folders");
            user_pref("mail.server.server2.type", "none");
            user_pref("mail.server.server2.directory", "\(localFolders.path)");
            user_pref("mail.smtpserver.smtp1.hostname", "smtp.fastmail.com");
            user_pref("mail.smtpserver.smtp1.port", 465);
            user_pref("mail.smtpserver.smtp1.socketType", 3);
            user_pref("mail.smtpserver.smtp1.username", "person@fastmail.com");
            """
        )

        let accounts = ThunderbirdAccountReader.accounts(prefs: prefs, profilePath: root)

        let account = try XCTUnwrap(accounts.first)
        XCTAssertEqual(account.emailAddress, "person@fastmail.com")
        XCTAssertEqual(account.displayName, "Test Person")
        XCTAssertEqual(account.serverType, .imap)
        XCTAssertEqual(account.incoming?.host, "imap.fastmail.com")
        XCTAssertEqual(account.incoming?.port, 993)
        XCTAssertEqual(account.incoming?.security, .tls)
        XCTAssertEqual(account.outgoing?.host, "smtp.fastmail.com")
        XCTAssertEqual(account.outgoing?.port, 465)
        XCTAssertFalse(account.incomingUsesStartTLS)
        XCTAssertEqual(account.additionalIdentities, ["alias@fastmail.com"])

        let sources = ThunderbirdAccountReader.localSources(
            prefs: prefs,
            profilePath: root,
            accounts: accounts,
            includeIMAPCache: false
        )

        XCTAssertEqual(sources.map(\.label), ["Local Folders"])
        XCTAssertEqual(sources.first?.directory.standardizedFileURL, localFolders.standardizedFileURL)
    }

    func testReadsOlderSMTPSocketKey() {
        let prefs = ThunderbirdPrefs.parse(
            """
            user_pref("mail.accountmanager.accounts", "account1");
            user_pref("mail.account.account1.identities", "id1");
            user_pref("mail.account.account1.server", "server1");
            user_pref("mail.identity.id1.useremail", "person@strato.de");
            user_pref("mail.identity.id1.smtpServer", "smtp1");
            user_pref("mail.server.server1.hostname", "imap.strato.de");
            user_pref("mail.server.server1.port", 993);
            user_pref("mail.server.server1.socketType", 3);
            user_pref("mail.server.server1.type", "imap");
            user_pref("mail.smtpserver.smtp1.hostname", "smtp.strato.de");
            user_pref("mail.smtpserver.smtp1.port", 465);
            user_pref("mail.smtpserver.smtp1.try_ssl", 3);
            """
        )

        let account = ThunderbirdAccountReader.accounts(
            prefs: prefs,
            profilePath: URL(fileURLWithPath: "/tmp/does-not-exist")
        )[0]

        XCTAssertEqual(account.outgoing?.security, .tls)
        XCTAssertFalse(account.outgoingUsesStartTLS)
    }

    func testFlagsStartTLSAndPOP3() {
        let prefs = ThunderbirdPrefs.parse(
            """
            user_pref("mail.accountmanager.accounts", "account1");
            user_pref("mail.account.account1.identities", "id1");
            user_pref("mail.account.account1.server", "server1");
            user_pref("mail.identity.id1.useremail", "person@example.com");
            user_pref("mail.server.server1.hostname", "imap.example.com");
            user_pref("mail.server.server1.port", 143);
            user_pref("mail.server.server1.socketType", 2);
            user_pref("mail.server.server1.type", "imap");
            user_pref("mail.smtpserver.smtp1.hostname", "smtp.example.com");
            user_pref("mail.smtpserver.smtp1.socketType", 2);
            """
        )

        let account = ThunderbirdAccountReader.accounts(
            prefs: prefs,
            profilePath: URL(fileURLWithPath: "/tmp/does-not-exist")
        )[0]

        XCTAssertTrue(account.incomingUsesStartTLS)
        XCTAssertTrue(account.outgoingUsesStartTLS)
        XCTAssertTrue(account.issues.contains { $0.contains("STARTTLS") })
    }
}

final class ThunderbirdMboxTests: XCTestCase {
    func testSplitsMessagesAndUnescapesFromLines() {
        let data = Data(
            """
            From alice@example.com Mon Jan  1 10:00:00 2024
            From: Alice <alice@example.com>
            Subject: First
            Date: Mon, 1 Jan 2024 10:00:00 +0000

            First body.
            >From quoted line.
            From the body.

            From bob@example.com Tue Jan  2 11:00:00 2024
            From: Bob <bob@example.com>
            Subject: Second
            Date: Tue, 2 Jan 2024 11:00:00 +0000

            Second body.
            """.utf8
        )

        let ranges = MboxReader.messageRanges(in: data)
        XCTAssertEqual(ranges.count, 2)

        let first = MboxReader.unescape(data[ranges[0]])
        let firstText = String(decoding: first, as: UTF8.self)
        XCTAssertTrue(firstText.contains("First body."))
        XCTAssertTrue(firstText.contains("From quoted line."))
        XCTAssertTrue(firstText.contains("\nFrom the body."))

        let envelope = MboxReader.envelopeDate(for: ranges[0], in: data)
        XCTAssertNotNil(envelope)
    }

    func testNonMboxDataIsTreatedAsOneMessage() {
        let data = Data("From: a@example.com\r\nSubject: Raw\r\n\r\nBody".utf8)
        let ranges = MboxReader.messageRanges(in: data)

        XCTAssertEqual(ranges.count, 1)
        let normalized = String(decoding: MboxReader.unescape(data[ranges[0]]), as: UTF8.self)
        XCTAssertEqual(normalized, "From: a@example.com\nSubject: Raw\n\nBody")
    }
}

final class ThunderbirdLocalStoreTests: XCTestCase {
    func testDiscoversNestedMboxFoldersAndMaildir() throws {
        let sourceDirectory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        try writeMessage(
            to: sourceDirectory.appendingPathComponent("Inbox"),
            subject: "Inbox message"
        )
        try Data("index".utf8).write(to: sourceDirectory.appendingPathComponent("Inbox.msf"))
        try writeMessage(
            to: sourceDirectory.appendingPathComponent("Archives.sbd/2024"),
            subject: "Archived message"
        )

        let maildir = sourceDirectory.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(
            at: maildir.appendingPathComponent("cur"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: maildir.appendingPathComponent("new"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: maildir.appendingPathComponent("tmp"),
            withIntermediateDirectories: true
        )
        try writeMessage(
            to: maildir.appendingPathComponent("cur/message.eml"),
            subject: "Maildir message"
        )

        let source = ThunderbirdLocalSource(
            label: "Local Folders",
            directory: sourceDirectory,
            serverKey: "server2",
            serverType: .local
        )
        let folders = ThunderbirdLocalStore.discoverFolders(in: source)

        XCTAssertEqual(
            folders.map(\.path),
            ["Local Folders/Archives/2024", "Local Folders/Inbox", "Local Folders/Projects"]
        )
        XCTAssertEqual(folders.first { $0.name == "Inbox" }?.role, .inbox)
        XCTAssertEqual(folders.first { $0.name == "Projects" }?.format, .maildir)

        let messages = try ThunderbirdLocalStore.messages(in: folders[1])
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(String(decoding: messages[0].data, as: UTF8.self).contains("Inbox message"))

        XCTAssertEqual(try ThunderbirdLocalStore.messageCount(in: folders[2]), 1)
    }
}

final class ThunderbirdImporterTests: XCTestCase {
    func testImportsAccountsAndLocalMail() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let profile = root.appendingPathComponent("Profiles/test.default")
        try makeProfile(at: profile, prefs: Self.prefs())
        try writeMessage(
            to: profile.appendingPathComponent("Mail/Local Folders/Inbox"),
            subject: "Hello Thunderbird",
            extraHeaders: "Message-ID: <one@example.com>\nX-Mozilla-Status: 0001\n",
            body: "Hello from Thunderbird.\n\n>From the quoting test."
        )
        try writeMessage(
            to: profile.appendingPathComponent("Mail/Local Folders/Archives.sbd/2024"),
            subject: "Archived 2024",
            extraHeaders: "Message-ID: <two@example.com>\nX-Mozilla-Status: 0005\n",
            body: "Archived message."
        )

        let database = MailDatabase(fileURL: root.appendingPathComponent("mailr.sqlite3"))
        let importer = try ThunderbirdImporter(profile: ThunderbirdProfile(
            name: "Test Profile",
            path: profile,
            isDefault: true
        ))
        let summary = try importer.importInto(database: database)

        XCTAssertEqual(summary.accountsCreated, ["person@fastmail.com"])
        XCTAssertEqual(summary.messageCount, 2)
        XCTAssertEqual(Set(summary.mailboxes), [
            "Local Folders/Inbox",
            "Local Folders/Archives/2024"
        ])

        let accounts = try database.loadAccounts()
        let server = try XCTUnwrap(accounts.first { $0.emailAddress == "person@fastmail.com" })
        XCTAssertEqual(server.provider, .fastmail)
        XCTAssertEqual(server.incoming.host, "imap.fastmail.com")
        XCTAssertEqual(server.incoming.port, 993)
        XCTAssertEqual(server.outgoing.host, "smtp.fastmail.com")

        let local = try XCTUnwrap(accounts.first { $0.provider == .local })
        XCTAssertEqual(local.displayName, "Thunderbird — Test Profile")
        XCTAssertEqual(local.emailAddress, "test.default@mailr.local")

        let boxes = try database.loadMailboxes(accountID: local.id)
        XCTAssertEqual(Set(boxes.map(\.path)), [
            "Local Folders/Inbox",
            "Local Folders/Archives/2024"
        ])

        let messages = try database.loadMessages(
            accountID: local.id,
            mailbox: "Local Folders/Inbox"
        )
        let message = try XCTUnwrap(messages.first)
        XCTAssertEqual(message.subject, "Hello Thunderbird")
        XCTAssertTrue(message.isRead)
        XCTAssertFalse(message.isOnMailbox)

        let full = try XCTUnwrap(database.loadMessage(
            accountID: local.id,
            mailbox: "Local Folders/Inbox",
            uid: message.uid
        ))
        XCTAssertTrue(full.text?.contains("Hello from Thunderbird.") == true)
        XCTAssertTrue(full.text?.contains("\nFrom the quoting test.") == true)

        let archived = try database.loadMessages(
            accountID: local.id,
            mailbox: "Local Folders/Archives/2024"
        )
        XCTAssertEqual(archived.first?.isFlagged, true)
    }

    func testRepeatImportIsIdempotent() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let profile = root.appendingPathComponent("Profiles/test.default")
        try makeProfile(at: profile, prefs: Self.prefs())
        try writeMessage(
            to: profile.appendingPathComponent("Mail/Local Folders/Inbox"),
            subject: "Hello",
            extraHeaders: "Message-ID: <one@example.com>\n"
        )

        let database = MailDatabase(fileURL: root.appendingPathComponent("mailr.sqlite3"))
        let importer = try ThunderbirdImporter(profile: ThunderbirdProfile(
            name: "Test Profile",
            path: profile
        ))

        let first = try importer.importInto(database: database)
        let second = try importer.importInto(database: database)

        XCTAssertEqual(first.messageCount, 1)
        XCTAssertEqual(second.messageCount, 1)
        XCTAssertTrue(second.accountsSkipped.contains { $0.contains("already exists") })
        XCTAssertEqual(try database.loadAccounts().count, 2)

        let local = try XCTUnwrap(try database.loadAccounts().first { $0.provider == .local })
        XCTAssertEqual(
            try database.loadMessages(accountID: local.id, mailbox: "Local Folders/Inbox").count,
            1
        )
    }

    func testStartTLSCustomAccountIsSkippedButLocalMailIsImported() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let profile = root.appendingPathComponent("Profiles/test.default")
        try makeProfile(at: profile, prefs: """
        user_pref("mail.accountmanager.accounts", "account1");
        user_pref("mail.account.account1.identities", "id1");
        user_pref("mail.account.account1.server", "server1");
        user_pref("mail.identity.id1.useremail", "person@example.com");
        user_pref("mail.server.server1.hostname", "imap.example.com");
        user_pref("mail.server.server1.port", 143);
        user_pref("mail.server.server1.socketType", 2);
        user_pref("mail.server.server1.type", "imap");
        user_pref("mail.server.server2.hostname", "Local Folders");
        user_pref("mail.server.server2.type", "none");
        """)
        try writeMessage(
            to: profile.appendingPathComponent("Mail/Local Folders/Inbox"),
            subject: "Still imported"
        )

        let database = MailDatabase(fileURL: root.appendingPathComponent("mailr.sqlite3"))
        let summary = try ThunderbirdImporter(profile: ThunderbirdProfile(name: "Test", path: profile))
            .importInto(database: database)

        XCTAssertTrue(summary.accountsCreated.isEmpty)
        XCTAssertTrue(summary.accountsSkipped.contains { $0.contains("STARTTLS") })
        XCTAssertEqual(summary.messageCount, 1)
        XCTAssertNotNil(summary.localAccountName)
    }

    func testDryRunWritesNothing() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let profile = root.appendingPathComponent("Profiles/test.default")
        try makeProfile(at: profile, prefs: Self.prefs())
        try writeMessage(to: profile.appendingPathComponent("Mail/Local Folders/Inbox"), subject: "Hello")

        let database = MailDatabase(fileURL: root.appendingPathComponent("mailr.sqlite3"))
        let importer = try ThunderbirdImporter(profile: ThunderbirdProfile(name: "Test", path: profile))
        let summary = try importer.importInto(
            database: database,
            options: ThunderbirdImportOptions(dryRun: true)
        )

        XCTAssertEqual(summary.messageCount, 1)
        XCTAssertEqual(try database.loadAccounts(), [])
    }

    func testLocalMailServiceServesImportedMessages() async throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let profile = root.appendingPathComponent("Profiles/test.default")
        try makeProfile(at: profile, prefs: Self.prefs())
        try writeMessage(
            to: profile.appendingPathComponent("Mail/Local Folders/Inbox"),
            subject: "Served locally",
            extraHeaders: "Message-ID: <served@example.com>\n"
        )

        let database = MailDatabase(fileURL: root.appendingPathComponent("mailr.sqlite3"))
        _ = try ThunderbirdImporter(profile: ThunderbirdProfile(name: "Test", path: profile))
            .importInto(database: database)

        let local = try XCTUnwrap(try database.loadAccounts().first { $0.provider == .local })
        let service = LocalMailService(database: database, accountID: local.id)

        let boxes = try await service.listMailboxes()
        XCTAssertEqual(boxes.map(\.path), ["Local Folders/Inbox"])
        XCTAssertEqual(boxes[0].totalCount, 1)

        let messages = try await service.fetchMessages(mailbox: "Local Folders/Inbox", limit: 10)
        let message = try XCTUnwrap(messages.first)
        let full = try await service.fetchMessage(
            mailbox: "Local Folders/Inbox",
            uid: message.uid
        )
        XCTAssertEqual(full.summary.subject, "Served locally")
        XCTAssertTrue(full.text?.contains("Body for Served locally") == true)
    }

    // MARK: Fixtures

    private static func prefs() -> String {
        """
        user_pref("mail.account.account1.identities", "id1");
        user_pref("mail.account.account1.server", "server1");
        user_pref("mail.accountmanager.accounts", "account1");
        user_pref("mail.accountmanager.defaultaccount", "account1");
        user_pref("mail.identity.id1.fullName", "Test Person");
        user_pref("mail.identity.id1.useremail", "person@fastmail.com");
        user_pref("mail.identity.id1.smtpServer", "smtp1");
        user_pref("mail.server.server1.hostname", "imap.fastmail.com");
        user_pref("mail.server.server1.port", 993);
        user_pref("mail.server.server1.socketType", 3);
        user_pref("mail.server.server1.type", "imap");
        user_pref("mail.server.server1.userName", "person@fastmail.com");
        user_pref("mail.server.server2.hostname", "Local Folders");
        user_pref("mail.server.server2.type", "none");
        user_pref("mail.smtpserver.smtp1.hostname", "smtp.fastmail.com");
        user_pref("mail.smtpserver.smtp1.port", 465);
        user_pref("mail.smtpserver.smtp1.socketType", 3);
        user_pref("mail.smtpserver.smtp1.username", "person@fastmail.com");
        """
    }
}

// MARK: - Helpers

private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MailrThunderbirdTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeProfile(at url: URL, prefs: String = "user_pref(\"test\", true);") throws {
    try FileManager.default.createDirectory(
        at: url.appendingPathComponent("Mail/Local Folders"),
        withIntermediateDirectories: true
    )
    try prefs.write(
        to: url.appendingPathComponent("prefs.js"),
        atomically: true,
        encoding: .utf8
    )
}

private func writeMessage(
    to url: URL,
    subject: String,
    extraHeaders: String = "",
    body: String? = nil
) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let bodyText = body ?? "Body for \(subject)"
    let message = """
    From sender@example.com Mon Jan  1 10:00:00 2024
    From: Sender <sender@example.com>
    To: person@fastmail.com
    Subject: \(subject)
    Date: Mon, 1 Jan 2024 10:00:00 +0000
    \(extraHeaders)Content-Type: text/plain; charset=utf-8

    \(bodyText)
    """
    try Data(message.utf8).write(to: url)
}
