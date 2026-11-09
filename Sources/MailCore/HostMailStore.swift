import Foundation

// MARK: - Configuration

/// Describes where the host archive server is running.
///
/// The server is a small HTTP/JSON process on the host machine. The client
/// mirrors every message it retrieves there, so mail stays readable even after
/// it disappears from (or falls outside) the live IMAP mailbox.
public struct HostMailConfiguration: Hashable, Sendable {
    public var baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// The address used when no configuration is supplied. This works for the
    /// macOS app and the iOS Simulator, which share the host's loopback.
    public static var defaultBaseURL: URL {
        URL(string: "http://127.0.0.1:8787")!
    }

    /// Reads `MAILR_HOST_SERVER` (or `MAILR_HOST_URL`) from the `.env` file
    /// and the process environment. Set it to `off` to disable host syncing.
    ///
    /// Physical iPhones cannot reach the Mac's loopback address; point this at
    /// the Mac's LAN address, for example `http://192.168.1.20:8787`.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidateURLs: [URL]? = nil
    ) -> HostMailConfiguration? {
        var values = environment

        if let found = try? DotEnv.loadFirst(at: candidateURLs ?? EnvironmentAccounts.defaultCandidateURLs()) {
            values = found.dotEnv.merging(overrides: environment).values
        }

        let raw = (values["MAILR_HOST_SERVER"]
            ?? values["MAILR_HOST_URL"]
            ?? values["MAILR_HOST_SERVER_URL"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let raw, !raw.isEmpty else {
            return HostMailConfiguration(baseURL: defaultBaseURL)
        }

        switch raw.lowercased() {
        case "off", "none", "disabled", "false", "0":
            return nil
        default:
            break
        }

        let withScheme = raw.contains("://") ? raw : "http://\(raw)"
        guard var components = URLComponents(string: withScheme),
              components.host != nil else {
            return HostMailConfiguration(baseURL: defaultBaseURL)
        }
        if components.path == "/" {
            components.path = ""
        }
        if components.port == nil {
            components.port = 8787
        }
        guard let url = components.url else {
            return HostMailConfiguration(baseURL: defaultBaseURL)
        }
        return HostMailConfiguration(baseURL: url)
    }

    public var displayAddress: String { baseURL.absoluteString }
}

// MARK: - Errors

public enum HostMailError: LocalizedError, Sendable, Equatable {
    case unavailable(String)
    case invalidResponse
    case server(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            "The host archive is unavailable: \(detail)"
        case .invalidResponse:
            "The host archive returned an invalid response."
        case .server(let status, let message):
            "The host archive returned HTTP \(status): \(message)"
        }
    }
}

// MARK: - Wire types

public struct HostMailHealth: Codable, Sendable, Equatable {
    public var status: String
    public var version: Int
    public var messageCount: Int
    public var databasePath: String

    public init(status: String, version: Int = 1, messageCount: Int, databasePath: String) {
        self.status = status
        self.version = version
        self.messageCount = messageCount
        self.databasePath = databasePath
    }
}

public struct HostMailboxSyncRequest: Codable, Sendable {
    public var accountID: UUID
    public var mailbox: String
    public var messages: [MessageSummary]
    /// Messages that are still in the host archive but were not visible in the
    /// newest mailbox window, so they should be marked host-only.
    public var absentUIDs: [UInt32]

    public init(
        accountID: UUID,
        mailbox: String,
        messages: [MessageSummary],
        absentUIDs: [UInt32] = []
    ) {
        self.accountID = accountID
        self.mailbox = mailbox
        self.messages = messages
        self.absentUIDs = absentUIDs
    }
}

public struct HostMessageEnvelope: Codable, Sendable {
    public var accountID: UUID
    public var message: MailMessage

    public init(accountID: UUID, message: MailMessage) {
        self.accountID = accountID
        self.message = message
    }
}

public struct HostMessageResponse: Codable, Sendable {
    public var message: MailMessage?

    public init(message: MailMessage?) {
        self.message = message
    }
}

public struct HostSyncResponse: Codable, Sendable {
    public var stored: Int

    public init(stored: Int) {
        self.stored = stored
    }
}

public struct HostDeleteResponse: Codable, Sendable {
    public var deleted: Bool

    public init(deleted: Bool) {
        self.deleted = deleted
    }
}

public struct HostMoveRequest: Codable, Sendable {
    public var accountID: UUID
    public var source: String
    public var uid: UInt32
    public var destination: String

    public init(accountID: UUID, source: String, uid: UInt32, destination: String) {
        self.accountID = accountID
        self.source = source
        self.uid = uid
        self.destination = destination
    }
}

public struct HostMoveResponse: Codable, Sendable {
    public var moved: Bool

    public init(moved: Bool) {
        self.moved = moved
    }
}

public struct HostFlagsRequest: Codable, Sendable {
    public var accountID: UUID
    public var mailbox: String
    public var uid: UInt32
    public var isRead: Bool?
    public var isFlagged: Bool?
    public var isAnswered: Bool?

    public init(
        accountID: UUID,
        mailbox: String,
        uid: UInt32,
        isRead: Bool? = nil,
        isFlagged: Bool? = nil,
        isAnswered: Bool? = nil
    ) {
        self.accountID = accountID
        self.mailbox = mailbox
        self.uid = uid
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.isAnswered = isAnswered
    }
}

public struct HostSendRequest: Codable, Sendable {
    public var accountID: UUID
    public var message: OutgoingMessage

    public init(accountID: UUID, message: OutgoingMessage) {
        self.accountID = accountID
        self.message = message
    }
}

public struct HostMailboxListRequest: Codable, Sendable {
    public var accountID: UUID
    public var mailboxes: [Mailbox]

    public init(accountID: UUID, mailboxes: [Mailbox]) {
        self.accountID = accountID
        self.mailboxes = mailboxes
    }
}

public struct HostStorageResponse: Codable, Sendable {
    public var accountID: UUID
    public var mailbox: String
    public var uid: UInt32
    public var onMailbox: Bool
    public var onHost: Bool

    public init(
        accountID: UUID,
        mailbox: String,
        uid: UInt32,
        onMailbox: Bool,
        onHost: Bool
    ) {
        self.accountID = accountID
        self.mailbox = mailbox
        self.uid = uid
        self.onMailbox = onMailbox
        self.onHost = onHost
    }
}

public struct HostErrorResponse: Codable, Sendable {
    public var error: String

    public init(error: String) {
        self.error = error
    }
}

// MARK: - Tagging wire types

public struct HostTagRequest: Codable, Sendable {
    public var tag: MailTag

    public init(tag: MailTag) {
        self.tag = tag
    }
}

public struct HostTaggedMessagesResponse: Codable, Sendable {
    public var messages: [TaggedMessage]

    public init(messages: [TaggedMessage]) {
        self.messages = messages
    }
}

public struct HostMessageTagRequest: Codable, Sendable {
    public var accountID: UUID
    public var mailbox: String
    public var uid: UInt32
    public var tagID: UUID
    public var tagged: Bool

    public init(
        accountID: UUID,
        mailbox: String,
        uid: UInt32,
        tagID: UUID,
        tagged: Bool
    ) {
        self.accountID = accountID
        self.mailbox = mailbox
        self.uid = uid
        self.tagID = tagID
        self.tagged = tagged
    }
}

public struct HostClassifyRequest: Codable, Sendable {
    public var accountID: UUID
    public var mailbox: String
    public var limit: Int
    public var uids: [UInt32]?
    public var force: Bool

    public init(
        accountID: UUID,
        mailbox: String,
        limit: Int = 50,
        uids: [UInt32]? = nil,
        force: Bool = false
    ) {
        self.accountID = accountID
        self.mailbox = mailbox
        self.limit = limit
        self.uids = uids
        self.force = force
    }
}

public struct HostClassifyResponse: Codable, Sendable {
    public var classified: Int
    public var skipped: Int
    public var failed: Int
    public var status: MailClassifierStatus

    public init(
        classified: Int,
        skipped: Int = 0,
        failed: Int = 0,
        status: MailClassifierStatus
    ) {
        self.classified = classified
        self.skipped = skipped
        self.failed = failed
        self.status = status
    }
}

// MARK: - Client protocol

public protocol HostMailStore: Sendable {
    func health() async throws -> HostMailHealth
    func accounts() async throws -> [MailAccount]
    func requestSync() async throws
    func send(_ message: OutgoingMessage, accountID: UUID) async throws
    func mailboxes(accountID: UUID) async throws -> [Mailbox]
    func syncMailbox(
        accountID: UUID,
        mailbox: String,
        messages: [MessageSummary],
        absentUIDs: [UInt32]
    ) async throws
    func mailboxSnapshot(accountID: UUID, mailbox: String, limit: Int) async throws -> [MessageSummary]
    func storeMessage(_ message: MailMessage, accountID: UUID) async throws
    func storedMessage(accountID: UUID, mailbox: String, uid: UInt32) async throws -> MailMessage?
    func storageStatus(accountID: UUID, mailbox: String, uid: UInt32) async throws -> HostStorageResponse?
    func deleteMessage(accountID: UUID, mailbox: String, uid: UInt32) async throws
    func moveMessage(accountID: UUID, from source: String, uid: UInt32, to destination: String) async throws
    func updateFlags(
        accountID: UUID,
        mailbox: String,
        uid: UInt32,
        isRead: Bool?,
        isFlagged: Bool?,
        isAnswered: Bool?
    ) async throws
    func saveMailboxes(_ mailboxes: [Mailbox], accountID: UUID) async throws

    // Tagging. Implementations that predate these routes can keep the default
    // no-op behaviour below.
    func tags() async throws -> [MailTag]
    func saveTag(_ tag: MailTag) async throws
    func deleteTag(id: UUID) async throws
    func taggedMessages(
        accountID: UUID,
        mailbox: String,
        uids: [UInt32]
    ) async throws -> [TaggedMessage]
    func setMessageTag(
        accountID: UUID,
        mailbox: String,
        uid: UInt32,
        tagID: UUID,
        tagged: Bool
    ) async throws
    func classify(
        accountID: UUID,
        mailbox: String,
        limit: Int,
        uids: [UInt32]?,
        force: Bool
    ) async throws -> HostClassifyResponse
    func classifierStatus() async throws -> MailClassifierStatus
}

public extension HostMailStore {
    func tags() async throws -> [MailTag] { [] }
    func saveTag(_ tag: MailTag) async throws {}
    func deleteTag(id: UUID) async throws {}
    func taggedMessages(
        accountID: UUID,
        mailbox: String,
        uids: [UInt32]
    ) async throws -> [TaggedMessage] { [] }
    func setMessageTag(
        accountID: UUID,
        mailbox: String,
        uid: UInt32,
        tagID: UUID,
        tagged: Bool
    ) async throws {}
    func classify(
        accountID: UUID,
        mailbox: String,
        limit: Int,
        uids: [UInt32]?,
        force: Bool
    ) async throws -> HostClassifyResponse {
        HostClassifyResponse(classified: 0, status: .disabled)
    }
    func classifierStatus() async throws -> MailClassifierStatus { .disabled }
}

// MARK: - HTTP client

/// A tiny HTTP/JSON client for ``HostMailServer``.
public struct HTTPHostMailStore: HostMailStore {
    public let configuration: HostMailConfiguration
    private let session: URLSession

    public init(configuration: HostMailConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func health() async throws -> HostMailHealth {
        try await get("health", timeout: 4)
    }

    public func accounts() async throws -> [MailAccount] {
        try await get("v1/accounts")
    }

    public func requestSync() async throws {
        _ = try await send("POST", path: "v1/sync", timeout: 120)
    }

    public func send(_ message: OutgoingMessage, accountID: UUID) async throws {
        let request = HostSendRequest(accountID: accountID, message: message)
        _ = try await send(
            "POST",
            path: "v1/send",
            body: try encode(request),
            timeout: 120
        )
    }

    public func mailboxes(accountID: UUID) async throws -> [Mailbox] {
        try await get(
            "v1/mailboxes",
            query: [URLQueryItem(name: "accountID", value: accountID.uuidString)],
            timeout: 60
        )
    }

    public func syncMailbox(
        accountID: UUID,
        mailbox: String,
        messages: [MessageSummary],
        absentUIDs: [UInt32]
    ) async throws {
        let request = HostMailboxSyncRequest(
            accountID: accountID,
            mailbox: mailbox,
            messages: messages,
            absentUIDs: absentUIDs
        )
        _ = try await send("POST", path: "v1/sync/mailbox", body: try encode(request))
    }

    public func mailboxSnapshot(
        accountID: UUID,
        mailbox: String,
        limit: Int
    ) async throws -> [MessageSummary] {
        try await get(
            "v1/messages/list",
            query: [
                URLQueryItem(name: "accountID", value: accountID.uuidString),
                URLQueryItem(name: "mailbox", value: mailbox),
                URLQueryItem(name: "limit", value: String(limit))
            ],
            timeout: 60
        )
    }

    public func storeMessage(_ message: MailMessage, accountID: UUID) async throws {
        let envelope = HostMessageEnvelope(accountID: accountID, message: message)
        _ = try await send("POST", path: "v1/messages", body: try encode(envelope))
    }

    public func storedMessage(accountID: UUID, mailbox: String, uid: UInt32) async throws -> MailMessage? {
        let response: HostMessageResponse = try await get(
            "v1/messages",
            query: messageQuery(accountID: accountID, mailbox: mailbox, uid: uid),
            timeout: 90
        )
        return response.message
    }

    public func storageStatus(
        accountID: UUID,
        mailbox: String,
        uid: UInt32
    ) async throws -> HostStorageResponse? {
        try await get(
            "v1/storage",
            query: messageQuery(accountID: accountID, mailbox: mailbox, uid: uid)
        )
    }

    public func deleteMessage(accountID: UUID, mailbox: String, uid: UInt32) async throws {
        _ = try await send(
            "DELETE",
            path: "v1/messages",
            query: messageQuery(accountID: accountID, mailbox: mailbox, uid: uid)
        )
    }

    public func moveMessage(
        accountID: UUID,
        from source: String,
        uid: UInt32,
        to destination: String
    ) async throws {
        let request = HostMoveRequest(
            accountID: accountID,
            source: source,
            uid: uid,
            destination: destination
        )
        _ = try await send("POST", path: "v1/move", body: try encode(request))
    }

    public func updateFlags(
        accountID: UUID,
        mailbox: String,
        uid: UInt32,
        isRead: Bool?,
        isFlagged: Bool?,
        isAnswered: Bool?
    ) async throws {
        let request = HostFlagsRequest(
            accountID: accountID,
            mailbox: mailbox,
            uid: uid,
            isRead: isRead,
            isFlagged: isFlagged,
            isAnswered: isAnswered
        )
        _ = try await send("POST", path: "v1/flags", body: try encode(request))
    }

    public func saveMailboxes(_ mailboxes: [Mailbox], accountID: UUID) async throws {
        let request = HostMailboxListRequest(accountID: accountID, mailboxes: mailboxes)
        _ = try await send("POST", path: "v1/mailboxes", body: try encode(request))
    }

    public func tags() async throws -> [MailTag] {
        try await get("v1/tags")
    }

    public func saveTag(_ tag: MailTag) async throws {
        let request = HostTagRequest(tag: tag)
        _ = try await send("POST", path: "v1/tags", body: try encode(request))
    }

    public func deleteTag(id: UUID) async throws {
        _ = try await send(
            "DELETE",
            path: "v1/tags",
            query: [URLQueryItem(name: "id", value: id.uuidString)]
        )
    }

    public func taggedMessages(
        accountID: UUID,
        mailbox: String,
        uids: [UInt32]
    ) async throws -> [TaggedMessage] {
        guard !uids.isEmpty else { return [] }
        let response: HostTaggedMessagesResponse = try await get(
            "v1/messages/tags",
            query: [
                URLQueryItem(name: "accountID", value: accountID.uuidString),
                URLQueryItem(name: "mailbox", value: mailbox),
                URLQueryItem(name: "uids", value: uids.map(String.init).joined(separator: ","))
            ]
        )
        return response.messages
    }

    public func setMessageTag(
        accountID: UUID,
        mailbox: String,
        uid: UInt32,
        tagID: UUID,
        tagged: Bool
    ) async throws {
        let request = HostMessageTagRequest(
            accountID: accountID,
            mailbox: mailbox,
            uid: uid,
            tagID: tagID,
            tagged: tagged
        )
        _ = try await send("POST", path: "v1/messages/tags", body: try encode(request))
    }

    public func classify(
        accountID: UUID,
        mailbox: String,
        limit: Int,
        uids: [UInt32]?,
        force: Bool
    ) async throws -> HostClassifyResponse {
        let request = HostClassifyRequest(
            accountID: accountID,
            mailbox: mailbox,
            limit: limit,
            uids: uids,
            force: force
        )
        return try await sendJSON(
            "POST",
            path: "v1/classify",
            body: try encode(request),
            timeout: 300
        )
    }

    public func classifierStatus() async throws -> MailClassifierStatus {
        try await get("v1/classifier", timeout: 10)
    }

    // MARK: Requests

    private func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        timeout: TimeInterval = 30
    ) async throws -> T {
        let data = try await send("GET", path: path, query: query, timeout: timeout)
        return try decode(data)
    }

    private func sendJSON<T: Decodable>(
        _ method: String,
        path: String,
        body: Data,
        timeout: TimeInterval = 30
    ) async throws -> T {
        let data = try await send(method, path: path, body: body, timeout: timeout)
        return try decode(data)
    }

    private func messageQuery(
        accountID: UUID,
        mailbox: String,
        uid: UInt32
    ) -> [URLQueryItem] {
        [
            URLQueryItem(name: "accountID", value: accountID.uuidString),
            URLQueryItem(name: "mailbox", value: mailbox),
            URLQueryItem(name: "uid", value: String(uid))
        ]
    }

    private func send(
        _ method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Data {
        guard var components = URLComponents(
            url: configuration.baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw HostMailError.unavailable("The host archive URL is invalid.")
        }

        let prefix = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = prefix + "/" + path
        if !query.isEmpty {
            components.queryItems = query
        }

        guard let url = components.url else {
            throw HostMailError.unavailable("Could not build a host archive request.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HostMailError.unavailable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw HostMailError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(HostErrorResponse.self, from: data))?.error
                ?? String(decoding: data.prefix(400), as: UTF8.self)
            throw HostMailError.server(status: http.statusCode, message: detail)
        }
        return data
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw HostMailError.invalidResponse
        }
    }
}
