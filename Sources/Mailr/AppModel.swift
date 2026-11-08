import Foundation
import Observation
import MailCore

struct MailboxSelection: Hashable {
    var accountID: UUID
    var mailboxPath: String
}

struct ComposeDraft: Identifiable {
    let id = UUID()
    var accountID: UUID
    var to: String = ""
    var cc: String = ""
    var bcc: String = ""
    var subject: String = ""
    var body: String = ""
    var attachments: [OutgoingAttachment] = []
    var inReplyTo: String?
    var references: [String] = []
    var isSending = false
}

struct AccountRuntime: Identifiable {
    var account: MailAccount
    var mailboxes: [Mailbox] = []
    var isLoadingMailboxes = false
    var error: String?

    var id: UUID { account.id }
}

@MainActor
@Observable
final class AppModel {
    // Sidebar & accounts
    var runtimes: [AccountRuntime] = []
    var selection: MailboxSelection?
    var collapsedAccountIDs: Set<UUID> = [] {
        didSet { persistCollapsedAccountIDs() }
    }
    var showSettings = false
    var isRefreshing = false
    var statusText: String?

    // Message list
    var messages: [MessageSummary] = []
    var selectedMessageID: String?
    var isLoadingMessages = false
    var messagesError: String?
    var searchText = ""

    // Reader
    var currentMessage: MailMessage?
    var isLoadingBody = false
    var remoteContentAllowed = false
    var currentStorage: MessageStorageStatus?
    var hostArchiveHealth: HostMailHealth?
    var isCheckingHostArchive = false

    // Compose & alerts
    var compose: ComposeDraft?
    var errorMessage: String?

    @ObservationIgnored private let accountStore = AccountStore()
    @ObservationIgnored private let credentials = KeychainCredentialStore()
    @ObservationIgnored private let hostConfiguration: HostMailConfiguration?
    @ObservationIgnored private let hostStore: (any HostMailStore)?
    @ObservationIgnored private var services: [UUID: any MailService] = [:]
    @ObservationIgnored private var hostAccountIDs: Set<UUID> = []
    @ObservationIgnored private static let hostAccountIDsKey = "MailrHostAccountIDs"
    @ObservationIgnored private static let collapsedAccountIDsKey = "MailrCollapsedAccountIDs"
    private(set) var isHostMode = false
    @ObservationIgnored private var loadToken = UUID()
    @ObservationIgnored private var bodyToken = UUID()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var clearStatusTask: Task<Void, Never>?
    @ObservationIgnored private var composeSuspendedForLock: ComposeDraft?
    @ObservationIgnored private var captureComposeOnDisappear = false
    @ObservationIgnored private var settingsSuspendedForLock = false

    /// Whether the first mailbox/message load has finished. Used to avoid
    /// duplicating startup work when the app is unlocked.
    private(set) var hasLoadedInitialMail = false

    init() {
        let configuration = HostMailConfiguration.load()
        self.hostConfiguration = configuration
        self.hostStore = configuration.map { HTTPHostMailStore(configuration: $0) }

        let storedHostIDs = UserDefaults.standard.stringArray(forKey: Self.hostAccountIDsKey) ?? []
        hostAccountIDs = Set(storedHostIDs.compactMap { UUID(uuidString: $0) })
        isHostMode = !hostAccountIDs.isEmpty

        let storedCollapsedIDs = UserDefaults.standard.stringArray(forKey: Self.collapsedAccountIDsKey) ?? []
        collapsedAccountIDs = Set(storedCollapsedIDs.compactMap { UUID(uuidString: $0) })

        loadAccounts()
    }

    // MARK: - Derived state

    var activeRuntime: AccountRuntime? {
        guard let selection else { return nil }
        return runtimes.first(where: { $0.id == selection.accountID })
    }

    var activeAccount: MailAccount? { activeRuntime?.account }

    var activeMailbox: Mailbox? {
        guard let selection else { return nil }
        return activeRuntime?.mailboxes.first(where: { $0.path == selection.mailboxPath })
    }

    /// Accounts that currently have at least one mailbox section to show.
    var hasMailboxSections: Bool {
        runtimes.contains { !$0.mailboxes.isEmpty }
    }

    var allMailboxSectionsCollapsed: Bool {
        let accounts = runtimes.filter { !$0.mailboxes.isEmpty }
        guard !accounts.isEmpty else { return false }
        return accounts.allSatisfy { collapsedAccountIDs.contains($0.id) }
    }

    func isMailboxSectionCollapsed(_ accountID: UUID) -> Bool {
        collapsedAccountIDs.contains(accountID)
    }

    func toggleMailboxSection(_ accountID: UUID) {
        if collapsedAccountIDs.contains(accountID) {
            collapsedAccountIDs.remove(accountID)
        } else {
            collapsedAccountIDs.insert(accountID)
        }
    }

    func toggleAllMailboxSections() {
        if allMailboxSectionsCollapsed {
            collapsedAccountIDs.removeAll()
        } else {
            collapsedAccountIDs = Set(
                runtimes.filter { !$0.mailboxes.isEmpty }.map(\.id)
            )
        }
    }

    private func persistCollapsedAccountIDs() {
        UserDefaults.standard.set(
            collapsedAccountIDs.map(\.uuidString).sorted(),
            forKey: Self.collapsedAccountIDsKey
        )
    }

    var selectedSummary: MessageSummary? {
        guard let selectedMessageID else { return nil }
        return messages.first(where: { $0.id == selectedMessageID })
    }

    var filteredMessages: [MessageSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return messages }
        return messages.filter { message in
            message.subject.localizedCaseInsensitiveContains(query)
                || message.senderDisplayName.localizedCaseInsensitiveContains(query)
                || message.senderAddress.localizedCaseInsensitiveContains(query)
                || message.snippet.localizedCaseInsensitiveContains(query)
        }
    }

    var totalUnread: Int {
        runtimes.reduce(0) { partial, runtime in
            partial + runtime.mailboxes
                .filter { $0.role == .inbox }
                .reduce(0) { $0 + $1.unreadCount }
        }
    }

    var currentAccountAddress: String {
        activeAccount?.emailAddress ?? ""
    }

    /// The host archive address, or `nil` when host syncing is disabled.
    var hostArchiveAddress: String? {
        hostConfiguration?.displayAddress
    }

    var isHostArchiveEnabled: Bool {
        hostStore != nil
    }

    func refreshHostArchiveStatus() async {
        guard let hostStore else {
            hostArchiveHealth = nil
            return
        }
        isCheckingHostArchive = true
        hostArchiveHealth = try? await hostStore.health()
        isCheckingHostArchive = false
    }

    func isHostAccount(_ accountID: UUID) -> Bool {
        hostAccountIDs.contains(accountID)
    }

    /// The host server reads this file when it downloads mail. It is written
    /// with 0600 permissions next to the host database.
    func setHostPassword(_ password: String, for account: MailAccount) throws {
        try HostCredentialStore().setPassword(password, forEmail: account.emailAddress)
    }

    func refreshHostNow() async {
        guard let hostStore else { return }
        try? await hostStore.requestSync()
        await refreshHostAccounts()
        if let selection {
            await loadMailboxes(for: selection.accountID)
            await loadMessages(preserveSelection: true)
        }
    }

    /// Replaces the locally configured accounts with the accounts owned by the
    /// host server. The host is the authority when it exposes any accounts.
    private func refreshHostAccounts() async {
        guard let hostStore else { return }

        var hostAccounts: [MailAccount] = []
        for attempt in 0..<4 {
            if let fetched = try? await hostStore.accounts(), !fetched.isEmpty {
                hostAccounts = fetched
                break
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        guard !hostAccounts.isEmpty else { return }

        let existingMailboxes = Dictionary(
            uniqueKeysWithValues: runtimes.map { ($0.id, $0.mailboxes) }
        )
        var accounts = hostAccounts
        if let demo = runtimes.first(where: { $0.account.isDemo })?.account,
           !accounts.contains(where: { $0.id == demo.id }) {
            accounts.insert(demo, at: 0)
        }

        runtimes = accounts.map { account in
            let boxes = existingMailboxes[account.id]
                ?? ((try? database.loadMailboxes(accountID: account.id)) ?? [])
            return AccountRuntime(account: account, mailboxes: boxes)
        }

        hostAccountIDs = Set(hostAccounts.map(\.id))
        isHostMode = true
        UserDefaults.standard.set(
            hostAccountIDs.map(\.uuidString),
            forKey: Self.hostAccountIDsKey
        )
        try? accountStore.save(accounts)

        if let selection, !accounts.contains(where: { $0.id == selection.accountID }) {
            self.selection = nil
        }
    }

    // MARK: - Startup

    func start() async {
        guard !started else { return }
        started = true

        await refreshHostAccounts()

        let demoID = runtimes.first(where: { $0.account.isDemo })?.id
        if let demoID {
            await loadMailboxes(for: demoID)
        }

        for runtime in runtimes where runtime.account.isDemo == false {
            await loadMailboxes(for: runtime.id)
        }

        if selection == nil {
            selectDefaultMailbox()
        }

        #if DEBUG
        if let preview = ProcessInfo.processInfo.environment["MAILR_UI_PREVIEW"] {
            await applyPreviewMode(preview)
        }
        #endif

        hasLoadedInitialMail = true
    }

    #if DEBUG
    /// Small, debug-only launch hook used for screenshot and simulator smoke
    /// tests. It is compiled out of release builds.
    private func applyPreviewMode(_ mode: String) async {
        // Let the first UI task finish so this preview does not race with the
        // normal selection-driven load.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard let demoID = runtimes.first(where: { $0.account.isDemo })?.id else { return }

        if selection == nil || selection?.accountID != demoID,
           let inbox = runtimes.first(where: { $0.id == demoID })?.mailboxes.first(where: { $0.role == .inbox }) {
            selection = MailboxSelection(accountID: demoID, mailboxPath: inbox.path)
        }

        switch mode {
        case "inbox":
            await loadMessages()
        case "message":
            await loadMessages()
            if let first = messages.first {
                selectedMessageID = first.id
                await openSelectedMessage()
            }
        case "attachment":
            await loadMessages()
            if let withAttachment = messages.first(where: { $0.hasAttachments }) {
                selectedMessageID = withAttachment.id
                await openSelectedMessage()
            }
        case "compose":
            newCompose()
        case "settings", "security":
            showSettings = true
        case "account":
            showSettings = true
        default:
            break
        }
    }
    #endif

    private var database: MailDatabase { accountStore.database }

    private func loadAccounts() {
        do {
            var stored = try accountStore.load()
            if stored.isEmpty {
                stored = [.demo]
                try? accountStore.save(stored)
            }

            applyEnvironmentAccounts(to: &stored)

            runtimes = stored.map { account in
                // Restore the last known mailboxes so the sidebar works offline
                // until the next network refresh completes.
                let boxes = (try? database.loadMailboxes(accountID: account.id)) ?? []
                return AccountRuntime(account: account, mailboxes: boxes)
            }
        } catch {
            errorMessage = "Could not read your account list: \(error.localizedDescription)"
            runtimes = [AccountRuntime(account: .demo)]
        }
    }

    /// Imports accounts from the optional local `.env` file. Passwords are
    /// written to the Keychain; only account metadata is stored in SQLite.
    private func applyEnvironmentAccounts(to accounts: inout [MailAccount]) {
        let imported: [EnvironmentAccount]
        do {
            imported = try EnvironmentAccounts.load()
        } catch {
            errorMessage = ".env: \(error.localizedDescription)"
            return
        }

        guard !imported.isEmpty else { return }

        let merged = EnvironmentAccounts.merge(imported, into: accounts)
        if merged != accounts {
            accounts = merged
            do {
                try accountStore.save(accounts)
            } catch {
                errorMessage = "Could not save the accounts from .env: \(error.localizedDescription)"
            }
        }

        for entry in imported {
            guard let password = entry.password, !password.isEmpty else { continue }

            let accountID = accounts.first(where: {
                $0.id == entry.account.id
                    || $0.emailAddress.caseInsensitiveCompare(entry.account.emailAddress) == .orderedSame
            })?.id ?? entry.account.id

            do {
                try credentials.setPassword(password, for: accountID)
            } catch {
                errorMessage = "Could not save the .env password for \(entry.account.emailAddress): \(error.localizedDescription)"
            }
        }
    }

    private func selectDefaultMailbox() {
        guard selection == nil else { return }
        for runtime in runtimes {
            if let inbox = runtime.mailboxes.first(where: { $0.role == .inbox }) ?? runtime.mailboxes.first {
                selection = MailboxSelection(accountID: runtime.id, mailboxPath: inbox.path)
                return
            }
        }
    }

    // MARK: - Mailboxes

    func loadMailboxes(for accountID: UUID) async {
        guard let index = runtimes.firstIndex(where: { $0.id == accountID }) else { return }
        runtimes[index].isLoadingMailboxes = true
        runtimes[index].error = nil

        let account = runtimes[index].account
        do {
            let service = try service(for: accountID)
            let boxes = try await service.listMailboxes()
            try? database.saveMailboxes(boxes, accountID: accountID)
            if let hostStore, account.provider != .local, !hostAccountIDs.contains(accountID) {
                try? await hostStore.saveMailboxes(boxes, accountID: accountID)
            }
            guard let currentIndex = runtimes.firstIndex(where: { $0.id == accountID }) else { return }
            runtimes[currentIndex].mailboxes = boxes
            runtimes[currentIndex].error = nil

            if selection == nil, let inbox = boxes.first(where: { $0.role == .inbox }) ?? boxes.first {
                selection = MailboxSelection(accountID: accountID, mailboxPath: inbox.path)
            } else if let selection, selection.accountID == accountID,
                      !boxes.contains(where: { $0.path == selection.mailboxPath }) {
                self.selection = boxes.first.map {
                    MailboxSelection(accountID: accountID, mailboxPath: $0.path)
                }
            }
        } catch {
            guard let currentIndex = runtimes.firstIndex(where: { $0.id == accountID }) else { return }
            runtimes[currentIndex].error = error.localizedDescription
            if runtimes[currentIndex].mailboxes.isEmpty, selection?.accountID == accountID {
                self.selection = nil
            }
            if account.isDemo == false {
                // Surface setup problems once, rather than on every refresh.
                errorMessage = error.localizedDescription
            }
        }

        if let currentIndex = runtimes.firstIndex(where: { $0.id == accountID }) {
            runtimes[currentIndex].isLoadingMailboxes = false
        }
    }

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if let hostStore, isHostMode {
            try? await hostStore.requestSync()
            await refreshHostAccounts()
        }

        for runtime in runtimes {
            await loadMailboxes(for: runtime.id)
        }
        if selection != nil {
            await loadMessages(preserveSelection: true)
        }
    }

    // MARK: - App Lock

    /// Closes transient sheets so the lock screen cannot be covered by them,
    /// remembering what was open so it can be restored after unlocking.
    func suspendForLock() {
        if showSettings {
            settingsSuspendedForLock = true
            showSettings = false
        }
        if let compose {
            // `ComposeView` keeps edits in local state, so remember the draft
            // it hands back when the sheet finishes dismissing.
            composeSuspendedForLock = compose
            captureComposeOnDisappear = true
            self.compose = nil
        }
    }

    /// Called by `ComposeView` when its sheet goes away. Only captures the
    /// draft when the dismissal came from App Lock, so a normal cancel still
    /// discards the message.
    func composeViewDidDisappear(_ draft: ComposeDraft) {
        guard captureComposeOnDisappear else { return }
        captureComposeOnDisappear = false
        composeSuspendedForLock = draft
    }

    func restoreAfterUnlock() {
        if settingsSuspendedForLock {
            settingsSuspendedForLock = false
            showSettings = true
        }
        captureComposeOnDisappear = false
        if let draft = composeSuspendedForLock {
            composeSuspendedForLock = nil
            compose = draft
        }
    }

    // MARK: - Messages

    func loadMessages(preserveSelection: Bool = false) async {
        guard let selection else {
            messages = []
            selectedMessageID = nil
            currentMessage = nil
            currentStorage = nil
            return
        }

        let token = UUID()
        loadToken = token
        isLoadingMessages = true
        messagesError = nil
        if !preserveSelection {
            selectedMessageID = nil
            currentMessage = nil
            currentStorage = nil
            searchText = ""
        }

        // Show the cached list immediately, then replace it with the server's
        // response. Offline launches still have something to display.
        var cachedHostOnly: [MessageSummary] = []
        if let cached = try? database.loadMessages(
            accountID: selection.accountID,
            mailbox: selection.mailboxPath,
            limit: 100
        ) {
            cachedHostOnly = cached.filter { !$0.isOnMailbox }
            if messages.isEmpty || !preserveSelection {
                messages = cached
            }
        }

        do {
            let service = try service(for: selection.accountID)
            let fetched = try await service.fetchMessages(mailbox: selection.mailboxPath, limit: 100)
            guard token == loadToken else { return }

            let isLocalAccount = runtimes.first(where: { $0.id == selection.accountID })?.account.provider == .local
            let isHostAccount = hostAccountIDs.contains(selection.accountID)
            var visible = fetched
            if !isLocalAccount && !isHostAccount {
                for index in visible.indices {
                    visible[index].isOnMailbox = true
                }
            }

            // Ask the host archive for everything it holds in this mailbox,
            // then merge in mail that is no longer visible on the real IMAP
            // server. The newest-window check avoids treating older archived
            // messages as host-only just because the client only fetches 100.
            var merged = visible
            let visibleIDs = Set(visible.map(\.id))
            var hostOnly: [MessageSummary] = []
            if let hostStore, !isLocalAccount, !isHostAccount {
                let snapshot = try? await hostStore.mailboxSnapshot(
                    accountID: selection.accountID,
                    mailbox: selection.mailboxPath,
                    limit: 300
                )
                let cutoff: Date
                if visible.count >= 100, let oldest = visible.map(\.date).min() {
                    cutoff = oldest
                } else {
                    cutoff = .distantPast
                }

                if let snapshot {
                    hostOnly = snapshot
                        .filter { !visibleIDs.contains($0.id) && $0.date >= cutoff }
                        .map { message in
                            var copy = message
                            copy.isOnMailbox = false
                            return copy
                        }
                    merged.append(contentsOf: hostOnly)
                } else {
                    // The archive is unreachable; keep host-only rows already
                    // cached on this device so they do not disappear.
                    merged.append(contentsOf: cachedHostOnly.filter { !visibleIDs.contains($0.id) })
                }
                merged.sort { $0.date > $1.date }

                try? await hostStore.syncMailbox(
                    accountID: selection.accountID,
                    mailbox: selection.mailboxPath,
                    messages: visible,
                    absentUIDs: hostOnly.map(\.uid)
                )
            } else {
                merged.append(contentsOf: cachedHostOnly.filter { !visibleIDs.contains($0.id) })
                merged.sort { $0.date > $1.date }
            }

            guard token == loadToken else { return }
            messages = merged

            // The live mailbox snapshot replaces locally cached summaries.
            // Host-only rows are preserved separately so they stay available
            // while the archive is offline.
            try? database.replaceMessages(
                visible,
                accountID: selection.accountID,
                mailbox: selection.mailboxPath
            )
            if !hostOnly.isEmpty {
                try? database.upsertMessages(hostOnly, accountID: selection.accountID)
            }

            if preserveSelection, let id = selectedMessageID,
               !merged.contains(where: { $0.id == id }) {
                selectedMessageID = nil
                currentMessage = nil
            }
        } catch {
            guard token == loadToken else { return }
            messagesError = error.localizedDescription
        }

        if token == loadToken {
            isLoadingMessages = false
        }
    }

    func selectionDidChange() async {
        currentMessage = nil
        currentStorage = nil
        remoteContentAllowed = false
        await loadMessages()
    }

    func openSelectedMessage() async {
        guard let selection, let id = selectedMessageID,
              let summary = messages.first(where: { $0.id == id }) else {
            currentMessage = nil
            currentStorage = nil
            return
        }

        let token = UUID()
        bodyToken = token
        isLoadingBody = true
        remoteContentAllowed = false
        currentStorage = MessageStorageStatus(
            onMailbox: summary.isOnMailbox,
            onHost: false,
            onDevice: false
        )

        let isLocalAccount = runtimes.first(where: { $0.id == selection.accountID })?.account.provider == .local
        let isHostAccount = hostAccountIDs.contains(selection.accountID)

        do {
            let service = try service(for: selection.accountID)
            let fetchedMessage = try await service.fetchMessage(mailbox: summary.mailbox, uid: summary.uid)
            guard token == bodyToken, selectedMessageID == id else { return }

            var message = fetchedMessage
            if !isLocalAccount && !isHostAccount {
                message.summary.isOnMailbox = true
            }
            try? database.saveMessage(message, accountID: selection.accountID)
            updateSummary(id: id) { $0.isOnMailbox = message.summary.isOnMailbox }

            // Mirror the full message to the host archive. Failing to reach
            // the archive must never make the mailbox unreadable.
            var onHost = isHostAccount
            if let hostStore, !isLocalAccount, !isHostAccount {
                do {
                    try await hostStore.storeMessage(message, accountID: selection.accountID)
                    onHost = true
                } catch {
                    onHost = false
                }
            }

            guard token == bodyToken, selectedMessageID == id else { return }
            currentMessage = message
            currentStorage = MessageStorageStatus(
                onMailbox: isHostAccount ? message.summary.isOnMailbox : !isLocalAccount,
                onHost: onHost,
                onDevice: true
            )
            isLoadingBody = false

            if summary.isUnread {
                markSeen(message: summary, seen: true)
            }
        } catch {
            guard token == bodyToken else { return }

            // A connection or authentication failure leaves the mailbox state
            // unknown; a command failure means the message is no longer there.
            let mailboxStillHasMessage = self.mailboxStillHasMessage(after: error)

            // Prefer the host archive, then the local cache.
            var onHost = false
            var loaded: MailMessage?
            if let hostStore, !isLocalAccount, !isHostAccount,
               let hostMessage = try? await hostStore.storedMessage(
                   accountID: selection.accountID,
                   mailbox: summary.mailbox,
                   uid: summary.uid
               ) {
                onHost = true
                updateSummary(id: id) {
                    $0.isOnMailbox = mailboxStillHasMessage ? summary.isOnMailbox : false
                }

                // The archive may only have the summary if the body was never
                // downloaded. Fall through to the local cache in that case.
                if hostMessage.text != nil
                    || hostMessage.html != nil
                    || !hostMessage.attachments.isEmpty {
                    var copy = hostMessage
                    copy.summary.isOnMailbox = mailboxStillHasMessage ? summary.isOnMailbox : false
                    loaded = copy
                }
            }

            guard token == bodyToken, selectedMessageID == id else { return }

            if loaded == nil {
                loaded = (try? database.loadMessage(
                    accountID: selection.accountID,
                    mailbox: summary.mailbox,
                    uid: summary.uid
                )) ?? nil
            }

            isLoadingBody = false
            if var message = loaded {
                if !mailboxStillHasMessage {
                    message.summary.isOnMailbox = false
                    updateSummary(id: id) { $0.isOnMailbox = false }
                }
                try? database.saveMessage(message, accountID: selection.accountID)
                currentMessage = message
                currentStorage = MessageStorageStatus(
                    onMailbox: message.summary.isOnMailbox,
                    onHost: onHost,
                    onDevice: true
                )
            } else {
                currentStorage = MessageStorageStatus(
                    onMailbox: mailboxStillHasMessage ? summary.isOnMailbox : false,
                    onHost: false,
                    onDevice: false
                )
                errorMessage = error.localizedDescription
                currentMessage = MailMessage(summary: summary, text: nil, html: nil)
            }
        }
    }

    /// Interprets a body-fetch failure for the storage badge. Transient
    /// connection/auth problems leave the mailbox state unknown, while a
    /// command failure means the message is gone from the mailbox.
    private func mailboxStillHasMessage(after error: any Error) -> Bool {
        guard let mailError = error as? MailError else { return true }
        switch mailError {
        case .connection, .protocolViolation, .authentication, .notConfigured, .unsupported:
            return true
        case .commandFailed, .invalidMessage:
            return false
        }
    }

    func toggleFlag(_ summary: MessageSummary? = nil) {
        guard let target = summary ?? currentMessage?.summary ?? selectedSummary,
              let accountID = accountID(forMailbox: target.mailbox) ?? selection?.accountID else {
            return
        }
        let next = !target.isFlagged

        updateSummary(id: target.id) { $0.isFlagged = next }
        if currentMessage?.id == target.id {
            currentMessage?.summary.isFlagged = next
        }
        try? database.updateFlags(
            accountID: accountID,
            mailbox: target.mailbox,
            uid: target.uid,
            isFlagged: next
        )

        Task {
            do {
                let service = try service(for: accountID)
                try await service.setFlags(
                    mailbox: target.mailbox,
                    uid: target.uid,
                    flags: [.flagged],
                    enabled: next
                )
                if let hostStore, !hostAccountIDs.contains(accountID) {
                    try? await hostStore.updateFlags(
                        accountID: accountID,
                        mailbox: target.mailbox,
                        uid: target.uid,
                        isRead: nil,
                        isFlagged: next,
                        isAnswered: nil
                    )
                }
            } catch {
                updateSummary(id: target.id) { $0.isFlagged = !next }
                if currentMessage?.id == target.id {
                    currentMessage?.summary.isFlagged = !next
                }
                try? database.updateFlags(
                    accountID: accountID,
                    mailbox: target.mailbox,
                    uid: target.uid,
                    isFlagged: !next
                )
                if let hostStore, !hostAccountIDs.contains(accountID) {
                    try? await hostStore.updateFlags(
                        accountID: accountID,
                        mailbox: target.mailbox,
                        uid: target.uid,
                        isRead: nil,
                        isFlagged: !next,
                        isAnswered: nil
                    )
                }
                errorMessage = error.localizedDescription
            }
        }
    }

    func markUnread(_ summary: MessageSummary? = nil) {
        guard let target = summary ?? currentMessage?.summary ?? selectedSummary,
              let accountID = accountID(forMailbox: target.mailbox) ?? selection?.accountID else {
            return
        }
        markSeen(message: target, seen: false, account: accountID)
    }

    func markRead(_ summary: MessageSummary? = nil) {
        guard let target = summary ?? currentMessage?.summary ?? selectedSummary,
              let accountID = accountID(forMailbox: target.mailbox) ?? selection?.accountID else {
            return
        }
        markSeen(message: target, seen: true, account: accountID)
    }

    private func markSeen(message: MessageSummary, seen: Bool, account: UUID? = nil) {
        guard let resolvedAccount = account ?? accountID(forMailbox: message.mailbox) ?? selection?.accountID else {
            return
        }
        guard message.isRead != seen else { return }

        updateSummary(id: message.id) { $0.isRead = seen }
        if currentMessage?.id == message.id {
            currentMessage?.summary.isRead = seen
        }
        if let index = mailboxesIndex(accountID: resolvedAccount, path: message.mailbox) {
            let current = runtimes[index.account].mailboxes[index.mailbox].unreadCount
            runtimes[index.account].mailboxes[index.mailbox].unreadCount = max(0, current + (seen ? -1 : 1))
        }
        try? database.updateFlags(
            accountID: resolvedAccount,
            mailbox: message.mailbox,
            uid: message.uid,
            isRead: seen
        )

        Task {
            do {
                let service = try service(for: resolvedAccount)
                try await service.setFlags(
                    mailbox: message.mailbox,
                    uid: message.uid,
                    flags: [.seen],
                    enabled: seen
                )
                if let hostStore, !hostAccountIDs.contains(resolvedAccount) {
                    try? await hostStore.updateFlags(
                        accountID: resolvedAccount,
                        mailbox: message.mailbox,
                        uid: message.uid,
                        isRead: seen,
                        isFlagged: nil,
                        isAnswered: nil
                    )
                }
            } catch {
                // Leave the optimistic state alone; a refresh will correct it.
            }
        }
    }

    func delete(_ summary: MessageSummary? = nil) {
        guard let target = summary ?? currentMessage?.summary ?? selectedSummary,
              let accountID = accountID(forMailbox: target.mailbox) ?? selection?.accountID else {
            return
        }

        let nextSelection = neighborID(after: target.id)
        removeLocally(id: target.id)

        Task {
            do {
                // Host-only messages no longer exist on the IMAP server, so
                // only ask the mailbox to delete messages it still owns.
                if target.isOnMailbox {
                    let service = try service(for: accountID)
                    try await service.delete(mailbox: target.mailbox, uid: target.uid)
                }
                try? database.deleteMessage(
                    accountID: accountID,
                    mailbox: target.mailbox,
                    uid: target.uid
                )
                if let hostStore {
                    try? await hostStore.deleteMessage(
                        accountID: accountID,
                        mailbox: target.mailbox,
                        uid: target.uid
                    )
                }
                await loadMailboxes(for: accountID)
                await loadMessages(preserveSelection: true)
                if let nextSelection, messages.contains(where: { $0.id == nextSelection }) {
                    selectedMessageID = nextSelection
                    await openSelectedMessage()
                }
            } catch {
                errorMessage = error.localizedDescription
                await loadMessages(preserveSelection: true)
            }
        }
    }

    func replyToCurrentMessage() {
        guard let message = currentMessage ?? selectedSummary.map({ MailMessage(summary: $0) }) else {
            return
        }

        let preferredID = accountID(forMailbox: message.summary.mailbox) ?? selection?.accountID
        let accountID = preferredID.flatMap { id in
            runtimes.first(where: { $0.id == id && $0.account.provider != .local })?.id
        } ?? runtimes.first(where: {
            $0.account.provider != .local && !$0.account.isDemo
        })?.id

        guard let accountID else {
            errorMessage = "Add a mail account before replying to imported mail."
            return
        }

        let account = runtimes.first(where: { $0.id == accountID })?.account
        let ownAddresses = Set([account?.emailAddress.lowercased() ?? ""])
        let recipient = message.summary.from.first(where: { !ownAddresses.contains($0.address.lowercased()) })
            ?? message.summary.to.first(where: { !ownAddresses.contains($0.address.lowercased()) })
            ?? message.summary.from.first

        let subject = message.summary.subject.lowercased().hasPrefix("re:")
            ? message.summary.subject
            : "Re: \(message.summary.subject)"

        let source = message.text
            ?? message.html.map(MessageParser.stripHTML)
            ?? ""
        let quoted = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }
            .joined(separator: "\n")

        var references = message.summary.references
        if let messageID = message.summary.messageID, !references.contains(messageID) {
            references.append(messageID)
        }

        compose = ComposeDraft(
            accountID: accountID,
            to: recipient?.address ?? "",
            subject: subject,
            body: "\n\nOn \(message.summary.date.formatted(date: .abbreviated, time: .shortened)), \(message.summary.senderDisplayName) wrote:\n\(quoted)",
            inReplyTo: message.summary.messageID,
            references: references
        )
    }

    func newCompose() {
        let preferredID = selection?.accountID
        let accountID = preferredID.flatMap { id in
            runtimes.first(where: { $0.id == id && $0.account.provider != .local })?.id
        } ?? runtimes.first(where: {
            $0.account.provider != .local && !$0.account.isDemo
        })?.id ?? runtimes.first(where: {
            $0.account.provider != .local
        })?.id

        guard let accountID else {
            flash("Add a mail account to compose a message.")
            return
        }
        compose = ComposeDraft(accountID: accountID)
    }

    // MARK: - Send

    func send(_ draft: ComposeDraft) async -> Bool {
        guard let account = runtimes.first(where: { $0.id == draft.accountID })?.account else {
            errorMessage = "The selected account is no longer available."
            return false
        }

        let to = EmailAddress.parseList(draft.to)
        let cc = EmailAddress.parseList(draft.cc)
        let bcc = EmailAddress.parseList(draft.bcc)

        guard !to.isEmpty || !cc.isEmpty || !bcc.isEmpty else {
            errorMessage = "Add at least one recipient."
            return false
        }

        let outgoing = OutgoingMessage(
            from: account.fromAddress,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: draft.subject,
            text: draft.body,
            attachments: draft.attachments,
            inReplyTo: draft.inReplyTo,
            references: draft.references
        )

        do {
            let service = try service(for: draft.accountID)
            try await service.send(outgoing)
            compose = nil
            flash("Message sent")
            if selection?.accountID == draft.accountID {
                await loadMailboxes(for: draft.accountID)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Account editing

    func saveAccount(_ account: MailAccount, password: String?) async throws {
        if hostAccountIDs.contains(account.id) {
            throw MailError.notConfigured(
                "This account is managed by the host server. Change it in the host configuration."
            )
        }
        if let password, !password.isEmpty {
            try credentials.setPassword(password, for: account.id)
        }

        var accounts = runtimes.map(\.account)
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        try accountStore.save(accounts)

        if let existing = services[account.id] {
            await existing.close()
        }
        services[account.id] = nil

        if let index = runtimes.firstIndex(where: { $0.id == account.id }) {
            runtimes[index] = AccountRuntime(
                account: account,
                mailboxes: runtimes[index].mailboxes,
                isLoadingMailboxes: true,
                error: nil
            )
        } else {
            runtimes.append(AccountRuntime(account: account))
        }

        await loadMailboxes(for: account.id)
        if selection?.accountID == account.id {
            await loadMessages(preserveSelection: true)
        }
    }

    func deleteAccount(_ accountID: UUID) async {
        if hostAccountIDs.contains(accountID) {
            flash("This account is managed by the host server.")
            return
        }
        await services[accountID]?.close()
        services[accountID] = nil
        try? credentials.deletePassword(for: accountID)

        runtimes.removeAll { $0.id == accountID }
        try? database.deleteAccount(id: accountID)
        if selection?.accountID == accountID {
            selection = nil
            messages = []
            selectedMessageID = nil
            currentMessage = nil
            selectDefaultMailbox()
        }

        try? accountStore.save(runtimes.map(\.account))
    }

    func passwordForEditing(_ accountID: UUID) -> String {
        (try? credentials.password(for: accountID)) ?? ""
    }

    func testAccount(_ account: MailAccount, password: String) async throws -> Int {
        if account.isDemo {
            let service = DemoMailService()
            return try await service.listMailboxes().count
        }
        if hostAccountIDs.contains(account.id), let hostStore {
            let service = HostMailService(store: hostStore, accountID: account.id)
            return try await service.listMailboxes().count
        }
        if account.provider == .local {
            let service = LocalMailService(database: database, accountID: account.id)
            return try await service.listMailboxes().count
        }
        guard !password.isEmpty else {
            throw MailError.authentication("Enter the account password first.")
        }
        let service = IMAPMailService(account: account, password: password)
        do {
            let boxes = try await service.listMailboxes()
            await service.close()
            return boxes.count
        } catch {
            await service.close()
            throw error
        }
    }

    // MARK: - Helpers

    func service(for accountID: UUID) throws -> any MailService {
        if let existing = services[accountID] {
            return existing
        }
        guard let account = runtimes.first(where: { $0.id == accountID })?.account else {
            throw MailError.notConfigured("That account is no longer available.")
        }

        let service: any MailService
        if account.isDemo {
            service = DemoMailService(database: database)
        } else if hostAccountIDs.contains(accountID), let hostStore {
            service = HostMailService(store: hostStore, accountID: accountID)
        } else if account.provider == .local {
            service = LocalMailService(database: database, accountID: accountID)
        } else {
            guard let password = try credentials.password(for: accountID), !password.isEmpty else {
                throw MailError.authentication(
                    "No password is saved for \(account.emailAddress). Add one in Settings."
                )
            }
            service = IMAPMailService(account: account, password: password)
        }

        services[accountID] = service
        return service
    }

    func accountID(forMailbox path: String) -> UUID? {
        if let selection, selection.mailboxPath == path {
            return selection.accountID
        }
        for runtime in runtimes {
            if runtime.mailboxes.contains(where: { $0.path == path }) {
                return runtime.id
            }
        }
        return nil
    }

    func updateSummary(id: String, _ transform: (inout MessageSummary) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        transform(&messages[index])
    }

    private func removeLocally(id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let next = messages.count > 1
            ? (index + 1 < messages.count ? messages[index + 1].id : messages[index - 1].id)
            : nil
        let removed = messages.remove(at: index)

        if let location = mailboxesIndex(accountID: selection?.accountID ?? UUID(), path: removed.mailbox) {
            runtimes[location.account].mailboxes[location.mailbox].totalCount =
                max(0, runtimes[location.account].mailboxes[location.mailbox].totalCount - 1)
            if removed.isUnread {
                runtimes[location.account].mailboxes[location.mailbox].unreadCount =
                    max(0, runtimes[location.account].mailboxes[location.mailbox].unreadCount - 1)
            }
        }

        if selectedMessageID == id {
            selectedMessageID = next
            currentMessage = nil
        }
    }

    private func neighborID(after id: String) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        if index + 1 < messages.count { return messages[index + 1].id }
        if index > 0 { return messages[index - 1].id }
        return nil
    }

    private func mailboxesIndex(accountID: UUID, path: String) -> (account: Int, mailbox: Int)? {
        guard let accountIndex = runtimes.firstIndex(where: { $0.id == accountID }),
              let mailboxIndex = runtimes[accountIndex].mailboxes.firstIndex(where: { $0.path == path }) else {
            return nil
        }
        return (accountIndex, mailboxIndex)
    }

    func flash(_ text: String) {
        statusText = text
        clearStatusTask?.cancel()
        clearStatusTask = Task {
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            statusText = nil
        }
    }
}
