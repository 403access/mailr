import Foundation

public struct ThunderbirdCredentialImportSummary: Sendable {
    public var profileName: String
    public var imported: [String]
    public var wouldImport: [String]
    public var oauthSkipped: [String]
    public var unmatched: [String]
    public var isDryRun: Bool

    public init(
        profileName: String,
        imported: [String] = [],
        wouldImport: [String] = [],
        oauthSkipped: [String] = [],
        unmatched: [String] = [],
        isDryRun: Bool = false
    ) {
        self.profileName = profileName
        self.imported = imported
        self.wouldImport = wouldImport
        self.oauthSkipped = oauthSkipped
        self.unmatched = unmatched
        self.isDryRun = isDryRun
    }
}

public enum ThunderbirdCredentialImporter {
    /// Reads and decrypts Thunderbird's saved logins, then writes passwords for
    /// matching Mailr accounts into the credential store (the Keychain in the
    /// app and CLI). OAuth2 entries are reported but never used as passwords.
    public static func importCredentials(
        profile: ThunderbirdProfile,
        database: MailDatabase,
        credentialStore: any CredentialStore = KeychainCredentialStore(),
        hostCredentialStore: HostCredentialStore? = HostCredentialStore(),
        nssDirectory: URL? = nil,
        dryRun: Bool = false
    ) throws -> ThunderbirdCredentialImportSummary {
        let credentials = try ThunderbirdCredentials.read(
            profile: profile,
            nssDirectory: nssDirectory
        )
        let accounts = try database.loadAccounts()
        return try apply(
            credentials,
            to: accounts,
            profileName: profile.name,
            credentialStore: credentialStore,
            hostCredentialStore: hostCredentialStore,
            dryRun: dryRun
        )
    }

    /// Matches already-decrypted credentials to accounts and writes them. Kept
    /// separate from NSS loading so it can be unit tested.
    static func apply(
        _ credentials: [ThunderbirdCredential],
        to accounts: [MailAccount],
        profileName: String,
        credentialStore: any CredentialStore,
        hostCredentialStore: HostCredentialStore? = nil,
        dryRun: Bool
    ) throws -> ThunderbirdCredentialImportSummary {
        var summary = ThunderbirdCredentialImportSummary(
            profileName: profileName,
            isDryRun: dryRun
        )
        var preferred: [UUID: ThunderbirdCredential] = [:]
        var smtpFallback: [UUID: ThunderbirdCredential] = [:]
        var hostPasswords: [String: String] = [:]

        for credential in credentials {
            if credential.isOAuth {
                summary.oauthSkipped.append(
                    "\(credential.username) (\(credential.host))"
                )
                continue
            }

            guard let account = match(credential, in: accounts) else {
                summary.unmatched.append(credential.displayName)
                continue
            }

            switch credential.scheme {
            case .imap, .mailbox, .pop3:
                if preferred[account.id] == nil {
                    preferred[account.id] = credential
                }
            case .smtp:
                if smtpFallback[account.id] == nil {
                    smtpFallback[account.id] = credential
                }
            case .oauth, .other:
                break
            }
        }

        for account in accounts where !account.isDemo && account.provider != .local {
            guard let credential = preferred[account.id] ?? smtpFallback[account.id] else {
                continue
            }

            if dryRun {
                summary.wouldImport.append(account.emailAddress)
            } else {
                try credentialStore.setPassword(credential.password, for: account.id)
                hostPasswords[account.emailAddress] = credential.password
                summary.imported.append(account.emailAddress)
            }
        }

        if !dryRun, let hostCredentialStore, !hostPasswords.isEmpty {
            try hostCredentialStore.setPasswords(hostPasswords)
        }

        summary.oauthSkipped = Array(Set(summary.oauthSkipped)).sorted()
        summary.unmatched = Array(Set(summary.unmatched)).sorted()
        return summary
    }

    private static func match(
        _ credential: ThunderbirdCredential,
        in accounts: [MailAccount]
    ) -> MailAccount? {
        let username = credential.username.lowercased()
        let host = credential.host.lowercased()

        // Thunderbird usually stores the full email address as the username.
        if let account = accounts.first(where: {
            $0.emailAddress.lowercased() == username
        }) {
            return account
        }

        if let account = accounts.first(where: {
            $0.incoming.username.lowercased() == username
                || $0.outgoing.username.lowercased() == username
        }) {
            return account
        }

        let matchingHost = accounts.filter { account in
            let incoming = account.incoming.host.lowercased()
            let outgoing = account.outgoing.host.lowercased()
            return incoming == host || outgoing == host
        }

        if matchingHost.count == 1 {
            return matchingHost[0]
        }

        if let account = matchingHost.first(where: {
            $0.incoming.username.lowercased() == username
                || $0.outgoing.username.lowercased() == username
                || $0.emailAddress.lowercased() == username
        }) {
            return account
        }

        return nil
    }
}
