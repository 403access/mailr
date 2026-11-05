import Foundation
import Security

// MARK: - Service protocol

public protocol MailService: Sendable {
    func listMailboxes() async throws -> [Mailbox]
    func fetchMessages(mailbox: String, limit: Int) async throws -> [MessageSummary]
    func fetchMessage(mailbox: String, uid: UInt32) async throws -> MailMessage
    func setFlags(mailbox: String, uid: UInt32, flags: Set<MessageFlag>, enabled: Bool) async throws
    func move(mailbox: String, uid: UInt32, to destination: String) async throws
    func delete(mailbox: String, uid: UInt32) async throws
    func send(_ message: OutgoingMessage) async throws
    func close() async
}

// MARK: - Account persistence

/// Account persistence backed by the shared synchronous SQLite database.
///
/// The `fileURL` initializer is kept for tests and tools; the database file
/// stores accounts alongside mailboxes, messages, bodies, and attachments.
public struct AccountStore: Sendable {
    public let database: MailDatabase

    public var fileURL: URL {
        database.fileURL ?? MailDatabase.defaultURL
    }

    public init(fileURL: URL? = nil) {
        self.database = MailDatabase(fileURL: fileURL)
    }

    public func load() throws -> [MailAccount] {
        try database.loadAccounts()
    }

    public func save(_ accounts: [MailAccount]) throws {
        try database.saveAccounts(accounts)
    }
}

// MARK: - Credentials

public protocol CredentialStore: Sendable {
    func password(for accountID: UUID) throws -> String?
    func setPassword(_ password: String, for accountID: UUID) throws
    func deletePassword(for accountID: UUID) throws
}

public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "com.mailr.credentials") {
        self.service = service
    }

    public func password(for accountID: UUID) throws -> String? {
        var query = baseQuery(accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
                return nil
            }
            return password
        case errSecItemNotFound:
            return nil
        default:
            throw MailError.notConfigured("Could not read the password from Keychain (status \(status)).")
        }
    }

    public func setPassword(_ password: String, for accountID: UUID) throws {
        let data = Data(password.utf8)
        var query = baseQuery(accountID)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw MailError.notConfigured("Could not update the Keychain item (status \(updateStatus)).")
        }

        query[kSecValueData as String] = data
        query[kSecAttrLabel as String] = "Mailr account password"
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MailError.notConfigured("Could not save the password to Keychain (status \(addStatus)).")
        }
    }

    public func deletePassword(for accountID: UUID) throws {
        let status = SecItemDelete(baseQuery(accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MailError.notConfigured("Could not remove the Keychain item (status \(status)).")
        }
    }

    private func baseQuery(_ accountID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString
        ]
    }
}

public struct InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var values: [UUID: String] = [:]
    }

    private let storage = Storage()

    public init() {}

    public func password(for accountID: UUID) throws -> String? {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.values[accountID]
    }

    public func setPassword(_ password: String, for accountID: UUID) throws {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        storage.values[accountID] = password
    }

    public func deletePassword(for accountID: UUID) throws {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        storage.values.removeValue(forKey: accountID)
    }
}
