import XCTest
@testable import MailCore

final class DotEnvTests: XCTestCase {
    func testParsesCommonDotEnvSyntax() {
        let env = DotEnv.parse(
            """
            # A comment
            export SIMPLE=value
            QUOTED="hello world"
            SINGLE='literal $VALUE'
            HASH=value#not-comment
            COMMENTED=value # trailing comment
            EMPTY=
            SPACED = padded value
            ESCAPED="line1\\nline2"
            QUOTED_COMMENT="value" # trailing comment
            EQUALS=a=b=c
            this is not an assignment

            """
        )

        XCTAssertEqual(env["SIMPLE"], "value")
        XCTAssertEqual(env["QUOTED"], "hello world")
        XCTAssertEqual(env["SINGLE"], "literal $VALUE")
        XCTAssertEqual(env["HASH"], "value#not-comment")
        XCTAssertEqual(env["COMMENTED"], "value")
        XCTAssertEqual(env["EMPTY"], "")
        XCTAssertEqual(env["SPACED"], "padded value")
        XCTAssertEqual(env["ESCAPED"], "line1\nline2")
        XCTAssertEqual(env["QUOTED_COMMENT"], "value")
        XCTAssertEqual(env["EQUALS"], "a=b=c")
        XCTAssertNil(env["THIS IS NOT AN ASSIGNMENT"])
    }

    func testHandlesCRLFAndUnicode() {
        let env = DotEnv.parse("GREETING=\"héllo\"\r\nCITY=Zürich\r\n")

        XCTAssertEqual(env["GREETING"], "héllo")
        XCTAssertEqual(env["CITY"], "Zürich")
    }

    func testProcessValuesOverrideFileValues() {
        let file = DotEnv.parse("A=file\nB=file\n")
        let merged = file.merging(overrides: ["B": "process", "C": "process"])

        XCTAssertEqual(merged["A"], "file")
        XCTAssertEqual(merged["B"], "process")
        XCTAssertEqual(merged["C"], "process")
    }

    func testLoadsFirstExistingFile() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("missing.env")
        let present = directory.appendingPathComponent("present.env")
        try "MAILR_ACCOUNT_TEST_EMAIL=test@example.com\n".write(
            to: present,
            atomically: true,
            encoding: .utf8
        )

        let loaded = try XCTUnwrap(DotEnv.loadFirst(at: [missing, present]))

        XCTAssertEqual(loaded.url, present)
        XCTAssertEqual(loaded.dotEnv["MAILR_ACCOUNT_TEST_EMAIL"], "test@example.com")
    }

    func testLoadFirstReturnsNilWhenNoFileExists() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(try DotEnv.loadFirst(at: [directory.appendingPathComponent(".env")]))
    }

    func testShippedExampleIsValidAndDefinesNoAccounts() throws {
        // Tests/MailCoreTests -> repository root.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let example = root.appendingPathComponent(".env.example")

        let env = try DotEnv.load(at: example)

        XCTAssertEqual(try EnvironmentAccounts.accounts(from: env.values), [])
    }
}

final class EnvironmentAccountsTests: XCTestCase {
    func testImportsKnownProviderFromEmailAndPasswordOnly() throws {
        let entries = try EnvironmentAccounts.accounts(from: [
            "MAILR_ACCOUNT_WORK_EMAIL": "person@gmail.com",
            "MAILR_ACCOUNT_WORK_PASSWORD": "super-secret"
        ])

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entry.account.emailAddress, "person@gmail.com")
        XCTAssertEqual(entry.account.displayName, "person")
        XCTAssertEqual(entry.account.provider, .gmail)
        XCTAssertFalse(entry.account.isDemo)
        XCTAssertEqual(
            entry.account.incoming,
            ServerSettings(host: "imap.gmail.com", port: 993, security: .tls, username: "person@gmail.com")
        )
        XCTAssertEqual(
            entry.account.outgoing,
            ServerSettings(host: "smtp.gmail.com", port: 465, security: .tls, username: "person@gmail.com")
        )
        XCTAssertEqual(entry.password, "super-secret")
    }

    func testInfersAllSupportedProviderDomains() throws {
        let domains: [(String, ProviderKind)] = [
            ("me@icloud.com", .icloud),
            ("me@me.com", .icloud),
            ("me@gmail.com", .gmail),
            ("me@googlemail.com", .gmail),
            ("me@yahoo.com", .yahoo),
            ("me@fastmail.com", .fastmail),
            ("me@zoho.com", .zoho)
        ]

        for (index, item) in domains.enumerated() {
            let entries = try EnvironmentAccounts.accounts(from: [
                "MAILR_ACCOUNT_\(index)_EMAIL": item.0,
                "MAILR_ACCOUNT_\(index)_PASSWORD": "secret"
            ])
            XCTAssertEqual(entries.first?.account.provider, item.1, "Failed for \(item.0)")
        }
    }

    func testCustomProviderOverridesEveryServerField() throws {
        let entries = try EnvironmentAccounts.accounts(from: [
            "MAILR_ACCOUNT_LOCAL_EMAIL": "me@example.com",
            "MAILR_ACCOUNT_LOCAL_PASSWORD": "secret",
            "MAILR_ACCOUNT_LOCAL_NAME": "Local Mail",
            "MAILR_ACCOUNT_LOCAL_PROVIDER": "custom",
            "MAILR_ACCOUNT_LOCAL_IMAP_HOST": "imap.example.com",
            "MAILR_ACCOUNT_LOCAL_IMAP_PORT": "1993",
            "MAILR_ACCOUNT_LOCAL_IMAP_SECURITY": "plaintext",
            "MAILR_ACCOUNT_LOCAL_IMAP_USERNAME": "imap-user",
            "MAILR_ACCOUNT_LOCAL_SMTP_HOST": "smtp.example.com",
            "MAILR_ACCOUNT_LOCAL_SMTP_PORT": "1465",
            "MAILR_ACCOUNT_LOCAL_SMTP_SECURITY": "tls",
            "MAILR_ACCOUNT_LOCAL_SMTP_USERNAME": "smtp-user"
        ])

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.account.displayName, "Local Mail")
        XCTAssertEqual(entry.account.provider, .custom)
        XCTAssertEqual(
            entry.account.incoming,
            ServerSettings(host: "imap.example.com", port: 1993, security: .plaintext, username: "imap-user")
        )
        XCTAssertEqual(
            entry.account.outgoing,
            ServerSettings(host: "smtp.example.com", port: 1465, security: .tls, username: "smtp-user")
        )
    }

    func testExplicitIdentifierIsUsed() throws {
        let id = UUID()
        let entries = try EnvironmentAccounts.accounts(from: [
            "MAILR_ACCOUNT_WORK_EMAIL": "person@gmail.com",
            "MAILR_ACCOUNT_WORK_PASSWORD": "secret",
            "MAILR_ACCOUNT_WORK_ID": id.uuidString
        ])

        XCTAssertEqual(entries.first?.account.id, id)
    }

    func testGeneratedIdentifiersAreStableAndUnique() throws {
        let values = [
            "MAILR_ACCOUNT_WORK_EMAIL": "person@gmail.com",
            "MAILR_ACCOUNT_WORK_PASSWORD": "secret",
            "MAILR_ACCOUNT_HOME_EMAIL": "other@fastmail.com",
            "MAILR_ACCOUNT_HOME_PASSWORD": "secret"
        ]

        let first = try EnvironmentAccounts.accounts(from: values).map(\.account.id)
        let second = try EnvironmentAccounts.accounts(from: values).map(\.account.id)

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first).count, 2)
    }

    func testAccountsAreOrderedByPrefix() throws {
        let entries = try EnvironmentAccounts.accounts(from: [
            "MAILR_ACCOUNT_ZULU_EMAIL": "zulu@gmail.com",
            "MAILR_ACCOUNT_ZULU_PASSWORD": "secret",
            "MAILR_ACCOUNT_ALPHA_EMAIL": "alpha@gmail.com",
            "MAILR_ACCOUNT_ALPHA_PASSWORD": "secret"
        ])

        XCTAssertEqual(entries.map(\.account.emailAddress), ["alpha@gmail.com", "zulu@gmail.com"])
    }

    func testPasswordIsNeverPartOfAccountMetadata() throws {
        let entries = try EnvironmentAccounts.accounts(from: [
            "MAILR_ACCOUNT_WORK_EMAIL": "person@gmail.com",
            "MAILR_ACCOUNT_WORK_PASSWORD": "super-secret"
        ])

        let account = try XCTUnwrap(entries.first?.account)
        let encoded = try String(data: JSONEncoder().encode(account), encoding: .utf8) ?? ""

        XCTAssertFalse(encoded.contains("super-secret"))
        XCTAssertFalse(encoded.contains("MAILR_ACCOUNT_"))
    }

    func testMissingEmailThrows() {
        assertThrows(
            .missingValue("MAILR_ACCOUNT_WORK_EMAIL"),
            values: ["MAILR_ACCOUNT_WORK_PASSWORD": "secret"]
        )
    }

    func testUnknownAccountVariableThrows() {
        assertThrows(
            .unknownVariable("MAILR_ACCOUNT_WORK_PASSSWORD"),
            values: [
                "MAILR_ACCOUNT_WORK_EMAIL": "person@gmail.com",
                "MAILR_ACCOUNT_WORK_PASSSWORD": "secret"
            ]
        )
    }

    func testInvalidProviderThrows() {
        assertThrows(
            .invalidProvider("outlook", variable: "MAILR_ACCOUNT_WORK_PROVIDER"),
            values: [
                "MAILR_ACCOUNT_WORK_EMAIL": "person@example.com",
                "MAILR_ACCOUNT_WORK_PROVIDER": "outlook"
            ]
        )
    }

    func testInvalidPortThrows() {
        assertThrows(
            .invalidPort("70000", variable: "MAILR_ACCOUNT_WORK_IMAP_PORT"),
            values: [
                "MAILR_ACCOUNT_WORK_EMAIL": "person@example.com",
                "MAILR_ACCOUNT_WORK_PROVIDER": "custom",
                "MAILR_ACCOUNT_WORK_IMAP_HOST": "imap.example.com",
                "MAILR_ACCOUNT_WORK_IMAP_PORT": "70000",
                "MAILR_ACCOUNT_WORK_SMTP_HOST": "smtp.example.com"
            ]
        )
    }

    func testInvalidSecurityThrows() {
        assertThrows(
            .invalidSecurity("starttls", variable: "MAILR_ACCOUNT_WORK_SMTP_SECURITY"),
            values: [
                "MAILR_ACCOUNT_WORK_EMAIL": "person@example.com",
                "MAILR_ACCOUNT_WORK_PROVIDER": "custom",
                "MAILR_ACCOUNT_WORK_IMAP_HOST": "imap.example.com",
                "MAILR_ACCOUNT_WORK_SMTP_HOST": "smtp.example.com",
                "MAILR_ACCOUNT_WORK_SMTP_SECURITY": "starttls"
            ]
        )
    }

    func testCustomProviderWithoutServerHostsThrows() {
        assertThrows(
            .missingServer("IMAP", variable: "MAILR_ACCOUNT_WORK_IMAP_HOST"),
            values: [
                "MAILR_ACCOUNT_WORK_EMAIL": "person@example.com",
                "MAILR_ACCOUNT_WORK_PROVIDER": "custom",
                "MAILR_ACCOUNT_WORK_SMTP_HOST": "smtp.example.com"
            ]
        )
    }

    func testInvalidIdentifierThrows() {
        assertThrows(
            .invalidIdentifier("not-a-uuid", variable: "MAILR_ACCOUNT_WORK_ID"),
            values: [
                "MAILR_ACCOUNT_WORK_EMAIL": "person@gmail.com",
                "MAILR_ACCOUNT_WORK_ID": "not-a-uuid"
            ]
        )
    }

    func testDuplicateEmailsThrow() {
        assertThrows(
            .duplicateAccount("person@gmail.com"),
            values: [
                "MAILR_ACCOUNT_ONE_EMAIL": "person@gmail.com",
                "MAILR_ACCOUNT_ONE_PASSWORD": "secret",
                "MAILR_ACCOUNT_TWO_EMAIL": "PERSON@gmail.com",
                "MAILR_ACCOUNT_TWO_PASSWORD": "secret"
            ]
        )
    }

    func testLoadReadsCandidateFile() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent(".env")
        try """
        MAILR_ACCOUNT_WORK_EMAIL=person@gmail.com
        MAILR_ACCOUNT_WORK_PASSWORD=file-secret
        """.write(to: file, atomically: true, encoding: .utf8)

        let entries = try EnvironmentAccounts.load(environment: [:], candidateURLs: [file])

        XCTAssertEqual(entries.first?.account.emailAddress, "person@gmail.com")
        XCTAssertEqual(entries.first?.password, "file-secret")
    }

    func testLoadLetsProcessEnvironmentOverrideFile() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent(".env")
        try """
        MAILR_ACCOUNT_WORK_EMAIL=person@gmail.com
        MAILR_ACCOUNT_WORK_PASSWORD=file-secret
        """.write(to: file, atomically: true, encoding: .utf8)

        let entries = try EnvironmentAccounts.load(
            environment: ["MAILR_ACCOUNT_WORK_PASSWORD": "process-secret"],
            candidateURLs: [file]
        )

        XCTAssertEqual(entries.first?.password, "process-secret")
    }

    func testLoadWithoutFilesReturnsEmptyList() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(
            try EnvironmentAccounts.load(environment: [:], candidateURLs: [directory.appendingPathComponent(".env")]),
            []
        )
    }

    func testLoadUsesProcessEnvironmentWithoutAFile() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let entries = try EnvironmentAccounts.load(
            environment: [
                "MAILR_ACCOUNT_WORK_EMAIL": "person@gmail.com",
                "MAILR_ACCOUNT_WORK_PASSWORD": "process-secret"
            ],
            candidateURLs: [directory.appendingPathComponent("missing.env")]
        )

        XCTAssertEqual(entries.first?.account.emailAddress, "person@gmail.com")
        XCTAssertEqual(entries.first?.password, "process-secret")
    }

    func testExplicitEnvFileWinsOverCandidateFiles() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let candidate = directory.appendingPathComponent("candidate.env")
        let explicit = directory.appendingPathComponent("explicit.env")
        try """
        MAILR_ACCOUNT_WORK_EMAIL=candidate@gmail.com
        MAILR_ACCOUNT_WORK_PASSWORD=secret
        """.write(to: candidate, atomically: true, encoding: .utf8)
        try """
        MAILR_ACCOUNT_WORK_EMAIL=explicit@gmail.com
        MAILR_ACCOUNT_WORK_PASSWORD=secret
        """.write(to: explicit, atomically: true, encoding: .utf8)

        let entries = try EnvironmentAccounts.load(
            environment: ["MAILR_ENV_FILE": explicit.path],
            candidateURLs: [candidate]
        )

        XCTAssertEqual(entries.first?.account.emailAddress, "explicit@gmail.com")
    }

    func testDefaultCandidateURLsUseExpectedOrder() {
        let root = URL(fileURLWithPath: "/tmp/mailr-environment-test")
        let urls = EnvironmentAccounts.defaultCandidateURLs(
            currentDirectory: root,
            bundleResourceURL: root.appendingPathComponent("Mailr.app/Contents/Resources"),
            applicationSupportDirectory: root.appendingPathComponent("Support"),
            homeDirectory: root.appendingPathComponent("home")
        )

        XCTAssertEqual(urls.map(\.path), [
            "/tmp/mailr-environment-test/.env",
            "/tmp/mailr-environment-test/Mailr.app/Contents/Resources/Mailr.env",
            "/tmp/mailr-environment-test/Support/Mailr/.env",
            "/tmp/mailr-environment-test/home/.config/mailr/.env"
        ])
    }

    func testLoadWithMissingExplicitFileThrows() {
        XCTAssertThrowsError(
            try EnvironmentAccounts.load(
                environment: ["MAILR_ENV_FILE": "/definitely/not/here/.env"],
                candidateURLs: []
            )
        ) { error in
            XCTAssertEqual(
                error as? EnvironmentConfigurationError,
                .missingFile("/definitely/not/here/.env")
            )
        }
    }

    func testLoadedPasswordCanBeStoredUnderTheMergedAccountIdentifier() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent(".env")
        try """
        MAILR_ACCOUNT_WORK_EMAIL=person@gmail.com
        MAILR_ACCOUNT_WORK_PASSWORD=file-secret
        """.write(to: file, atomically: true, encoding: .utf8)

        let entries = try EnvironmentAccounts.load(environment: [:], candidateURLs: [file])
        let existingID = UUID()
        let existing = MailAccount(
            id: existingID,
            displayName: "Existing",
            emailAddress: "person@gmail.com",
            provider: .gmail,
            incoming: ServerSettings(host: "imap.gmail.com", port: 993, security: .tls, username: "person@gmail.com"),
            outgoing: ServerSettings(host: "smtp.gmail.com", port: 465, security: .tls, username: "person@gmail.com")
        )

        let merged = EnvironmentAccounts.merge(entries, into: [existing])
        let accountID = try XCTUnwrap(merged.first?.id)
        let password = try XCTUnwrap(entries.first?.password)

        let credentials = InMemoryCredentialStore()
        try credentials.setPassword(password, for: accountID)

        XCTAssertEqual(accountID, existingID)
        XCTAssertEqual(try credentials.password(for: accountID), "file-secret")
    }
}

final class EnvironmentAccountsMergeTests: XCTestCase {

    func testMergeAppendsNewAccounts() throws {
        let existing = makeAccount(email: "existing@gmail.com")
        let entry = try makeEntry(email: "new@gmail.com")

        let merged = EnvironmentAccounts.merge([entry], into: [existing])

        XCTAssertEqual(merged.map(\.emailAddress), ["existing@gmail.com", "new@gmail.com"])
    }

    func testMergeUpdatesMatchingEmailAndKeepsExistingIdentifier() throws {
        let existingID = UUID()
        let existing = MailAccount(
            id: existingID,
            displayName: "Old Name",
            emailAddress: "person@gmail.com",
            provider: .gmail,
            incoming: ServerSettings(host: "old.example.com", port: 993, security: .tls, username: "person"),
            outgoing: ServerSettings(host: "old.example.com", port: 465, security: .tls, username: "person")
        )
        let entry = try makeEntry(email: "PERSON@gmail.com", name: "New Name")

        let merged = EnvironmentAccounts.merge([entry], into: [existing])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, existingID)
        XCTAssertEqual(merged[0].displayName, "New Name")
        XCTAssertEqual(merged[0].incoming.host, "imap.gmail.com")
    }

    func testMergeLeavesUnrelatedAccountsUntouched() throws {
        let existing = makeAccount(email: "existing@gmail.com")
        let entry = try makeEntry(email: "new@gmail.com")

        let merged = EnvironmentAccounts.merge([entry], into: [existing])

        XCTAssertEqual(merged.first, existing)
    }

    func testMergeIsIdempotent() throws {
        let entry = try makeEntry(email: "person@gmail.com")

        let once = EnvironmentAccounts.merge([entry], into: [])
        let twice = EnvironmentAccounts.merge([entry], into: once)

        XCTAssertEqual(once, twice)
    }

    private func makeAccount(email: String) -> MailAccount {
        MailAccount(
            displayName: "Existing",
            emailAddress: email,
            provider: .custom,
            incoming: ServerSettings(host: "imap.example.com", port: 993, security: .tls, username: email),
            outgoing: ServerSettings(host: "smtp.example.com", port: 465, security: .tls, username: email)
        )
    }

    private func makeEntry(email: String, name: String = "Person") throws -> EnvironmentAccount {
        let entries = try EnvironmentAccounts.accounts(from: [
            "MAILR_ACCOUNT_WORK_EMAIL": email,
            "MAILR_ACCOUNT_WORK_PASSWORD": "secret",
            "MAILR_ACCOUNT_WORK_NAME": name
        ])
        return try XCTUnwrap(entries.first)
    }
}

final class EnvironmentAccountsPersistenceTests: XCTestCase {
    func testEnvironmentAccountsPersistWithoutPasswords() throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(fileURL: directory.appendingPathComponent("mailr.sqlite3"))
        let entries = try EnvironmentAccounts.accounts(from: [
            "MAILR_ACCOUNT_WORK_EMAIL": "person@gmail.com",
            "MAILR_ACCOUNT_WORK_PASSWORD": "super-secret-password"
        ])

        let merged = EnvironmentAccounts.merge(entries, into: [])
        try store.save(merged)

        XCTAssertEqual(try store.load(), merged)

        let accountID = try XCTUnwrap(merged.first?.id)
        let credentials = InMemoryCredentialStore()
        try credentials.setPassword(try XCTUnwrap(entries.first?.password), for: accountID)
        XCTAssertEqual(try credentials.password(for: accountID), "super-secret-password")

        // The password must never reach the SQLite files.
        for file in try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) {
            let data = try Data(contentsOf: file)
            XCTAssertFalse(
                String(decoding: data, as: UTF8.self).contains("super-secret-password"),
                "Password leaked into \(file.lastPathComponent)"
            )
        }
    }
}

// MARK: - Helpers

private func makeTemporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MailrEnvTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func assertThrows(
    _ expected: EnvironmentConfigurationError,
    values: [String: String],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try EnvironmentAccounts.accounts(from: values), file: file, line: line) { error in
        XCTAssertEqual(error as? EnvironmentConfigurationError, expected, file: file, line: line)
    }
}
