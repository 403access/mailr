import Foundation
import SQLite3

// MARK: - Errors

public enum MailDatabaseError: LocalizedError, Sendable {
    case openFailed(String)
    case statementFailed(String)
    case bindingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let detail): "Could not open the mail database: \(detail)"
        case .statementFailed(let detail): "The mail database rejected a statement: \(detail)"
        case .bindingFailed(let detail): "Could not bind a value to the mail database: \(detail)"
        }
    }
}

// MARK: - Database

/// A small, synchronous SQLite store for accounts, mailboxes, message
/// summaries, bodies, and attachments.
///
/// Every public method is blocking. The database is serialized with a
/// recursive lock, so it is safe to call from any thread, including the main
/// actor for small reads and writes.
public final class MailDatabase: @unchecked Sendable {
    public let fileURL: URL?

    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?
    private var openError: (any Error)?
    private var opened = false

    /// Opens (or creates) a database at the supplied file URL.
    /// Passing `nil` uses `Application Support/Mailr/mailr.sqlite3`.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
    }

    /// Creates a private in-memory database, useful for tests and previews.
    public init(inMemory: Bool) {
        precondition(inMemory, "Use init(fileURL:) for a persistent database.")
        self.fileURL = nil
    }

    deinit {
        sqlite3_close(handle)
    }

    public static var defaultURL: URL {
        let base: URL
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            base = support
        } else {
            base = FileManager.default.temporaryDirectory
        }
        return base
            .appendingPathComponent("Mailr", isDirectory: true)
            .appendingPathComponent("mailr.sqlite3")
    }

    /// The database used by the host archive server. It is deliberately
    /// separate from the client cache so the server can keep mail the client
    /// has since removed (or that the mailbox no longer exposes).
    public static var hostURL: URL {
        defaultURL
            .deletingLastPathComponent()
            .appendingPathComponent("host-mail.sqlite3")
    }

    // MARK: Opening

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try ensureOpenLocked()
        guard let handle else {
            throw MailDatabaseError.openFailed("The database is not available.")
        }
        return try body(handle)
    }

    private func ensureOpenLocked() throws {
        if opened {
            if let openError { throw openError }
            return
        }
        opened = true
        do {
            try openLocked()
        } catch {
            openError = error
            throw error
        }
    }

    private func openLocked() throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let path: String
        if let fileURL {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            path = fileURL.path
        } else {
            path = ":memory:"
        }

        var database: OpaquePointer?
        let status = sqlite3_open_v2(path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(database)
            throw MailDatabaseError.openFailed(message)
        }
        handle = database
        sqlite3_busy_timeout(database, 5_000)

        if let fileURL {
            // Mail data is private; keep the database readable only by the user.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fileURL.deletingLastPathComponent().path
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        }

        try execLocked("PRAGMA journal_mode = WAL;")
        try execLocked("PRAGMA synchronous = NORMAL;")

        try createSchemaLocked()
        try migrateLegacyAccountsLocked()
    }

    private func execLocked(_ sql: String) throws {
        guard let handle else { return }
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(message)
            throw MailDatabaseError.statementFailed(detail)
        }
    }

    private func createSchemaLocked() throws {
        try execLocked("""
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS accounts (
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            email_address TEXT NOT NULL,
            provider TEXT NOT NULL,
            incoming_host TEXT NOT NULL,
            incoming_port INTEGER NOT NULL,
            incoming_security TEXT NOT NULL,
            incoming_username TEXT NOT NULL,
            outgoing_host TEXT NOT NULL,
            outgoing_port INTEGER NOT NULL,
            outgoing_security TEXT NOT NULL,
            outgoing_username TEXT NOT NULL,
            is_demo INTEGER NOT NULL DEFAULT 0,
            sort_index INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS mailboxes (
            account_id TEXT NOT NULL,
            path TEXT NOT NULL,
            name TEXT NOT NULL,
            role TEXT NOT NULL,
            delimiter TEXT,
            unread_count INTEGER NOT NULL DEFAULT 0,
            total_count INTEGER NOT NULL DEFAULT 0,
            sort_index INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (account_id, path)
        );

        CREATE TABLE IF NOT EXISTS messages (
            account_id TEXT NOT NULL,
            mailbox TEXT NOT NULL,
            uid INTEGER NOT NULL,
            subject TEXT NOT NULL,
            from_json TEXT NOT NULL,
            to_json TEXT NOT NULL,
            cc_json TEXT NOT NULL,
            date REAL NOT NULL,
            snippet TEXT NOT NULL,
            size INTEGER NOT NULL DEFAULT 0,
            is_read INTEGER NOT NULL DEFAULT 0,
            is_flagged INTEGER NOT NULL DEFAULT 0,
            is_answered INTEGER NOT NULL DEFAULT 0,
            has_attachments INTEGER NOT NULL DEFAULT 0,
            message_id TEXT,
            in_reply_to TEXT,
            references_json TEXT NOT NULL DEFAULT '[]',
            on_mailbox INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (account_id, mailbox, uid)
        );

        CREATE INDEX IF NOT EXISTS idx_messages_mailbox
            ON messages(account_id, mailbox, date DESC);

        CREATE TABLE IF NOT EXISTS message_bodies (
            account_id TEXT NOT NULL,
            mailbox TEXT NOT NULL,
            uid INTEGER NOT NULL,
            text TEXT,
            html TEXT,
            PRIMARY KEY (account_id, mailbox, uid)
        );

        CREATE TABLE IF NOT EXISTS attachments (
            account_id TEXT NOT NULL,
            mailbox TEXT NOT NULL,
            uid INTEGER NOT NULL,
            attachment_id TEXT NOT NULL,
            filename TEXT NOT NULL,
            mime_type TEXT NOT NULL,
            data BLOB NOT NULL,
            is_inline INTEGER NOT NULL DEFAULT 0,
            content_id TEXT,
            sort_index INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (account_id, mailbox, uid, attachment_id)
        );
        """)

        // Databases created by interim builds may predate the count columns.
        // The statements fail harmlessly when the columns already exist.
        try? execLocked("ALTER TABLE mailboxes ADD COLUMN unread_count INTEGER NOT NULL DEFAULT 0;")
        try? execLocked("ALTER TABLE mailboxes ADD COLUMN total_count INTEGER NOT NULL DEFAULT 0;")
        try? execLocked("ALTER TABLE messages ADD COLUMN on_mailbox INTEGER NOT NULL DEFAULT 1;")
    }

    /// Imports the pre-SQLite `accounts.json` file once and renames it so it is
    /// not imported again.
    private func migrateLegacyAccountsLocked() throws {
        guard let fileURL, fileURL.lastPathComponent != "accounts.json" else { return }
        if (try? metaValueLocked("legacy_accounts_json")) == "1" { return }

        let legacyURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("accounts.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            try? setMetaLocked("legacy_accounts_json", "1")
            return
        }

        if let data = try? Data(contentsOf: legacyURL),
           let accounts = try? JSONDecoder().decode([MailAccount].self, from: data) {
            try saveAccountsLocked(accounts)
        }

        try? setMetaLocked("legacy_accounts_json", "1")
        try? FileManager.default.moveItem(
            at: legacyURL,
            to: legacyURL.appendingPathExtension("migrated")
        )
    }

    private func metaValueLocked(_ key: String) throws -> String? {
        try withDatabase { database in
            let statement = try prepare(database, "SELECT value FROM meta WHERE key = ? LIMIT 1;")
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, key)
            guard try step(statement) else { return nil }
            return text(statement, 0)
        }
    }

    private func setMetaLocked(_ key: String, _ value: String) throws {
        try withDatabase { database in
            let statement = try prepare(database, """
            INSERT INTO meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, key)
            bind(statement, 2, value)
            try run(statement)
        }
    }

    // MARK: Accounts

    public func loadAccounts() throws -> [MailAccount] {
        try withDatabase { database in
            let statement = try prepare(database, """
            SELECT id, display_name, email_address, provider,
                   incoming_host, incoming_port, incoming_security, incoming_username,
                   outgoing_host, outgoing_port, outgoing_security, outgoing_username,
                   is_demo
            FROM accounts
            ORDER BY sort_index ASC, display_name ASC;
            """)
            defer { sqlite3_finalize(statement) }

            var accounts: [MailAccount] = []
            while try step(statement) {
                guard let id = UUID(uuidString: text(statement, 0) ?? "") else { continue }
                accounts.append(MailAccount(
                    id: id,
                    displayName: text(statement, 1) ?? "",
                    emailAddress: text(statement, 2) ?? "",
                    provider: ProviderKind(rawValue: text(statement, 3) ?? "") ?? .custom,
                    incoming: ServerSettings(
                        host: text(statement, 4) ?? "",
                        port: Int(sqlite3_column_int64(statement, 5)),
                        security: ServerSecurity(rawValue: text(statement, 6) ?? "") ?? .tls,
                        username: text(statement, 7) ?? ""
                    ),
                    outgoing: ServerSettings(
                        host: text(statement, 8) ?? "",
                        port: Int(sqlite3_column_int64(statement, 9)),
                        security: ServerSecurity(rawValue: text(statement, 10) ?? "") ?? .tls,
                        username: text(statement, 11) ?? ""
                    ),
                    isDemo: sqlite3_column_int(statement, 12) != 0
                ))
            }
            return accounts
        }
    }

    public func saveAccounts(_ accounts: [MailAccount]) throws {
        try withDatabase { _ in
            try saveAccountsLocked(accounts)
        }
    }

    private func saveAccountsLocked(_ accounts: [MailAccount]) throws {
        try transactionLocked {
            let keep = Set(accounts.map(\.id.uuidString))
            let existing = try accountIDsLocked()
            for id in existing where !keep.contains(id) {
                try deleteAccountLocked(id)
            }

            for (index, account) in accounts.enumerated() {
                let sql = """
                INSERT INTO accounts (
                    id, display_name, email_address, provider,
                    incoming_host, incoming_port, incoming_security, incoming_username,
                    outgoing_host, outgoing_port, outgoing_security, outgoing_username,
                    is_demo, sort_index
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    display_name = excluded.display_name,
                    email_address = excluded.email_address,
                    provider = excluded.provider,
                    incoming_host = excluded.incoming_host,
                    incoming_port = excluded.incoming_port,
                    incoming_security = excluded.incoming_security,
                    incoming_username = excluded.incoming_username,
                    outgoing_host = excluded.outgoing_host,
                    outgoing_port = excluded.outgoing_port,
                    outgoing_security = excluded.outgoing_security,
                    outgoing_username = excluded.outgoing_username,
                    is_demo = excluded.is_demo,
                    sort_index = excluded.sort_index;
                """
                let statement = try prepare(try handleLocked(), sql)
                defer { sqlite3_finalize(statement) }
                bind(statement, 1, account.id.uuidString)
                bind(statement, 2, account.displayName)
                bind(statement, 3, account.emailAddress)
                bind(statement, 4, account.provider.rawValue)
                bind(statement, 5, account.incoming.host)
                sqlite3_bind_int64(statement, 6, Int64(account.incoming.port))
                bind(statement, 7, account.incoming.security.rawValue)
                bind(statement, 8, account.incoming.username)
                bind(statement, 9, account.outgoing.host)
                sqlite3_bind_int64(statement, 10, Int64(account.outgoing.port))
                bind(statement, 11, account.outgoing.security.rawValue)
                bind(statement, 12, account.outgoing.username)
                sqlite3_bind_int(statement, 13, account.isDemo ? 1 : 0)
                sqlite3_bind_int64(statement, 14, Int64(index))
                try run(statement)
            }
        }
    }

    private func accountIDsLocked() throws -> [String] {
        let statement = try prepare(try handleLocked(), "SELECT id FROM accounts;")
        defer { sqlite3_finalize(statement) }
        var ids: [String] = []
        while try step(statement) {
            if let id = text(statement, 0) { ids.append(id) }
        }
        return ids
    }

    public func deleteAccount(id: UUID) throws {
        try withDatabase { _ in
            try deleteAccountLocked(id.uuidString)
        }
    }

    private func deleteAccountLocked(_ id: String) throws {
        let database = try handleLocked()
        for table in ["attachments", "message_bodies", "messages", "mailboxes", "accounts"] {
            let column = table == "accounts" ? "id" : "account_id"
            let statement = try prepare(
                database,
                "DELETE FROM \(table) WHERE \(column) = ?;"
            )
            bind(statement, 1, id)
            try run(statement)
            sqlite3_finalize(statement)
        }
    }

    // MARK: Mailboxes

    /// Loads mailboxes with counts derived from the cached message table so
    /// unread totals stay consistent with what is stored locally.
    public func loadMailboxes(accountID: UUID) throws -> [Mailbox] {
        try withDatabase { database in
            let statement = try prepare(database, """
            SELECT path, name, role, delimiter,
                   CASE WHEN EXISTS (
                       SELECT 1 FROM messages m
                       WHERE m.account_id = mailboxes.account_id
                         AND m.mailbox = mailboxes.path
                   )
                   THEN (SELECT COUNT(*) FROM messages m
                         WHERE m.account_id = mailboxes.account_id
                           AND m.mailbox = mailboxes.path
                           AND m.is_read = 0)
                   ELSE unread_count END,
                   CASE WHEN EXISTS (
                       SELECT 1 FROM messages m
                       WHERE m.account_id = mailboxes.account_id
                         AND m.mailbox = mailboxes.path
                   )
                   THEN (SELECT COUNT(*) FROM messages m
                         WHERE m.account_id = mailboxes.account_id
                           AND m.mailbox = mailboxes.path)
                   ELSE total_count END
            FROM mailboxes
            WHERE account_id = ?
            ORDER BY sort_index ASC;
            """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, accountID.uuidString)

            var boxes: [Mailbox] = []
            while try step(statement) {
                boxes.append(Mailbox(
                    path: text(statement, 0) ?? "",
                    name: text(statement, 1) ?? "",
                    role: MailboxRole(rawValue: text(statement, 2) ?? "") ?? .other,
                    delimiter: text(statement, 3),
                    unreadCount: Int(sqlite3_column_int64(statement, 4)),
                    totalCount: Int(sqlite3_column_int64(statement, 5))
                ))
            }
            return boxes
        }
    }

    public func saveMailboxes(_ mailboxes: [Mailbox], accountID: UUID) throws {
        try withDatabase { _ in
            try transactionLocked {
                let database = try handleLocked()
                let delete = try prepare(database, "DELETE FROM mailboxes WHERE account_id = ?;")
                bind(delete, 1, accountID.uuidString)
                try run(delete)
                sqlite3_finalize(delete)

                for (index, box) in mailboxes.enumerated() {
                    let statement = try prepare(database, """
                    INSERT INTO mailboxes (
                        account_id, path, name, role, delimiter,
                        unread_count, total_count, sort_index
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                    """)
                    defer { sqlite3_finalize(statement) }
                    bind(statement, 1, accountID.uuidString)
                    bind(statement, 2, box.path)
                    bind(statement, 3, box.name)
                    bind(statement, 4, box.role.rawValue)
                    bind(statement, 5, box.delimiter)
                    sqlite3_bind_int64(statement, 6, Int64(box.unreadCount))
                    sqlite3_bind_int64(statement, 7, Int64(box.totalCount))
                    sqlite3_bind_int64(statement, 8, Int64(index))
                    try run(statement)
                }
            }
        }
    }

    // MARK: Messages

    public func loadMessages(
        accountID: UUID,
        mailbox: String,
        limit: Int = 100
    ) throws -> [MessageSummary] {
        try withDatabase { database in
            let statement = try prepare(database, """
            SELECT uid, mailbox, subject, from_json, to_json, cc_json, date, snippet,
                   size, is_read, is_flagged, is_answered, has_attachments,
                   message_id, in_reply_to, references_json, on_mailbox
            FROM messages
            WHERE account_id = ? AND mailbox = ?
            ORDER BY date DESC
            LIMIT ?;
            """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, accountID.uuidString)
            bind(statement, 2, mailbox)
            sqlite3_bind_int64(statement, 3, Int64(max(0, limit)))

            var messages: [MessageSummary] = []
            while try step(statement) {
                messages.append(messageSummary(from: statement))
            }
            return messages
        }
    }

    public func upsertMessages(_ messages: [MessageSummary], accountID: UUID) throws {
        try withDatabase { _ in
            try transactionLocked {
                for message in messages {
                    try upsertSummaryLocked(message, accountID: accountID)
                }
            }
        }
    }

    /// Replaces the locally cached list for a mailbox, removing messages the
    /// server no longer reports (for example after a deletion elsewhere).
    public func replaceMessages(
        _ messages: [MessageSummary],
        accountID: UUID,
        mailbox: String
    ) throws {
        try withDatabase { _ in
            try transactionLocked {
                for message in messages {
                    try upsertSummaryLocked(message, accountID: accountID)
                }

                let database = try handleLocked()
                let statement: OpaquePointer
                if messages.isEmpty {
                    // Keep host-only rows: they are not part of the live
                    // mailbox list, but the host archive may still hold them.
                    statement = try prepare(
                        database,
                        "DELETE FROM messages WHERE account_id = ? AND mailbox = ? AND on_mailbox = 1;"
                    )
                    bind(statement, 1, accountID.uuidString)
                    bind(statement, 2, mailbox)
                } else {
                    let placeholders = Array(repeating: "?", count: messages.count).joined(separator: ", ")
                    statement = try prepare(database, """
                    DELETE FROM messages
                    WHERE account_id = ? AND mailbox = ? AND on_mailbox = 1
                      AND uid NOT IN (\(placeholders));
                    """)
                    bind(statement, 1, accountID.uuidString)
                    bind(statement, 2, mailbox)
                    for (index, message) in messages.enumerated() {
                        sqlite3_bind_int64(statement, Int32(index + 3), Int64(message.uid))
                    }
                }
                try run(statement)
                sqlite3_finalize(statement)

                // Bodies and attachments for removed summaries are no longer reachable.
                try pruneChildrenLocked(accountID: accountID, mailbox: mailbox)
            }
        }
    }

    /// Atomically replaces a mailbox with complete messages. Used by local
    /// imports, where the database is the only source of truth.
    public func replaceMailbox(
        _ messages: [MailMessage],
        accountID: UUID,
        mailbox: String
    ) throws {
        try withDatabase { database in
            try transactionLocked {
                for table in ["attachments", "message_bodies", "messages"] {
                    let statement = try prepare(database, """
                    DELETE FROM \(table)
                    WHERE account_id = ? AND mailbox = ?;
                    """)
                    bind(statement, 1, accountID.uuidString)
                    bind(statement, 2, mailbox)
                    try run(statement)
                    sqlite3_finalize(statement)
                }

                for message in messages {
                    try saveMessageLocked(message, accountID: accountID, database: database)
                }
            }
        }
    }

    /// Deletes a mailbox and everything cached for it.
    public func deleteMailbox(accountID: UUID, mailbox: String) throws {
        try withDatabase { _ in
            try transactionLocked {
                let database = try handleLocked()
                for table in ["attachments", "message_bodies", "messages"] {
                    let statement = try prepare(database, """
                    DELETE FROM \(table)
                    WHERE account_id = ? AND mailbox = ?;
                    """)
                    bind(statement, 1, accountID.uuidString)
                    bind(statement, 2, mailbox)
                    try run(statement)
                    sqlite3_finalize(statement)
                }

                let boxes = try prepare(
                    database,
                    "DELETE FROM mailboxes WHERE account_id = ? AND path = ?;"
                )
                bind(boxes, 1, accountID.uuidString)
                bind(boxes, 2, mailbox)
                try run(boxes)
                sqlite3_finalize(boxes)
            }
        }
    }

    /// Records a mailbox snapshot on the host archive.
    ///
    /// Messages in `messages` are known to be present in the actual mailbox.
    /// UIDs in `absentUIDs` were previously archived but are no longer visible
    /// in the mailbox window, so they become host-only. Summaries that are not
    /// part of the snapshot are intentionally left untouched: the client only
    /// fetches a window of the newest messages, and older archived mail must
    /// not be treated as deleted just because it fell outside that window.
    public func syncMailbox(
        _ messages: [MessageSummary],
        accountID: UUID,
        mailbox: String,
        absentUIDs: [UInt32] = []
    ) throws {
        try withDatabase { _ in
            try transactionLocked {
                for message in messages {
                    var visible = message
                    visible.isOnMailbox = true
                    try upsertSummaryLocked(visible, accountID: accountID)
                }

                let database = try handleLocked()
                for uid in absentUIDs {
                    let statement = try prepare(database, """
                    UPDATE messages SET on_mailbox = 0
                    WHERE account_id = ? AND mailbox = ? AND uid = ?;
                    """)
                    bind(statement, 1, accountID.uuidString)
                    bind(statement, 2, mailbox)
                    sqlite3_bind_int64(statement, 3, Int64(uid))
                    try run(statement)
                    sqlite3_finalize(statement)
                }
            }
        }
    }

    /// Marks one or more messages as present in, or absent from, the actual
    /// mailbox without changing any other stored field.
    public func markOnMailbox(
        accountID: UUID,
        mailbox: String,
        uids: [UInt32],
        onMailbox: Bool
    ) throws {
        guard !uids.isEmpty else { return }
        try withDatabase { database in
            try transactionLocked {
                for uid in uids {
                    let statement = try prepare(database, """
                    UPDATE messages SET on_mailbox = ?
                    WHERE account_id = ? AND mailbox = ? AND uid = ?;
                    """)
                    sqlite3_bind_int(statement, 1, onMailbox ? 1 : 0)
                    bind(statement, 2, accountID.uuidString)
                    bind(statement, 3, mailbox)
                    sqlite3_bind_int64(statement, 4, Int64(uid))
                    try run(statement)
                    sqlite3_finalize(statement)
                }
            }
        }
    }

    /// Whether the archive holds a summary for this message.
    public func hasMessage(accountID: UUID, mailbox: String, uid: UInt32) throws -> Bool {
        try withDatabase { database in
            let statement = try prepare(database, """
            SELECT 1 FROM messages
            WHERE account_id = ? AND mailbox = ? AND uid = ?
            LIMIT 1;
            """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, accountID.uuidString)
            bind(statement, 2, mailbox)
            sqlite3_bind_int64(statement, 3, Int64(uid))
            return try step(statement)
        }
    }

    /// Whether a body row exists for this message. Headers and summaries can
    /// be archived before the full message has been downloaded.
    public func hasBody(accountID: UUID, mailbox: String, uid: UInt32) throws -> Bool {
        try withDatabase { database in
            let statement = try prepare(database, """
            SELECT 1 FROM message_bodies
            WHERE account_id = ? AND mailbox = ? AND uid = ?
            LIMIT 1;
            """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, accountID.uuidString)
            bind(statement, 2, mailbox)
            sqlite3_bind_int64(statement, 3, Int64(uid))
            return try step(statement)
        }
    }

    /// The stored mailbox-presence flag, or `nil` when the message is unknown.
    public func isOnMailbox(accountID: UUID, mailbox: String, uid: UInt32) throws -> Bool? {
        try withDatabase { database in
            let statement = try prepare(database, """
            SELECT on_mailbox FROM messages
            WHERE account_id = ? AND mailbox = ? AND uid = ?
            LIMIT 1;
            """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, accountID.uuidString)
            bind(statement, 2, mailbox)
            sqlite3_bind_int64(statement, 3, Int64(uid))
            guard try step(statement) else { return nil }
            return sqlite3_column_int(statement, 0) != 0
        }
    }

    /// Total number of archived message summaries (used by the host server's
    /// health endpoint).
    public func messageCount() throws -> Int {
        try withDatabase { database in
            let statement = try prepare(database, "SELECT COUNT(*) FROM messages;")
            defer { sqlite3_finalize(statement) }
            guard try step(statement) else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func pruneChildrenLocked(accountID: UUID, mailbox: String) throws {
        let database = try handleLocked()
        for table in ["attachments", "message_bodies"] {
            let statement = try prepare(database, """
            DELETE FROM \(table)
            WHERE account_id = ? AND mailbox = ?
              AND uid NOT IN (
                SELECT uid FROM messages WHERE account_id = ? AND mailbox = ?
              );
            """)
            bind(statement, 1, accountID.uuidString)
            bind(statement, 2, mailbox)
            bind(statement, 3, accountID.uuidString)
            bind(statement, 4, mailbox)
            try run(statement)
            sqlite3_finalize(statement)
        }
    }

    private func upsertSummaryLocked(_ message: MessageSummary, accountID: UUID) throws {
        let statement = try prepare(try handleLocked(), """
        INSERT INTO messages (
            account_id, mailbox, uid, subject, from_json, to_json, cc_json, date,
            snippet, size, is_read, is_flagged, is_answered, has_attachments,
            message_id, in_reply_to, references_json, on_mailbox
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(account_id, mailbox, uid) DO UPDATE SET
            subject = excluded.subject,
            from_json = excluded.from_json,
            to_json = excluded.to_json,
            cc_json = excluded.cc_json,
            date = excluded.date,
            snippet = excluded.snippet,
            size = excluded.size,
            is_read = excluded.is_read,
            is_flagged = excluded.is_flagged,
            is_answered = excluded.is_answered,
            has_attachments = excluded.has_attachments,
            message_id = excluded.message_id,
            in_reply_to = excluded.in_reply_to,
            references_json = excluded.references_json,
            on_mailbox = excluded.on_mailbox;
        """)
        defer { sqlite3_finalize(statement) }

        bind(statement, 1, accountID.uuidString)
        bind(statement, 2, message.mailbox)
        sqlite3_bind_int64(statement, 3, Int64(message.uid))
        bind(statement, 4, message.subject)
        bind(statement, 5, try encode(message.from))
        bind(statement, 6, try encode(message.to))
        bind(statement, 7, try encode(message.cc))
        sqlite3_bind_double(statement, 8, message.date.timeIntervalSince1970)
        bind(statement, 9, message.snippet)
        sqlite3_bind_int64(statement, 10, Int64(message.size))
        sqlite3_bind_int(statement, 11, message.isRead ? 1 : 0)
        sqlite3_bind_int(statement, 12, message.isFlagged ? 1 : 0)
        sqlite3_bind_int(statement, 13, message.isAnswered ? 1 : 0)
        sqlite3_bind_int(statement, 14, message.hasAttachments ? 1 : 0)
        bind(statement, 15, message.messageID)
        bind(statement, 16, message.inReplyTo)
        bind(statement, 17, try encode(message.references))
        sqlite3_bind_int(statement, 18, message.isOnMailbox ? 1 : 0)
        try run(statement)
    }

    public func saveMessage(_ message: MailMessage, accountID: UUID) throws {
        try withDatabase { database in
            try transactionLocked {
                try saveMessageLocked(message, accountID: accountID, database: database)
            }
        }
    }

    /// Saves many complete messages in one transaction. Local mail imports use
    /// this to avoid one transaction per message.
    public func saveMessages(_ messages: [MailMessage], accountID: UUID) throws {
        guard !messages.isEmpty else { return }
        try withDatabase { database in
            try transactionLocked {
                for message in messages {
                    try saveMessageLocked(message, accountID: accountID, database: database)
                }
            }
        }
    }

    private func saveMessageLocked(
        _ message: MailMessage,
        accountID: UUID,
        database: OpaquePointer
    ) throws {
        try upsertSummaryLocked(message.summary, accountID: accountID)

        let body = try prepare(database, """
        INSERT INTO message_bodies (account_id, mailbox, uid, text, html)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(account_id, mailbox, uid) DO UPDATE SET
            text = excluded.text,
            html = excluded.html;
        """)
        bind(body, 1, accountID.uuidString)
        bind(body, 2, message.summary.mailbox)
        sqlite3_bind_int64(body, 3, Int64(message.summary.uid))
        bind(body, 4, message.text)
        bind(body, 5, message.html)
        try run(body)
        sqlite3_finalize(body)

        let clear = try prepare(
            database,
            "DELETE FROM attachments WHERE account_id = ? AND mailbox = ? AND uid = ?;"
        )
        bind(clear, 1, accountID.uuidString)
        bind(clear, 2, message.summary.mailbox)
        sqlite3_bind_int64(clear, 3, Int64(message.summary.uid))
        try run(clear)
        sqlite3_finalize(clear)

        for (index, attachment) in message.attachments.enumerated() {
            let statement = try prepare(database, """
            INSERT INTO attachments (
                account_id, mailbox, uid, attachment_id, filename,
                mime_type, data, is_inline, content_id, sort_index
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """)
            bind(statement, 1, accountID.uuidString)
            bind(statement, 2, message.summary.mailbox)
            sqlite3_bind_int64(statement, 3, Int64(message.summary.uid))
            bind(statement, 4, attachment.id.uuidString)
            bind(statement, 5, attachment.filename)
            bind(statement, 6, attachment.mimeType)
            bindBlob(statement, 7, attachment.data)
            sqlite3_bind_int(statement, 8, attachment.isInline ? 1 : 0)
            bind(statement, 9, attachment.contentID)
            sqlite3_bind_int64(statement, 10, Int64(index))
            try run(statement)
            sqlite3_finalize(statement)
        }
    }

    public func loadMessage(
        accountID: UUID,
        mailbox: String,
        uid: UInt32
    ) throws -> MailMessage? {
        try withDatabase { database in
            let statement = try prepare(database, """
            SELECT uid, mailbox, subject, from_json, to_json, cc_json, date, snippet,
                   size, is_read, is_flagged, is_answered, has_attachments,
                   message_id, in_reply_to, references_json, on_mailbox
            FROM messages
            WHERE account_id = ? AND mailbox = ? AND uid = ?
            LIMIT 1;
            """)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, accountID.uuidString)
            bind(statement, 2, mailbox)
            sqlite3_bind_int64(statement, 3, Int64(uid))
            guard try step(statement) else { return nil }
            let summary = messageSummary(from: statement)

            var bodyText: String?
            var bodyHTML: String?
            let body = try prepare(database, """
            SELECT text, html FROM message_bodies
            WHERE account_id = ? AND mailbox = ? AND uid = ?
            LIMIT 1;
            """)
            bind(body, 1, accountID.uuidString)
            bind(body, 2, mailbox)
            sqlite3_bind_int64(body, 3, Int64(uid))
            if try step(body) {
                bodyText = text(body, 0)
                bodyHTML = text(body, 1)
            }
            sqlite3_finalize(body)

            let attachments = try prepare(database, """
            SELECT attachment_id, filename, mime_type, data, is_inline, content_id
            FROM attachments
            WHERE account_id = ? AND mailbox = ? AND uid = ?
            ORDER BY sort_index ASC;
            """)
            defer { sqlite3_finalize(attachments) }
            bind(attachments, 1, accountID.uuidString)
            bind(attachments, 2, mailbox)
            sqlite3_bind_int64(attachments, 3, Int64(uid))

            var files: [MailAttachment] = []
            while try step(attachments) {
                files.append(MailAttachment(
                    id: UUID(uuidString: text(attachments, 0) ?? "") ?? UUID(),
                    filename: text(attachments, 1) ?? "",
                    mimeType: text(attachments, 2) ?? "application/octet-stream",
                    data: blob(attachments, 3),
                    isInline: sqlite3_column_int(attachments, 4) != 0,
                    contentID: text(attachments, 5)
                ))
            }

            return MailMessage(
                summary: summary,
                text: bodyText,
                html: bodyHTML,
                attachments: files
            )
        }
    }

    public func deleteMessage(accountID: UUID, mailbox: String, uid: UInt32) throws {
        try withDatabase { _ in
            try transactionLocked {
                let database = try handleLocked()
                for table in ["attachments", "message_bodies", "messages"] {
                    let statement = try prepare(database, """
                    DELETE FROM \(table)
                    WHERE account_id = ? AND mailbox = ? AND uid = ?;
                    """)
                    bind(statement, 1, accountID.uuidString)
                    bind(statement, 2, mailbox)
                    sqlite3_bind_int64(statement, 3, Int64(uid))
                    try run(statement)
                    sqlite3_finalize(statement)
                }
            }
        }
    }

    @discardableResult
    public func moveMessage(
        accountID: UUID,
        from source: String,
        uid: UInt32,
        to destination: String
    ) throws -> MessageSummary? {
        try withDatabase { _ in
            try transactionLocked {
                let database = try handleLocked()
                for table in ["messages", "message_bodies", "attachments"] {
                    let statement = try prepare(database, """
                    UPDATE \(table) SET mailbox = ?
                    WHERE account_id = ? AND mailbox = ? AND uid = ?;
                    """)
                    bind(statement, 1, destination)
                    bind(statement, 2, accountID.uuidString)
                    bind(statement, 3, source)
                    sqlite3_bind_int64(statement, 4, Int64(uid))
                    try run(statement)
                    sqlite3_finalize(statement)
                }
                let fetch = try prepare(database, """
                SELECT uid, mailbox, subject, from_json, to_json, cc_json, date, snippet,
                       size, is_read, is_flagged, is_answered, has_attachments,
                       message_id, in_reply_to, references_json, on_mailbox
                FROM messages
                WHERE account_id = ? AND mailbox = ? AND uid = ?
                LIMIT 1;
                """)
                defer { sqlite3_finalize(fetch) }
                bind(fetch, 1, accountID.uuidString)
                bind(fetch, 2, destination)
                sqlite3_bind_int64(fetch, 3, Int64(uid))
                guard try step(fetch) else { return nil }
                return messageSummary(from: fetch)
            }
        }
    }

    public func updateFlags(
        accountID: UUID,
        mailbox: String,
        uid: UInt32,
        isRead: Bool? = nil,
        isFlagged: Bool? = nil,
        isAnswered: Bool? = nil
    ) throws {
        try withDatabase { database in
            var assignments: [String] = []
            var values: [Bool] = []
            if let isRead {
                assignments.append("is_read = ?")
                values.append(isRead)
            }
            if let isFlagged {
                assignments.append("is_flagged = ?")
                values.append(isFlagged)
            }
            if let isAnswered {
                assignments.append("is_answered = ?")
                values.append(isAnswered)
            }
            guard !assignments.isEmpty else { return }

            let statement = try prepare(database, """
            UPDATE messages SET \(assignments.joined(separator: ", "))
            WHERE account_id = ? AND mailbox = ? AND uid = ?;
            """)
            defer { sqlite3_finalize(statement) }
            for (index, value) in values.enumerated() {
                sqlite3_bind_int(statement, Int32(index + 1), value ? 1 : 0)
            }
            bind(statement, Int32(values.count + 1), accountID.uuidString)
            bind(statement, Int32(values.count + 2), mailbox)
            sqlite3_bind_int64(statement, Int32(values.count + 3), Int64(uid))
            try run(statement)
        }
    }

    public func maxUID(accountID: UUID) throws -> UInt32 {
        try withDatabase { database in
            let statement = try prepare(
                database,
                "SELECT COALESCE(MAX(uid), 0) FROM messages WHERE account_id = ?;"
            )
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, accountID.uuidString)
            guard try step(statement) else { return 0 }
            return UInt32(clamping: sqlite3_column_int64(statement, 0))
        }
    }

    // MARK: Transactions

    private func transactionLocked<T>(_ body: () throws -> T) throws -> T {
        try execLocked("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let value = try body()
            try execLocked("COMMIT;")
            return value
        } catch {
            try? execLocked("ROLLBACK;")
            throw error
        }
    }

    private func handleLocked() throws -> OpaquePointer {
        guard let handle else {
            throw MailDatabaseError.openFailed("The database is not available.")
        }
        return handle
    }

    // MARK: SQLite helpers

    private func prepare(_ database: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw MailDatabaseError.statementFailed(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws -> Bool {
        let status = sqlite3_step(statement)
        switch status {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw MailDatabaseError.statementFailed(
                String(cString: sqlite3_errmsg(sqlite3_db_handle(statement)))
            )
        }
    }

    private func run(_ statement: OpaquePointer) throws {
        _ = try step(statement)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindBlob(_ statement: OpaquePointer, _ index: Int32, _ data: Data) {
        guard !data.isEmpty else {
            sqlite3_bind_zeroblob(statement, index, 0)
            return
        }
        _ = data.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(raw.count), Self.transient)
        }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func blob(_ statement: OpaquePointer, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: count)
    }

    private func messageSummary(from statement: OpaquePointer) -> MessageSummary {
        MessageSummary(
            uid: UInt32(clamping: sqlite3_column_int64(statement, 0)),
            mailbox: text(statement, 1) ?? "",
            subject: text(statement, 2) ?? "",
            from: (try? decode([EmailAddress].self, text(statement, 3))) ?? [],
            to: (try? decode([EmailAddress].self, text(statement, 4))) ?? [],
            cc: (try? decode([EmailAddress].self, text(statement, 5))) ?? [],
            date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            snippet: text(statement, 7) ?? "",
            size: Int(sqlite3_column_int64(statement, 8)),
            isRead: sqlite3_column_int(statement, 9) != 0,
            isFlagged: sqlite3_column_int(statement, 10) != 0,
            isAnswered: sqlite3_column_int(statement, 11) != 0,
            hasAttachments: sqlite3_column_int(statement, 12) != 0,
            messageID: text(statement, 13),
            inReplyTo: text(statement, 14),
            references: (try? decode([String].self, text(statement, 15))) ?? [],
            isOnMailbox: sqlite3_column_int(statement, 16) != 0
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: String?) throws -> T {
        guard let value, let data = value.data(using: .utf8) else {
            throw MailDatabaseError.bindingFailed("Missing encoded value.")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
