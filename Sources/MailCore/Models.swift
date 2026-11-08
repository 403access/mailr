import Foundation

// MARK: - Addresses

public struct EmailAddress: Hashable, Codable, Sendable, Identifiable {
    public var address: String
    public var name: String?

    public init(address: String, name: String? = nil) {
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (trimmedName?.isEmpty == false) ? trimmedName : nil
    }

    public var id: String {
        "\(name ?? "")<\(address.lowercased())>"
    }

    public var displayName: String {
        name ?? address
    }

    public var initials: String {
        let source = name ?? address
        let words = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "@" })
        if words.count >= 2, let first = words.first?.first, let last = words.last?.first {
            return "\(first)\(last)".uppercased()
        }
        return String(source.prefix(2)).uppercased()
    }

    /// Parses an RFC 5322 address list. Handles quoted display names,
    /// angle-addr forms, groups and simple bare addresses.
    public static func parseList(_ raw: String) -> [EmailAddress] {
        let unfolded = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")

        var items: [String] = []
        var current = ""
        var inQuotes = false
        var angleDepth = 0
        var escaped = false

        for character in unfolded {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inQuotes:
                escaped = true
                current.append(character)
            case "\"":
                inQuotes.toggle()
                current.append(character)
            case "<":
                if !inQuotes { angleDepth += 1 }
                current.append(character)
            case ">":
                if !inQuotes { angleDepth = max(0, angleDepth - 1) }
                current.append(character)
            case ",", ";":
                if !inQuotes && angleDepth == 0 {
                    items.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            default:
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(current)
        }

        return items.compactMap { parseSingle($0) }
    }

    private static func parseSingle(_ raw: String) -> EmailAddress? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Drop group prefixes such as `Team:`.
        if let colon = text.firstIndex(of: ":"),
           !text[..<colon].contains("@"),
           !text[..<colon].contains("<") {
            text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return nil }

        let name: String?
        let address: String

        if let open = text.firstIndex(of: "<"), let close = text[open...].firstIndex(of: ">") {
            address = String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            var rawName = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            if rawName.hasPrefix("\""), rawName.hasSuffix("\""), rawName.count >= 2 {
                rawName = String(rawName.dropFirst().dropLast())
            }
            rawName = rawName.replacingOccurrences(of: "\\\"", with: "\"")
            name = rawName.isEmpty ? nil : RFC2047.decode(rawName)
        } else {
            // Remove trailing comments like `user@example.com (Work)`.
            let withoutComment = text.replacingOccurrences(
                of: "\\s*\\([^)]*\\)\\s*$",
                with: "",
                options: .regularExpression
            )
            address = withoutComment.trimmingCharacters(in: .whitespaces)
            name = nil
        }

        guard !address.isEmpty, address.contains("@") else { return nil }
        return EmailAddress(address: RFC2047.decode(address), name: name.map { RFC2047.decode($0) })
    }
}

// MARK: - Accounts

public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case demo
    case icloud
    case gmail
    case yahoo
    case fastmail
    case zoho
    case custom
    /// Mail imported from another client and stored only on this device.
    case local

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .demo: "Demo"
        case .icloud: "iCloud"
        case .gmail: "Gmail"
        case .yahoo: "Yahoo"
        case .fastmail: "Fastmail"
        case .zoho: "Zoho"
        case .custom: "Custom"
        case .local: "Local Mail"
        }
    }

    public var note: String? {
        switch self {
        case .icloud:
            "Use an app-specific password from appleid.apple.com."
        case .gmail:
            "Use a Google app password (2-Step Verification required)."
        case .yahoo:
            "Use an app password generated in Yahoo account security."
        case .fastmail:
            "Use an app password from Settings > Privacy & Security."
        case .zoho:
            "Use an app-specific password if 2FA is enabled."
        case .custom:
            "IMAP and SMTP servers must support direct TLS (993/465)."
        case .demo:
            "A local, offline mailbox for trying Mailr."
        case .local:
            "Mail imported from another client. Stored only on this device."
        }
    }

    public var incomingDefaults: ServerSettings? {
        switch self {
        case .demo, .local:
            nil
        case .icloud:
            ServerSettings(host: "imap.mail.me.com", port: 993, security: .tls, username: "")
        case .gmail:
            ServerSettings(host: "imap.gmail.com", port: 993, security: .tls, username: "")
        case .yahoo:
            ServerSettings(host: "imap.mail.yahoo.com", port: 993, security: .tls, username: "")
        case .fastmail:
            ServerSettings(host: "imap.fastmail.com", port: 993, security: .tls, username: "")
        case .zoho:
            ServerSettings(host: "imap.zoho.com", port: 993, security: .tls, username: "")
        case .custom:
            ServerSettings(host: "", port: 993, security: .tls, username: "")
        }
    }

    public var outgoingDefaults: ServerSettings? {
        switch self {
        case .demo, .local:
            nil
        case .icloud:
            ServerSettings(host: "smtp.mail.me.com", port: 465, security: .tls, username: "")
        case .gmail:
            ServerSettings(host: "smtp.gmail.com", port: 465, security: .tls, username: "")
        case .yahoo:
            ServerSettings(host: "smtp.mail.yahoo.com", port: 465, security: .tls, username: "")
        case .fastmail:
            ServerSettings(host: "smtp.fastmail.com", port: 465, security: .tls, username: "")
        case .zoho:
            ServerSettings(host: "smtp.zoho.com", port: 465, security: .tls, username: "")
        case .custom:
            ServerSettings(host: "", port: 465, security: .tls, username: "")
        }
    }

    /// Infers a provider from a well-known email domain. Anything else is
    /// treated as a custom server.
    public static func inferred(forEmail email: String) -> ProviderKind {
        let domain = email
            .split(separator: "@", omittingEmptySubsequences: true)
            .last?
            .lowercased() ?? ""

        switch domain {
        case "icloud.com", "me.com", "mac.com":
            return .icloud
        case "gmail.com", "googlemail.com":
            return .gmail
        case "yahoo.com", "ymail.com", "rocketmail.com":
            return .yahoo
        case "fastmail.com", "fastmail.fm":
            return .fastmail
        case "zoho.com":
            return .zoho
        default:
            return .custom
        }
    }
}

public enum ServerSecurity: String, Codable, CaseIterable, Sendable {
    /// Implicit TLS, usually port 993 (IMAP) or 465 (SMTP).
    case tls
    /// Unencrypted. Only appropriate for a local development server.
    case plaintext

    public var displayName: String {
        switch self {
        case .tls: "TLS"
        case .plaintext: "None (insecure)"
        }
    }
}

public struct ServerSettings: Hashable, Codable, Sendable {
    public var host: String
    public var port: Int
    public var security: ServerSecurity
    public var username: String

    public init(host: String, port: Int, security: ServerSecurity, username: String) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
    }
}

public struct MailAccount: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var displayName: String
    public var emailAddress: String
    public var provider: ProviderKind
    public var incoming: ServerSettings
    public var outgoing: ServerSettings
    public var isDemo: Bool

    public init(
        id: UUID = UUID(),
        displayName: String,
        emailAddress: String,
        provider: ProviderKind,
        incoming: ServerSettings,
        outgoing: ServerSettings,
        isDemo: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.provider = provider
        self.incoming = incoming
        self.outgoing = outgoing
        self.isDemo = isDemo
    }

    public static let demoID = UUID(uuidString: "DE30A000-0000-4000-8000-000000000001")!

    public static var demo: MailAccount {
        MailAccount(
            id: demoID,
            displayName: "Mailr Demo",
            emailAddress: "demo@mailr.app",
            provider: .demo,
            incoming: ServerSettings(host: "", port: 0, security: .tls, username: ""),
            outgoing: ServerSettings(host: "", port: 0, security: .tls, username: ""),
            isDemo: true
        )
    }

    public var fromAddress: EmailAddress {
        EmailAddress(address: emailAddress, name: displayName)
    }
}

// MARK: - Mailboxes

public enum MailboxRole: String, Codable, Hashable, Sendable, CaseIterable {
    case inbox
    case drafts
    case sent
    case archive
    case junk
    case trash
    case other

    public var displayName: String {
        switch self {
        case .inbox: "Inbox"
        case .drafts: "Drafts"
        case .sent: "Sent"
        case .archive: "Archive"
        case .junk: "Junk"
        case .trash: "Trash"
        case .other: "Mailbox"
        }
    }

    public var sortIndex: Int {
        switch self {
        case .inbox: 0
        case .drafts: 1
        case .sent: 2
        case .archive: 3
        case .junk: 4
        case .trash: 5
        case .other: 6
        }
    }

    public var symbolName: String {
        switch self {
        case .inbox: "tray"
        case .drafts: "square.and.pencil"
        case .sent: "paperplane"
        case .archive: "archivebox"
        case .junk: "exclamationmark.octagon"
        case .trash: "trash"
        case .other: "folder"
        }
    }
}

public struct Mailbox: Identifiable, Hashable, Sendable, Codable {
    /// The server-side path. Kept exactly as the server returned it.
    public var path: String
    /// A human readable name, decoded from IMAP modified UTF-7.
    public var name: String
    public var role: MailboxRole
    public var delimiter: String?
    public var unreadCount: Int
    public var totalCount: Int

    public init(
        path: String,
        name: String,
        role: MailboxRole,
        delimiter: String? = "/",
        unreadCount: Int = 0,
        totalCount: Int = 0
    ) {
        self.path = path
        self.name = name
        self.role = role
        self.delimiter = delimiter
        self.unreadCount = unreadCount
        self.totalCount = totalCount
    }

    public var id: String { path }

    public static func sorted(_ boxes: [Mailbox]) -> [Mailbox] {
        boxes.sorted { lhs, rhs in
            if lhs.role.sortIndex != rhs.role.sortIndex {
                return lhs.role.sortIndex < rhs.role.sortIndex
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

// MARK: - Messages

public enum MessageFlag: String, Sendable, CaseIterable {
    case seen = "\\Seen"
    case flagged = "\\Flagged"
    case answered = "\\Answered"
    case draft = "\\Draft"
}

public struct MessageSummary: Identifiable, Hashable, Sendable, Codable {
    public var uid: UInt32
    public var mailbox: String
    public var subject: String
    public var from: [EmailAddress]
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var date: Date
    public var snippet: String
    public var size: Int
    public var isRead: Bool
    public var isFlagged: Bool
    public var isAnswered: Bool
    public var hasAttachments: Bool
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    /// Whether the message is currently present in the actual mailbox on the
    /// IMAP server. Messages that only live in the host archive are marked
    /// `false`.
    public var isOnMailbox: Bool

    public init(
        uid: UInt32,
        mailbox: String,
        subject: String,
        from: [EmailAddress],
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        date: Date,
        snippet: String = "",
        size: Int = 0,
        isRead: Bool = false,
        isFlagged: Bool = false,
        isAnswered: Bool = false,
        hasAttachments: Bool = false,
        messageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        isOnMailbox: Bool = true
    ) {
        self.uid = uid
        self.mailbox = mailbox
        self.subject = subject
        self.from = from
        self.to = to
        self.cc = cc
        self.date = date
        self.snippet = snippet
        self.size = size
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.isAnswered = isAnswered
        self.hasAttachments = hasAttachments
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.isOnMailbox = isOnMailbox
    }

    public var id: String { "\(mailbox)#\(uid)" }

    public var senderDisplayName: String {
        from.first?.displayName ?? "Unknown sender"
    }

    public var senderAddress: String {
        from.first?.address ?? ""
    }

    public var isUnread: Bool { !isRead }
}

public struct MailAttachment: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var filename: String
    public var mimeType: String
    public var data: Data
    public var isInline: Bool
    public var contentID: String?

    public init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String,
        data: Data,
        isInline: Bool = false,
        contentID: String? = nil
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.isInline = isInline
        self.contentID = contentID
    }

    public var byteCountLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    public var isVisibleAttachment: Bool {
        // Inline images with a Content-ID are embedded in the HTML body;
        // only show real files in the attachment bar.
        !isInline || contentID == nil
    }
}

public struct MailMessage: Identifiable, Hashable, Sendable, Codable {
    public var summary: MessageSummary
    public var text: String?
    public var html: String?
    public var attachments: [MailAttachment]

    public init(
        summary: MessageSummary,
        text: String? = nil,
        html: String? = nil,
        attachments: [MailAttachment] = []
    ) {
        self.summary = summary
        self.text = text
        self.html = html
        self.attachments = attachments
    }

    public var id: String { summary.id }
}

// MARK: - Storage location

/// Where a message is currently held.
public enum MessagePlacement: String, Codable, Hashable, Sendable, CaseIterable {
    /// Present in the actual IMAP mailbox, and not in the host archive.
    case mailbox
    /// Present in the host archive but no longer in the actual mailbox.
    case host
    /// Present in both the actual mailbox and the host archive.
    case both
    /// Only in this client's local database (for example while the host
    /// archive is unreachable).
    case device
    /// The message could not be found anywhere.
    case unknown

    public var title: String {
        switch self {
        case .mailbox: "On mailbox"
        case .host: "Only on host machine"
        case .both: "Mailbox + host machine"
        case .device: "Only on this device"
        case .unknown: "Storage unknown"
        }
    }

    public var symbolName: String {
        switch self {
        case .mailbox: "server.rack"
        case .host: "externaldrive.fill"
        case .both: "checkmark.circle.fill"
        case .device: "internaldrive"
        case .unknown: "questionmark.circle"
        }
    }
}

/// The result of looking for one message in the mailbox, the host archive, and
/// the local client database.
public struct MessageStorageStatus: Codable, Hashable, Sendable {
    public var onMailbox: Bool
    public var onHost: Bool
    public var onDevice: Bool

    public init(onMailbox: Bool, onHost: Bool, onDevice: Bool) {
        self.onMailbox = onMailbox
        self.onHost = onHost
        self.onDevice = onDevice
    }

    public var placement: MessagePlacement {
        switch (onMailbox, onHost, onDevice) {
        case (true, true, _):
            return .both
        case (true, false, _):
            return .mailbox
        case (false, true, _):
            return .host
        case (false, false, true):
            return .device
        case (false, false, false):
            return .unknown
        }
    }

    public var title: String { placement.title }
    public var symbolName: String { placement.symbolName }
}

public struct OutgoingAttachment: Sendable, Identifiable {
    public var id: UUID
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public struct OutgoingMessage: Sendable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var text: String
    public var attachments: [OutgoingAttachment]
    public var inReplyTo: String?
    public var references: [String]

    public init(
        from: EmailAddress,
        to: [EmailAddress],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        subject: String,
        text: String,
        attachments: [OutgoingAttachment] = [],
        inReplyTo: String? = nil,
        references: [String] = []
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.text = text
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
    }

    public var allRecipients: [EmailAddress] {
        to + cc + bcc
    }
}

// MARK: - Errors

public enum MailError: LocalizedError, Sendable, Equatable {
    case notConfigured(String)
    case connection(String)
    case authentication(String)
    case protocolViolation(String)
    case commandFailed(String)
    case unsupported(String)
    case invalidMessage(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let detail): detail
        case .connection(let detail): "Connection failed: \(detail)"
        case .authentication(let detail): "Sign-in failed: \(detail)"
        case .protocolViolation(let detail): "Unexpected server response: \(detail)"
        case .commandFailed(let detail): detail
        case .unsupported(let detail): detail
        case .invalidMessage(let detail): detail
        }
    }
}
