import Foundation

// MARK: - Status

public struct HostMailSyncStatus: Codable, Sendable, Equatable {
    public var lastSync: Date?
    public var isSyncing: Bool
    public var accountCount: Int
    public var accountErrors: [String: String]
    public var lastError: String?

    public init(
        lastSync: Date? = nil,
        isSyncing: Bool = false,
        accountCount: Int = 0,
        accountErrors: [String: String] = [:],
        lastError: String? = nil
    ) {
        self.lastSync = lastSync
        self.isSyncing = isSyncing
        self.accountCount = accountCount
        self.accountErrors = accountErrors
        self.lastError = lastError
    }
}

// MARK: - Actions

/// The host-side operations that cannot be answered from SQLite alone. The
/// HTTP router uses these to refresh mailbox data from IMAP and to proxy
/// user actions back to the origin server.
public protocol HostMailActions: Sendable {
    func syncNow() async
    func refreshMailboxes(accountID: UUID) async throws -> [Mailbox]
    func refreshMailbox(accountID: UUID, mailbox: String, limit: Int) async throws -> [MessageSummary]
    func fetchMessage(accountID: UUID, mailbox: String, uid: UInt32) async throws -> MailMessage
    func setFlags(
        accountID: UUID,
        mailbox: String,
        uid: UInt32,
        flags: Set<MessageFlag>,
        enabled: Bool
    ) async throws
    func move(accountID: UUID, from source: String, uid: UInt32, to destination: String) async throws
    func delete(accountID: UUID, mailbox: String, uid: UInt32) async throws
    func send(_ message: OutgoingMessage, accountID: UUID) async throws
    func statusSnapshot() async -> HostMailSyncStatus
    func classify(
        accountID: UUID,
        mailbox: String,
        limit: Int,
        uids: [UInt32]?,
        force: Bool
    ) async throws -> HostClassifyResponse
    func classifierStatus() async -> MailClassifierStatus
}

public extension HostMailActions {
    func classify(
        accountID: UUID,
        mailbox: String,
        limit: Int,
        uids: [UInt32]?,
        force: Bool
    ) async throws -> HostClassifyResponse {
        HostClassifyResponse(classified: 0, status: .disabled)
    }

    func classifierStatus() async -> MailClassifierStatus { .disabled }
}

// MARK: - Engine

/// Owns the IMAP connections on the host machine. It downloads mail into the
/// host database without deleting or moving anything on the origin server.
public actor HostMailSyncEngine: HostMailActions {
    public struct Configuration: Sendable {
        /// How often the background loop refreshes the Inbox.
        public var interval: TimeInterval
        /// Number of summaries fetched when a mailbox is refreshed.
        public var messageLimit: Int
        /// How many newest bodies to download eagerly for each refreshed mailbox.
        public var prefetchBodyLimit: Int
        /// How long a mailbox list or message list is considered fresh.
        public var freshness: TimeInterval
        /// Refresh every mailbox in the background, not just the Inbox.
        public var syncAllMailboxes: Bool
        /// Classify newly seen messages with the local Ollama model.
        public var tagging: TaggingConfiguration
        /// Maximum messages classified per mailbox refresh.
        public var classificationLimit: Int
        public var environment: [String: String]
        public var candidateURLs: [URL]?

        public init(
            interval: TimeInterval = 300,
            messageLimit: Int = 100,
            prefetchBodyLimit: Int = 20,
            freshness: TimeInterval = 30,
            syncAllMailboxes: Bool = false,
            tagging: TaggingConfiguration = TaggingConfiguration(),
            classificationLimit: Int = 10,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            candidateURLs: [URL]? = nil
        ) {
            self.interval = interval
            self.messageLimit = messageLimit
            self.prefetchBodyLimit = prefetchBodyLimit
            self.freshness = freshness
            self.syncAllMailboxes = syncAllMailboxes
            self.tagging = tagging
            self.classificationLimit = classificationLimit
            self.environment = environment
            self.candidateURLs = candidateURLs
        }
    }

    private let database: MailDatabase
    private let hostCredentials: HostCredentialStore
    private let configuration: Configuration
    private let classifier: EmailTagClassifier
    private var isClassifying = false

    private var accounts: [MailAccount]
    private var environmentPasswords: [String: String]
    private var filePasswords: [String: String]
    private var services: [UUID: IMAPMailService] = [:]
    private var serviceAccounts: [UUID: MailAccount] = [:]
    private var servicePasswords: [UUID: String] = [:]
    private var mailboxFreshness: [String: Date] = [:]
    private var mailboxListFreshness: [UUID: Date] = [:]
    private var loopTask: Task<Void, Never>?
    private var isSyncing = false
    private var lastSync: Date?
    private var lastError: String?
    private var accountErrors: [String: String] = [:]

    public init(
        database: MailDatabase,
        hostCredentials: HostCredentialStore = HostCredentialStore(),
        configuration: Configuration = Configuration()
    ) {
        self.database = database
        self.hostCredentials = hostCredentials
        self.configuration = configuration
        self.classifier = EmailTagClassifier(configuration: configuration.tagging)

        var environmentAccounts: [EnvironmentAccount] = []
        if let loaded = try? EnvironmentAccounts.load(
            environment: configuration.environment,
            candidateURLs: configuration.candidateURLs
        ) {
            environmentAccounts = loaded
        }

        let stored = (try? database.loadAccounts()) ?? []
        let merged = EnvironmentAccounts.merge(environmentAccounts, into: stored)
        if merged != stored {
            try? database.saveAccounts(merged)
        }
        self.accounts = merged
        self.environmentPasswords = Self.passwordMap(environmentAccounts)
        self.filePasswords = hostCredentials.load()
    }

    /// Reloads passwords written by `mailr-import credentials` or the Mac app.
    /// This is cheap and lets a password take effect without restarting.
    public func reloadCredentials() {
        filePasswords = hostCredentials.load()
    }

    // MARK: Lifecycle

    /// Starts the background refresh loop. Safe to call from synchronous code.
    public nonisolated func start() {
        Task { await self.startLoop() }
    }

    public nonisolated func stop() {
        Task { await self.stopLoop() }
    }

    private func startLoop() {
        guard loopTask == nil else { return }
        let interval = max(15, configuration.interval)
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
        for service in services.values {
            Task { await service.close() }
        }
        services.removeAll()
        serviceAccounts.removeAll()
        servicePasswords.removeAll()
    }

    // MARK: Accounts

    public func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        reloadAccounts()
        lastError = nil

        for account in accounts where account.provider != .demo && account.provider != .local {
            do {
                let boxes = try await refreshMailboxesLocked(accountID: account.id)
                let targets: [Mailbox]
                if configuration.syncAllMailboxes {
                    targets = boxes
                } else {
                    let inboxes = boxes.filter { $0.role == .inbox }
                    targets = inboxes.isEmpty ? Array(boxes.prefix(1)) : inboxes
                }
                for box in targets {
                    _ = try await refreshMailboxLocked(
                        accountID: account.id,
                        mailbox: box.path,
                        limit: configuration.messageLimit,
                        force: false
                    )
                }
                accountErrors[account.emailAddress] = nil
            } catch {
                accountErrors[account.emailAddress] = error.localizedDescription
                lastError = "\(account.emailAddress): \(error.localizedDescription)"
            }
        }

        lastSync = Date()
    }

    public func statusSnapshot() async -> HostMailSyncStatus {
        HostMailSyncStatus(
            lastSync: lastSync,
            isSyncing: isSyncing,
            accountCount: accounts.count,
            accountErrors: accountErrors,
            lastError: lastError
        )
    }

    private func reloadAccounts() {
        let environmentAccounts: [EnvironmentAccount]
        do {
            environmentAccounts = try EnvironmentAccounts.load(
                environment: configuration.environment,
                candidateURLs: configuration.candidateURLs
            )
        } catch {
            environmentAccounts = []
            if lastError == nil {
                lastError = "Could not read host account configuration: \(error.localizedDescription)"
            }
        }

        environmentPasswords = Self.passwordMap(environmentAccounts)
        filePasswords = hostCredentials.load()
        var stored = (try? database.loadAccounts()) ?? accounts
        stored = EnvironmentAccounts.merge(environmentAccounts, into: stored)
        if stored != accounts {
            try? database.saveAccounts(stored)
        }
        accounts = stored
    }

    // MARK: Mailboxes

    public func refreshMailboxes(accountID: UUID) async throws -> [Mailbox] {
        try await refreshMailboxesLocked(accountID: accountID)
    }

    private func refreshMailboxesLocked(accountID: UUID) async throws -> [Mailbox] {
        guard let account = account(for: accountID) else {
            throw MailError.notConfigured("That account is not available on the host.")
        }
        if account.provider == .local || account.isDemo {
            return Mailbox.sorted(try database.loadMailboxes(accountID: accountID))
        }

        if let last = mailboxListFreshness[accountID],
           Date().timeIntervalSince(last) < configuration.freshness {
            return Mailbox.sorted(try database.loadMailboxes(accountID: accountID))
        }

        let service = try await service(for: account)
        let boxes = try await retrying {
            try await service.listMailboxes()
        }
        try database.saveMailboxes(boxes, accountID: accountID)
        mailboxListFreshness[accountID] = Date()
        return boxes
    }

    public func refreshMailbox(
        accountID: UUID,
        mailbox: String,
        limit: Int
    ) async throws -> [MessageSummary] {
        try await refreshMailboxLocked(
            accountID: accountID,
            mailbox: mailbox,
            limit: limit,
            force: false
        )
    }

    private func refreshMailboxLocked(
        accountID: UUID,
        mailbox: String,
        limit: Int,
        force: Bool
    ) async throws -> [MessageSummary] {
        guard let account = account(for: accountID) else {
            throw MailError.notConfigured("That account is not available on the host.")
        }

        let scopedLimit = min(max(limit, 1), configuration.messageLimit)
        let key = "\(accountID.uuidString)/\(mailbox)"

        if !force,
           let last = mailboxFreshness[key],
           Date().timeIntervalSince(last) < configuration.freshness {
            return try database.loadMessages(
                accountID: accountID,
                mailbox: mailbox,
                limit: scopedLimit
            )
        }

        if account.provider == .local || account.isDemo {
            mailboxFreshness[key] = Date()
            return try database.loadMessages(
                accountID: accountID,
                mailbox: mailbox,
                limit: scopedLimit
            )
        }

        let service = try await service(for: account)
        let summaries = try await retrying {
            try await service.fetchMessages(
                mailbox: mailbox,
                limit: scopedLimit
            )
        }

        // If the window covered the whole mailbox, anything previously known
        // and no longer listed is now host-only.
        let existing = try database.loadMessages(
            accountID: accountID,
            mailbox: mailbox,
            limit: 10_000
        )
        let fetchedIDs = Set(summaries.map(\.id))
        let absent = summaries.count < scopedLimit
            ? existing.filter { $0.isOnMailbox && !fetchedIDs.contains($0.id) }.map(\.uid)
            : []

        try database.syncMailbox(
            summaries,
            accountID: accountID,
            mailbox: mailbox,
            absentUIDs: absent
        )

        for summary in summaries.prefix(configuration.prefetchBodyLimit) {
            guard !(try database.hasBody(
                accountID: accountID,
                mailbox: mailbox,
                uid: summary.uid
            )) else {
                continue
            }
            if let message = try? await service.fetchMessage(mailbox: mailbox, uid: summary.uid) {
                try? database.saveMessage(message, accountID: accountID)
            }
        }

        // Classification is deliberately fire-and-forget: a slow local model
        // must never hold up IMAP sync or a client request.
        if configuration.tagging.enabled, configuration.classificationLimit > 0 {
            let limit = configuration.classificationLimit
            let uids = summaries.map(\.uid)
            Task { [weak self] in
                _ = try? await self?.classify(
                    accountID: accountID,
                    mailbox: mailbox,
                    limit: limit,
                    uids: uids,
                    force: false
                )
            }
        }

        mailboxFreshness[key] = Date()
        return try database.loadMessages(
            accountID: accountID,
            mailbox: mailbox,
            limit: scopedLimit
        )
    }

    // MARK: Messages

    public func fetchMessage(
        accountID: UUID,
        mailbox: String,
        uid: UInt32
    ) async throws -> MailMessage {
        if let stored = try database.loadMessage(
            accountID: accountID,
            mailbox: mailbox,
            uid: uid
        ), stored.text != nil || stored.html != nil || !stored.attachments.isEmpty {
            return stored
        }

        guard let account = account(for: accountID) else {
            throw MailError.notConfigured("That account is not available on the host.")
        }

        let isOnMailbox = (try database.isOnMailbox(
            accountID: accountID,
            mailbox: mailbox,
            uid: uid
        )) ?? false

        guard isOnMailbox, account.provider != .local, !account.isDemo else {
            if let stored = try database.loadMessage(
                accountID: accountID,
                mailbox: mailbox,
                uid: uid
            ) {
                return stored
            }
            throw MailError.commandFailed("That message is not stored on the host.")
        }

        let service = try await service(for: account)
        let message = try await retrying {
            try await service.fetchMessage(mailbox: mailbox, uid: uid)
        }
        try database.saveMessage(message, accountID: accountID)
        return message
    }

    // MARK: Tagging

    public func classifierStatus() async -> MailClassifierStatus {
        await classifier.status()
    }

    public func classify(
        accountID: UUID,
        mailbox: String,
        limit: Int,
        uids: [UInt32]?,
        force: Bool
    ) async throws -> HostClassifyResponse {
        guard configuration.tagging.enabled else {
            return HostClassifyResponse(classified: 0, status: .disabled)
        }

        let status = await classifier.status()
        let tags = try database.loadTags().filter(\.isEnabled)
        guard !tags.isEmpty else {
            return HostClassifyResponse(classified: 0, status: status)
        }

        // A single local model request at a time keeps memory use predictable
        // on small machines. A manual request during a background pass simply
        // reports that work is already in progress.
        guard !isClassifying else {
            return HostClassifyResponse(classified: 0, skipped: 1, status: status)
        }
        isClassifying = true
        defer { isClassifying = false }

        let scopedLimit = min(max(limit, 1), 500)
        let candidates: [MessageSummary]
        if let uids {
            let wanted = Set(uids)
            candidates = try database.loadMessages(
                accountID: accountID,
                mailbox: mailbox,
                limit: 10_000
            ).filter { wanted.contains($0.uid) }
        } else {
            candidates = try database.loadMessages(
                accountID: accountID,
                mailbox: mailbox,
                limit: scopedLimit
            )
        }

        // Filter before applying the limit: the newest messages may already be
        // classified while older ones in the same window are still pending.
        let pendingIDs = Set(try database.unclassifiedUIDs(
            accountID: accountID,
            mailbox: mailbox,
            uids: candidates.map(\.uid),
            force: force
        ))
        let pending = candidates
            .filter { pendingIDs.contains($0.uid) }
            .prefix(scopedLimit)

        var classified = 0
        var failed = 0
        for summary in pending {
            let message = (try? database.loadMessage(
                accountID: accountID,
                mailbox: mailbox,
                uid: summary.uid
            )) ?? MailMessage(summary: summary)

            let outcome = await classifier.classify(message: message, tags: tags)
            do {
                try database.saveClassification(
                    outcome.classifications,
                    accountID: accountID,
                    mailbox: mailbox,
                    uid: summary.uid,
                    classifier: outcome.backend.rawValue
                )
                classified += 1
            } catch {
                failed += 1
            }
        }

        return HostClassifyResponse(
            classified: classified,
            skipped: max(0, candidates.count - pending.count),
            failed: failed,
            status: status
        )
    }

    // MARK: Actions

    public func setFlags(
        accountID: UUID,
        mailbox: String,
        uid: UInt32,
        flags: Set<MessageFlag>,
        enabled: Bool
    ) async throws {
        guard let account = account(for: accountID), account.provider != .local, !account.isDemo else {
            return
        }
        guard (try database.isOnMailbox(accountID: accountID, mailbox: mailbox, uid: uid)) == true else {
            return
        }
        let service = try await service(for: account)
        try await service.setFlags(mailbox: mailbox, uid: uid, flags: flags, enabled: enabled)
    }

    public func move(
        accountID: UUID,
        from source: String,
        uid: UInt32,
        to destination: String
    ) async throws {
        guard let account = account(for: accountID), account.provider != .local, !account.isDemo else {
            return
        }
        guard (try database.isOnMailbox(accountID: accountID, mailbox: source, uid: uid)) == true else {
            return
        }
        let service = try await service(for: account)
        try await service.move(mailbox: source, uid: uid, to: destination)
    }

    public func delete(accountID: UUID, mailbox: String, uid: UInt32) async throws {
        guard let account = account(for: accountID), account.provider != .local, !account.isDemo else {
            return
        }
        guard (try database.isOnMailbox(accountID: accountID, mailbox: mailbox, uid: uid)) == true else {
            return
        }
        let service = try await service(for: account)
        try await service.delete(mailbox: mailbox, uid: uid)
    }

    public func send(_ message: OutgoingMessage, accountID: UUID) async throws {
        guard let account = account(for: accountID), account.provider != .local, !account.isDemo else {
            throw MailError.notConfigured("This account only contains local mail and cannot send.")
        }
        let service = try await service(for: account)
        try await service.send(message)
    }

    // MARK: Services

    private func account(for accountID: UUID) -> MailAccount? {
        accounts.first { $0.id == accountID }
    }

    private func service(for account: MailAccount) async throws -> IMAPMailService {
        let password = try password(for: account)

        if let existing = services[account.id],
           serviceAccounts[account.id] == account,
           servicePasswords[account.id] == password {
            return existing
        }

        if let existing = services[account.id] {
            await existing.close()
        }

        let service = IMAPMailService(account: account, password: password)
        services[account.id] = service
        serviceAccounts[account.id] = account
        servicePasswords[account.id] = password
        return service
    }

    /// A stale or reset IMAP socket is common when the host has been idle.
    /// Retry read-only operations once; the service reconnects on the next try.
    private func retrying<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as MailError {
            switch error {
            case .connection, .protocolViolation:
                try? await Task.sleep(nanoseconds: 400_000_000)
                return try await operation()
            default:
                throw error
            }
        }
    }

    private func password(for account: MailAccount) throws -> String {
        if let password = environmentPasswords[account.emailAddress.lowercased()], !password.isEmpty {
            return password
        }
        if let password = filePasswords[account.emailAddress.lowercased()], !password.isEmpty {
            return password
        }
        throw MailError.authentication(
            "The host has no password for \(account.emailAddress). Import Thunderbird credentials or add one in the Mac app."
        )
    }

    private static func passwordMap(_ entries: [EnvironmentAccount]) -> [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            guard let password = entry.password, !password.isEmpty else { continue }
            result[entry.account.emailAddress.lowercased()] = password
        }
        return result
    }
}
