import Foundation

// MARK: - Server types

public enum ThunderbirdServerType: String, Sendable, Hashable {
    case imap
    case pop3
    case local = "none"
    case nntp
    case rss
    case other

    public var displayName: String {
        switch self {
        case .imap: "IMAP"
        case .pop3: "POP3"
        case .local: "Local Folders"
        case .nntp: "News"
        case .rss: "Feeds"
        case .other: "Other"
        }
    }
}

// MARK: - Accounts

public struct ThunderbirdAccount: Sendable, Identifiable {
    /// Thunderbird's internal account key, such as `account1`.
    public var key: String
    /// The primary identity's email address.
    public var emailAddress: String
    public var displayName: String
    public var serverType: ThunderbirdServerType
    public var serverKey: String?
    public var incoming: ServerSettings?
    public var outgoing: ServerSettings?
    public var incomingUsesStartTLS: Bool
    public var outgoingUsesStartTLS: Bool
    /// The directory that holds this account's local message store, if any.
    public var localDirectory: URL?
    public var localSourceLabel: String
    public var additionalIdentities: [String]
    public var issues: [String]

    public var id: String { key }

    public var isImportableAsServer: Bool {
        guard serverType == .imap else { return false }
        guard let incoming, !incoming.host.isEmpty else { return false }
        return !incomingUsesStartTLS
    }
}

/// One folder tree of local mail in a Thunderbird profile. Thunderbird keeps
/// shared local folders, POP3 stores, and optional IMAP offline stores in
/// separate directories.
public struct ThunderbirdLocalSource: Sendable, Hashable {
    public var label: String
    public var directory: URL
    public var serverKey: String
    public var serverType: ThunderbirdServerType

    public init(
        label: String,
        directory: URL,
        serverKey: String,
        serverType: ThunderbirdServerType
    ) {
        self.label = label
        self.directory = directory
        self.serverKey = serverKey
        self.serverType = serverType
    }
}

// MARK: - Reader

public enum ThunderbirdAccountReader {
    /// Reads the mail accounts described by a profile's prefs.js.
    public static func accounts(prefs: ThunderbirdPrefs, profilePath: URL) -> [ThunderbirdAccount] {
        var accountKeys = splitCSV(prefs.string("mail.accountmanager.accounts"))

        if accountKeys.isEmpty {
            // Older or partially written profiles may not have the manager
            // list. Fall back to every referenced account server.
            accountKeys = prefs.values.keys.compactMap { key in
                guard key.hasPrefix("mail.account."), key.hasSuffix(".server") else { return nil }
                return String(key.dropFirst("mail.account.".count).dropLast(".server".count))
            }.sorted()
        }

        var result: [ThunderbirdAccount] = []
        for accountKey in accountKeys {
            guard let account = makeAccount(
                accountKey: accountKey,
                prefs: prefs,
                profilePath: profilePath
            ) else {
                continue
            }
            result.append(account)
        }
        return result
    }

    /// Every server directory that can contain local mail. Local Folders and
    /// POP3 stores are included by default; IMAP offline stores are optional
    /// because they duplicate mail that is still on the server.
    public static func localSources(
        prefs: ThunderbirdPrefs,
        profilePath: URL,
        accounts: [ThunderbirdAccount],
        includeIMAPCache: Bool
    ) -> [ThunderbirdLocalSource] {
        var serverKeys = Set<String>()

        for key in prefs.values.keys {
            guard key.hasPrefix("mail.server.") else { continue }
            let remainder = key.dropFirst("mail.server.".count)
            guard let dot = remainder.firstIndex(of: ".") else { continue }
            serverKeys.insert(String(remainder[..<dot]))
        }

        var sources: [ThunderbirdLocalSource] = []
        var usedLabels: [String: Int] = [:]

        for serverKey in serverKeys.sorted() {
            let type = serverType(prefs: prefs, serverKey: serverKey)
            switch type {
            case .imap where !includeIMAPCache:
                continue
            case .nntp, .rss, .other:
                continue
            default:
                break
            }

            guard let directory = resolveDirectory(
                prefs: prefs,
                serverKey: serverKey,
                profilePath: profilePath,
                type: type
            ), FileManager.default.fileExists(atPath: directory.path) else {
                continue
            }

            let baseLabel: String
            switch type {
            case .local:
                baseLabel = "Local Folders"
            default:
                let matching = accounts.first(where: { $0.serverKey == serverKey })
                let host = prefs.string("mail.server.\(serverKey).hostname") ?? serverKey
                baseLabel = matching?.emailAddress.isEmpty == false
                    ? matching?.emailAddress ?? host
                    : host
            }

            var label = baseLabel
            if type == .imap {
                label += " (IMAP cache)"
            }
            let count = (usedLabels[label] ?? 0) + 1
            usedLabels[label] = count
            if count > 1 {
                label += " (\(count))"
            }

            sources.append(ThunderbirdLocalSource(
                label: label,
                directory: directory,
                serverKey: serverKey,
                serverType: type
            ))
        }

        return sources
    }

    /// A stable Mailr account for a profile's imported local mail.
    public static func localMailAccount(for profile: ThunderbirdProfile) -> MailAccount {
        let accountID = StableAccountID.localProfile(path: profile.id)
        let seed = profile.path.lastPathComponent.isEmpty
            ? profile.name
            : profile.path.lastPathComponent
        let localPart = seed
            .lowercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber { return character }
                return "."
            }
            .reduce(into: "") { result, character in
                if character == ".", result.last == "." { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        let email = (localPart.isEmpty ? "thunderbird" : localPart) + "@mailr.local"
        let settings = ServerSettings(host: "", port: 0, security: .tls, username: "")

        return MailAccount(
            id: accountID,
            displayName: "Thunderbird — \(profile.name)",
            emailAddress: email,
            provider: .local,
            incoming: settings,
            outgoing: settings,
            isDemo: false
        )
    }

    // MARK: Parsing

    private static func makeAccount(
        accountKey: String,
        prefs: ThunderbirdPrefs,
        profilePath: URL
    ) -> ThunderbirdAccount? {
        let serverKey = prefs.string("mail.account.\(accountKey).server")
        let identityKeys = splitCSV(prefs.string("mail.account.\(accountKey).identities"))

        var issues: [String] = []
        var identities: [(key: String, email: String, name: String, smtpServer: String?)] = []

        for identityKey in identityKeys {
            guard prefs.boolean("mail.identity.\(identityKey).valid") != false else { continue }
            let email = (prefs.string("mail.identity.\(identityKey).useremail") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !email.isEmpty else { continue }
            let name = prefs.string("mail.identity.\(identityKey).fullName") ?? ""
            identities.append((
                key: identityKey,
                email: email,
                name: name,
                smtpServer: prefs.string("mail.identity.\(identityKey).smtpServer")
            ))
        }

        guard let primary = identities.first else {
            // A server with no identity can still contribute local mail, but
            // there is not enough information to build a Mailr account.
            return nil
        }

        if identities.count > 1 {
            let aliases = identities.dropFirst().map(\.email).joined(separator: ", ")
            issues.append("Additional identities were not imported as separate accounts: \(aliases).")
        }

        let type = serverKey.map { serverType(prefs: prefs, serverKey: $0) } ?? .other
        let incomingInfo = serverKey.flatMap {
            incomingSettings(prefs: prefs, serverKey: $0, fallbackUsername: primary.email)
        }

        if let incomingInfo {
            switch type {
            case .imap:
                break
            case .pop3:
                issues.append("Thunderbird uses POP3 for this account. Mailr imports its local mail but does not connect to POP3.")
            case .local:
                issues.append("Thunderbird local folders are not an email account.")
            case .nntp, .rss, .other:
                issues.append("This Thunderbird account is not an IMAP mail account.")
            }

            if incomingInfo.usesStartTLS {
                issues.append("Incoming mail used STARTTLS. Mailr only supports implicit TLS.")
            }
            if let serverKey,
               prefs.integer("mail.server.\(serverKey).authMethod") == 10 {
                issues.append("Thunderbird signs in to this account with OAuth2. Mailr needs an app password.")
            }
        }

        let smtpKey = primary.smtpServer
            ?? splitCSV(prefs.string("mail.smtpservers")).first
            ?? "smtp1"
        let outgoingInfo = outgoingSettings(
            prefs: prefs,
            smtpKey: smtpKey,
            fallbackUsername: primary.email
        )
        if let outgoingInfo, outgoingInfo.usesStartTLS {
            issues.append("Outgoing mail used STARTTLS. Mailr only supports implicit TLS.")
        }
        if prefs.integer("mail.smtpserver.\(smtpKey).authMethod") == 10 {
            issues.append("Thunderbird signs in to the outgoing server with OAuth2. Mailr needs an app password.")
        }

        let localDirectory = serverKey.flatMap {
            resolveDirectory(prefs: prefs, serverKey: $0, profilePath: profilePath, type: type)
        }

        let localSourceLabel: String
        switch type {
        case .local:
            localSourceLabel = "Local Folders"
        default:
            localSourceLabel = primary.email
        }

        let displayName = primary.name
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ThunderbirdAccount(
            key: accountKey,
            emailAddress: primary.email,
            displayName: displayName.isEmpty ? defaultDisplayName(for: primary.email) : displayName,
            serverType: type,
            serverKey: serverKey,
            incoming: incomingInfo?.settings,
            outgoing: outgoingInfo?.settings,
            incomingUsesStartTLS: incomingInfo?.usesStartTLS ?? false,
            outgoingUsesStartTLS: outgoingInfo?.usesStartTLS ?? false,
            localDirectory: localDirectory,
            localSourceLabel: localSourceLabel,
            additionalIdentities: identities.dropFirst().map(\.email),
            issues: issues
        )
    }

    private struct ParsedServer {
        var settings: ServerSettings
        var usesStartTLS: Bool
    }

    private static func incomingSettings(
        prefs: ThunderbirdPrefs,
        serverKey: String,
        fallbackUsername: String
    ) -> ParsedServer? {
        guard let host = prefs.string("mail.server.\(serverKey).hostname")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !host.isEmpty else {
            return nil
        }

        let connection = connectionSettings(
            rawPort: prefs.integer("mail.server.\(serverKey).port"),
            rawSocketType: prefs.integer("mail.server.\(serverKey).socketType")
                ?? prefs.integer("mail.server.\(serverKey).try_ssl"),
            isIncoming: true
        )
        let username = (prefs.string("mail.server.\(serverKey).userName")
            ?? prefs.string("mail.server.\(serverKey).realuserName")
            ?? fallbackUsername)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedServer(
            settings: ServerSettings(
                host: host,
                port: connection.port,
                security: connection.security,
                username: username.isEmpty ? fallbackUsername : username
            ),
            usesStartTLS: connection.usesStartTLS
        )
    }

    private static func outgoingSettings(
        prefs: ThunderbirdPrefs,
        smtpKey: String,
        fallbackUsername: String
    ) -> ParsedServer? {
        guard let host = prefs.string("mail.smtpserver.\(smtpKey).hostname")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !host.isEmpty else {
            return nil
        }

        let connection = connectionSettings(
            rawPort: prefs.integer("mail.smtpserver.\(smtpKey).port"),
            rawSocketType: prefs.integer("mail.smtpserver.\(smtpKey).socketType")
                ?? prefs.integer("mail.smtpserver.\(smtpKey).try_ssl"),
            isIncoming: false
        )
        let username = (prefs.string("mail.smtpserver.\(smtpKey).username")
            ?? fallbackUsername)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedServer(
            settings: ServerSettings(
                host: host,
                port: connection.port,
                security: connection.security,
                username: username.isEmpty ? fallbackUsername : username
            ),
            usesStartTLS: connection.usesStartTLS
        )
    }

    private static func serverType(prefs: ThunderbirdPrefs, serverKey: String) -> ThunderbirdServerType {
        let raw = (prefs.string("mail.server.\(serverKey).type") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let type = ThunderbirdServerType(rawValue: raw) {
            return type
        }

        // Profiles written by some older versions omit `.type` for the shared
        // local folders server.
        let host = (prefs.string("mail.server.\(serverKey).hostname") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if host.caseInsensitiveCompare("Local Folders") == .orderedSame {
            return .local
        }
        return .other
    }

    private struct ConnectionSettings {
        var security: ServerSecurity
        var port: Int
        var usesStartTLS: Bool
    }

    /// Thunderbird stores 0 = plain, 1 = try STARTTLS, 2 = always STARTTLS,
    /// 3 = SSL/TLS. SMTP uses the older `try_ssl` key for the same values.
    private static func connectionSettings(
        rawPort: Int?,
        rawSocketType: Int?,
        isIncoming: Bool
    ) -> ConnectionSettings {
        let validPort = rawPort.flatMap { (1...65_535).contains($0) ? $0 : nil }

        let security: ServerSecurity
        let usesStartTLS: Bool

        switch rawSocketType {
        case 3:
            security = .tls
            usesStartTLS = false
        case 1, 2:
            security = .tls
            usesStartTLS = true
        case 0:
            security = .plaintext
            usesStartTLS = false
        default:
            // No explicit socket type. Infer from the conventional ports so
            // we do not migrate a working TLS account as plaintext.
            switch validPort {
            case 993, 465:
                security = .tls
                usesStartTLS = false
            case 143, 587:
                security = .tls
                usesStartTLS = true
            default:
                security = .plaintext
                usesStartTLS = false
            }
        }

        let fallbackPort: Int
        if usesStartTLS {
            fallbackPort = isIncoming ? 143 : 587
        } else if security == .tls {
            fallbackPort = isIncoming ? 993 : 465
        } else {
            fallbackPort = isIncoming ? 143 : 587
        }

        return ConnectionSettings(
            security: security,
            port: validPort ?? fallbackPort,
            usesStartTLS: usesStartTLS
        )
    }

    private static func resolveDirectory(
        prefs: ThunderbirdPrefs,
        serverKey: String,
        profilePath: URL,
        type: ThunderbirdServerType
    ) -> URL? {
        let fileManager = FileManager.default

        if let absolute = prefs.string("mail.server.\(serverKey).directory"),
           !absolute.isEmpty {
            let expanded = (absolute as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        if let relative = prefs.string("mail.server.\(serverKey).directory-rel"),
           !relative.isEmpty {
            let expanded = (relative as NSString).expandingTildeInPath
            let url = profilePath.appendingPathComponent(expanded).standardizedFileURL
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        let host = prefs.string("mail.server.\(serverKey).hostname") ?? ""
        let conventional: URL?
        switch type {
        case .local:
            conventional = profilePath.appendingPathComponent("Mail/Local Folders", isDirectory: true)
        case .pop3:
            conventional = host.isEmpty
                ? nil
                : profilePath.appendingPathComponent("Mail", isDirectory: true)
                    .appendingPathComponent(host, isDirectory: true)
        case .imap:
            conventional = host.isEmpty
                ? nil
                : profilePath.appendingPathComponent("ImapMail", isDirectory: true)
                    .appendingPathComponent(host, isDirectory: true)
        default:
            conventional = nil
        }

        if let conventional, fileManager.fileExists(atPath: conventional.path) {
            return conventional
        }
        return nil
    }

    // MARK: Helpers

    private static func splitCSV(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func defaultDisplayName(for email: String) -> String {
        email.split(separator: "@", omittingEmptySubsequences: false).first.map(String.init) ?? email
    }
}
