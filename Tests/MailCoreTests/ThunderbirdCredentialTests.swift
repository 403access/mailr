import XCTest
@testable import MailCore

final class ThunderbirdCredentialTests: XCTestCase {
    private func account(
        email: String = "person@example.com",
        incomingHost: String = "imap.example.com",
        incomingUser: String? = nil,
        outgoingHost: String = "smtp.example.com",
        outgoingUser: String? = nil
    ) -> MailAccount {
        MailAccount(
            displayName: "Person",
            emailAddress: email,
            provider: .custom,
            incoming: ServerSettings(
                host: incomingHost,
                port: 993,
                security: .tls,
                username: incomingUser ?? email
            ),
            outgoing: ServerSettings(
                host: outgoingHost,
                port: 465,
                security: .tls,
                username: outgoingUser ?? email
            )
        )
    }

    private func credential(
        scheme: ThunderbirdCredential.Scheme = .imap,
        host: String = "imap.example.com",
        username: String = "person@example.com",
        password: String = "secret",
        isOAuth: Bool = false
    ) -> ThunderbirdCredential {
        ThunderbirdCredential(
            hostname: "\(scheme.rawValue)://\(host)",
            host: host,
            scheme: scheme,
            username: username,
            password: password,
            isOAuth: isOAuth
        )
    }

    func testMatchesByEmailAndWritesKeychainAndHostFile() throws {
        let account = account()
        let keychain = InMemoryCredentialStore()
        let hostFile = makeTemporaryFile()
        let hostStore = HostCredentialStore(fileURL: hostFile)

        let summary = try ThunderbirdCredentialImporter.apply(
            [credential()],
            to: [account],
            profileName: "test",
            credentialStore: keychain,
            hostCredentialStore: hostStore,
            dryRun: false
        )

        XCTAssertEqual(summary.imported, ["person@example.com"])
        XCTAssertEqual(try keychain.password(for: account.id), "secret")
        XCTAssertEqual(hostStore.password(forEmail: "PERSON@example.com"), "secret")
    }

    func testMatchesByHostAndUsernameWhenEmailDiffers() throws {
        let account = account(email: "person@example.com", incomingUser: "login-name")
        let keychain = InMemoryCredentialStore()

        let summary = try ThunderbirdCredentialImporter.apply(
            [credential(host: "imap.example.com", username: "login-name")],
            to: [account],
            profileName: "test",
            credentialStore: keychain,
            hostCredentialStore: nil,
            dryRun: false
        )

        XCTAssertEqual(summary.imported, ["person@example.com"])
        XCTAssertEqual(try keychain.password(for: account.id), "secret")
    }

    func testSMTPIsFallbackWhenNoIMAPCredentialExists() throws {
        let account = account()
        let keychain = InMemoryCredentialStore()

        let summary = try ThunderbirdCredentialImporter.apply(
            [credential(scheme: .smtp, host: "smtp.example.com")],
            to: [account],
            profileName: "test",
            credentialStore: keychain,
            hostCredentialStore: nil,
            dryRun: false
        )

        XCTAssertEqual(summary.imported, ["person@example.com"])
        XCTAssertEqual(try keychain.password(for: account.id), "secret")
    }

    func testOAuthEntriesAreReportedAndNeverUsed() throws {
        let account = account()
        let keychain = InMemoryCredentialStore()

        let summary = try ThunderbirdCredentialImporter.apply(
            [
                credential(
                    scheme: .oauth,
                    host: "accounts.google.com",
                    isOAuth: true
                )
            ],
            to: [account],
            profileName: "test",
            credentialStore: keychain,
            hostCredentialStore: nil,
            dryRun: false
        )

        XCTAssertTrue(summary.imported.isEmpty)
        XCTAssertEqual(summary.oauthSkipped.count, 1)
        XCTAssertNil(try keychain.password(for: account.id))
    }

    func testDryRunWritesNothing() throws {
        let account = account()
        let keychain = InMemoryCredentialStore()
        let hostFile = makeTemporaryFile()
        let hostStore = HostCredentialStore(fileURL: hostFile)

        let summary = try ThunderbirdCredentialImporter.apply(
            [credential()],
            to: [account],
            profileName: "test",
            credentialStore: keychain,
            hostCredentialStore: hostStore,
            dryRun: true
        )

        XCTAssertEqual(summary.wouldImport, ["person@example.com"])
        XCTAssertNil(try keychain.password(for: account.id))
        XCTAssertNil(hostStore.password(forEmail: "person@example.com"))
    }

    func testUnmatchedCredentialIsReported() throws {
        let summary = try ThunderbirdCredentialImporter.apply(
            [credential(host: "other.example.com", username: "other@example.com")],
            to: [account()],
            profileName: "test",
            credentialStore: InMemoryCredentialStore(),
            hostCredentialStore: nil,
            dryRun: false
        )

        XCTAssertTrue(summary.imported.isEmpty)
        XCTAssertEqual(summary.unmatched.count, 1)
    }

    func testHostCredentialFileUsesPrivatePermissions() throws {
        let file = makeTemporaryFile()
        let store = HostCredentialStore(fileURL: file)

        try store.setPassword("secret", forEmail: "person@example.com")

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(store.password(forEmail: "person@example.com"), "secret")
    }

    // MARK: Helpers

    private func makeTemporaryFile() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailrCredentials-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("host-credentials.json")
    }
}
