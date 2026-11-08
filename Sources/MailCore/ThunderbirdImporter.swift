import Foundation

// MARK: - Options and results

public struct ThunderbirdImportOptions: Sendable {
    /// Import IMAP account settings.
    public var includeAccounts: Bool
    /// Import local folders, POP3 stores, and (optionally) IMAP caches.
    public var includeMail: Bool
    /// Include Thunderbird's IMAP offline caches. They duplicate mail that is
    /// still available on the server, so they are off by default.
    public var includeIMAPCache: Bool
    /// Update accounts that already exist with the same email address.
    public var overwriteAccounts: Bool
    /// Read and report without writing to the database.
    public var dryRun: Bool

    public init(
        includeAccounts: Bool = true,
        includeMail: Bool = true,
        includeIMAPCache: Bool = false,
        overwriteAccounts: Bool = false,
        dryRun: Bool = false
    ) {
        self.includeAccounts = includeAccounts
        self.includeMail = includeMail
        self.includeIMAPCache = includeIMAPCache
        self.overwriteAccounts = overwriteAccounts
        self.dryRun = dryRun
    }
}

public struct ThunderbirdImportSummary: Sendable {
    public var profileName: String
    public var profilePath: String
    public var accountsCreated: [String]
    public var accountsUpdated: [String]
    public var accountsSkipped: [String]
    public var localAccountName: String?
    public var localAccountEmail: String?
    public var mailboxes: [String]
    public var messageCount: Int
    public var issues: [String]
    public var isDryRun: Bool
}

// MARK: - Importer

public struct ThunderbirdImporter: Sendable {
    public let profile: ThunderbirdProfile
    public let prefs: ThunderbirdPrefs

    public init(profile: ThunderbirdProfile) throws {
        self.profile = profile
        self.prefs = try ThunderbirdPrefs.load(at: profile.prefsURL)
    }

    public func accounts() -> [ThunderbirdAccount] {
        ThunderbirdAccountReader.accounts(prefs: prefs, profilePath: profile.path)
    }

    public func localSources(includeIMAPCache: Bool) -> [ThunderbirdLocalSource] {
        ThunderbirdAccountReader.localSources(
            prefs: prefs,
            profilePath: profile.path,
            accounts: accounts(),
            includeIMAPCache: includeIMAPCache
        )
    }

    /// Imports account settings and local mail into `database`, which is
    /// normally `MailDatabase.defaultURL` (the same file the app uses).
    public func importInto(
        database: MailDatabase,
        options: ThunderbirdImportOptions = ThunderbirdImportOptions()
    ) throws -> ThunderbirdImportSummary {
        let thunderbirdAccounts = accounts()
        var storedAccounts = try database.loadAccounts()

        var summary = ThunderbirdImportSummary(
            profileName: profile.name,
            profilePath: profile.path.path,
            accountsCreated: [],
            accountsUpdated: [],
            accountsSkipped: [],
            localAccountName: nil,
            localAccountEmail: nil,
            mailboxes: [],
            messageCount: 0,
            issues: [],
            isDryRun: options.dryRun
        )

        if options.includeAccounts {
            importServerAccounts(
                thunderbirdAccounts,
                into: &storedAccounts,
                options: options,
                summary: &summary
            )
        }

        if options.includeMail {
            try importLocalMail(
                thunderbirdAccounts: thunderbirdAccounts,
                storedAccounts: &storedAccounts,
                database: database,
                options: options,
                summary: &summary
            )
        }

        if !options.dryRun {
            try database.saveAccounts(storedAccounts)
        }

        return summary
    }

    // MARK: Server accounts

    private func importServerAccounts(
        _ thunderbirdAccounts: [ThunderbirdAccount],
        into storedAccounts: inout [MailAccount],
        options: ThunderbirdImportOptions,
        summary: inout ThunderbirdImportSummary
    ) {
        for candidate in thunderbirdAccounts {
            for issue in candidate.issues {
                summary.issues.append("\(candidate.emailAddress): \(issue)")
            }

            guard candidate.serverType == .imap else {
                if candidate.serverType == .pop3 {
                    summary.accountsSkipped.append("\(candidate.emailAddress) (POP3 is not supported; local mail is still imported)")
                }
                continue
            }

            guard let rawIncoming = candidate.incoming, !rawIncoming.host.isEmpty else {
                summary.accountsSkipped.append("\(candidate.emailAddress) (no incoming server)")
                continue
            }

            let provider = ProviderKind.inferred(forEmail: candidate.emailAddress)
            var incoming = rawIncoming

            if candidate.incomingUsesStartTLS {
                guard let defaults = provider.incomingDefaults,
                      !defaults.host.isEmpty,
                      provider != .custom else {
                    summary.accountsSkipped.append(
                        "\(candidate.emailAddress) (incoming server uses STARTTLS, which Mailr does not support)"
                    )
                    continue
                }
                incoming = defaults
                incoming.username = rawIncoming.username
                summary.issues.append(
                    "\(candidate.emailAddress): using implicit TLS at \(defaults.host):\(defaults.port) instead of Thunderbird's STARTTLS setting."
                )
            }

            var outgoing = candidate.outgoing
            if outgoing == nil || candidate.outgoingUsesStartTLS {
                if let defaults = provider.outgoingDefaults, !defaults.host.isEmpty {
                    outgoing = defaults
                    outgoing?.username = candidate.outgoing?.username ?? candidate.emailAddress
                    if candidate.outgoingUsesStartTLS {
                        summary.issues.append(
                            "\(candidate.emailAddress): using implicit TLS at \(defaults.host):\(defaults.port) instead of Thunderbird's STARTTLS setting."
                        )
                    }
                } else {
                    outgoing = ServerSettings(
                        host: "",
                        port: 465,
                        security: .tls,
                        username: candidate.emailAddress
                    )
                    summary.issues.append(
                        "\(candidate.emailAddress): no supported outgoing server was found. Add one in Mailr before sending."
                    )
                }
            }

            guard var outgoing else {
                summary.accountsSkipped.append("\(candidate.emailAddress) (no outgoing server)")
                continue
            }
            if outgoing.username.isEmpty {
                outgoing.username = candidate.emailAddress
            }
            if incoming.username.isEmpty {
                incoming.username = candidate.emailAddress
            }

            let email = candidate.emailAddress
            let existingIndex = storedAccounts.firstIndex {
                $0.emailAddress.caseInsensitiveCompare(email) == .orderedSame
            }

            if let existingIndex {
                guard options.overwriteAccounts else {
                    summary.accountsSkipped.append("\(email) (already exists)")
                    continue
                }

                var updated = storedAccounts[existingIndex]
                updated.displayName = candidate.displayName
                updated.emailAddress = email
                updated.provider = provider
                updated.incoming = incoming
                updated.outgoing = outgoing
                storedAccounts[existingIndex] = updated
                summary.accountsUpdated.append(email)
            } else {
                let account = MailAccount(
                    id: StableAccountID.email(email),
                    displayName: candidate.displayName,
                    emailAddress: email,
                    provider: provider,
                    incoming: incoming,
                    outgoing: outgoing
                )
                storedAccounts.append(account)
                summary.accountsCreated.append(email)
            }
        }
    }

    // MARK: Local mail

    private func importLocalMail(
        thunderbirdAccounts: [ThunderbirdAccount],
        storedAccounts: inout [MailAccount],
        database: MailDatabase,
        options: ThunderbirdImportOptions,
        summary: inout ThunderbirdImportSummary
    ) throws {
        let sources = ThunderbirdAccountReader.localSources(
            prefs: prefs,
            profilePath: profile.path,
            accounts: thunderbirdAccounts,
            includeIMAPCache: options.includeIMAPCache
        )

        var folders: [ThunderbirdLocalFolder] = []
        var seenPaths = Set<String>()
        for source in sources {
            for folder in ThunderbirdLocalStore.discoverFolders(in: source) {
                if seenPaths.insert(folder.path).inserted {
                    folders.append(folder)
                }
            }
        }

        guard !folders.isEmpty else {
            if options.includeIMAPCache == false, !sources.isEmpty {
                summary.issues.append(
                    "No local mail folders were found. IMAP offline caches are skipped unless --include-imap-cache is set."
                )
            }
            return
        }

        let localAccount = ThunderbirdAccountReader.localMailAccount(for: profile)
        if let index = storedAccounts.firstIndex(where: {
            $0.id == localAccount.id
                || ($0.provider == .local && $0.emailAddress.caseInsensitiveCompare(localAccount.emailAddress) == .orderedSame)
        }) {
            var updated = storedAccounts[index]
            updated.displayName = localAccount.displayName
            updated.emailAddress = localAccount.emailAddress
            storedAccounts[index] = updated
        } else {
            storedAccounts.append(localAccount)
        }

        summary.localAccountName = localAccount.displayName
        summary.localAccountEmail = localAccount.emailAddress
        summary.mailboxes = folders.map(\.path)

        if options.dryRun {
            var estimated = 0
            for folder in folders {
                estimated += (try? ThunderbirdLocalStore.messageCount(in: folder)) ?? 0
            }
            summary.messageCount = estimated
            summary.issues.append("Dry run: no changes were written to the mail database.")
            return
        }

        var mailboxes: [Mailbox] = []
        var failedPaths = Set<String>()
        var seenMailboxPaths = Set<String>()
        let previousMailboxes = (try? database.loadMailboxes(accountID: localAccount.id)) ?? []

        for folder in folders {
            guard seenMailboxPaths.insert(folder.path).inserted else { continue }

            do {
                let stored = try ThunderbirdLocalStore.messages(in: folder)
                var messages: [MailMessage] = []

                for (index, item) in stored.enumerated() {
                    guard let message = Self.makeMessage(
                        item,
                        mailbox: folder.path,
                        uid: UInt32(index + 1)
                    ) else {
                        continue
                    }
                    messages.append(message)
                }

                try database.replaceMailbox(
                    messages,
                    accountID: localAccount.id,
                    mailbox: folder.path
                )

                let unread = messages.reduce(0) { $0 + ($1.summary.isRead ? 0 : 1) }
                mailboxes.append(Mailbox(
                    path: folder.path,
                    name: folder.name,
                    role: folder.role,
                    delimiter: "/",
                    unreadCount: unread,
                    totalCount: messages.count
                ))
                summary.messageCount += messages.count
            } catch {
                failedPaths.insert(folder.path)
                // Keep the previously imported mailbox visible when a
                // transient read error occurs.
                if let previous = previousMailboxes.first(where: { $0.path == folder.path }) {
                    mailboxes.append(previous)
                } else {
                    mailboxes.append(Mailbox(
                        path: folder.path,
                        name: folder.name,
                        role: folder.role,
                        delimiter: "/"
                    ))
                }
                summary.issues.append(
                    "\(folder.path): \(error.localizedDescription)"
                )
            }
        }

        // Remove mailboxes whose Thunderbird source disappeared, but only when
        // every folder imported cleanly so a transient read error cannot erase
        // previously imported mail.
        if failedPaths.isEmpty {
            let current = Set(mailboxes.map(\.path))
            for box in previousMailboxes where !current.contains(box.path) {
                try? database.deleteMailbox(accountID: localAccount.id, mailbox: box.path)
            }
        }

        try database.saveMailboxes(
            Mailbox.sorted(mailboxes),
            accountID: localAccount.id
        )
    }

    // MARK: Message conversion

    private static func makeMessage(
        _ stored: ThunderbirdStoredMessage,
        mailbox: String,
        uid: UInt32
    ) -> MailMessage? {
        guard !stored.data.isEmpty else { return nil }

        let parsed = MessageParser.parse(stored.data)
        let status = parsed.headers["X-Mozilla-Status"]
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces), radix: 16) }

        let isRead = status.map { $0 & 0x0001 != 0 } ?? true
        let isAnswered = status.map { $0 & 0x0002 != 0 } ?? false
        let isFlagged = status.map { $0 & 0x0004 != 0 } ?? false

        let bodyText = parsed.text
            ?? parsed.html.map(MessageParser.stripHTML)

        let summary = MessageSummary(
            uid: uid,
            mailbox: mailbox,
            subject: parsed.subject,
            from: parsed.from,
            to: parsed.to,
            cc: parsed.cc,
            date: parsed.date ?? stored.fallbackDate,
            snippet: snippet(from: bodyText),
            size: stored.data.count,
            isRead: isRead,
            isFlagged: isFlagged,
            isAnswered: isAnswered,
            hasAttachments: parsed.hasAttachments,
            messageID: parsed.messageID,
            inReplyTo: parsed.inReplyTo,
            references: parsed.references,
            isOnMailbox: false
        )

        return MailMessage(
            summary: summary,
            text: bodyText,
            html: parsed.html,
            attachments: parsed.attachments
        )
    }

    private static func snippet(from text: String?) -> String {
        guard let text else { return "" }
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 180 else { return collapsed }
        let prefix = collapsed.prefix(180)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }
}
