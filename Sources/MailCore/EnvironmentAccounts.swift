import CryptoKit
import Foundation

// MARK: - Errors

public enum EnvironmentConfigurationError: LocalizedError, Equatable, Sendable {
    case unreadableFile(String)
    case missingFile(String)
    case unknownVariable(String)
    case missingValue(String)
    case invalidEmail(String)
    case invalidProvider(String, variable: String)
    case invalidPort(String, variable: String)
    case invalidSecurity(String, variable: String)
    case invalidIdentifier(String, variable: String)
    case missingServer(String, variable: String)
    case duplicateAccount(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let detail):
            "Could not read the environment file: \(detail)"
        case .missingFile(let detail):
            "The environment file does not exist: \(detail)"
        case .unknownVariable(let key):
            "Unknown account variable \(key). Check the spelling in your .env file."
        case .missingValue(let key):
            "Missing required value \(key) in your .env file."
        case .invalidEmail(let value):
            "“\(value)” is not a valid email address in your .env file."
        case .invalidProvider(let value, let variable):
            "\(variable)=\(value) is not a supported provider. Use icloud, gmail, yahoo, fastmail, zoho, custom, or demo."
        case .invalidPort(let value, let variable):
            "\(variable)=\(value) is not a valid port. Use a number from 1 to 65535."
        case .invalidSecurity(let value, let variable):
            "\(variable)=\(value) is not valid. Use tls or plaintext."
        case .invalidIdentifier(let value, let variable):
            "\(variable)=\(value) is not a valid UUID."
        case .missingServer(let server, let variable):
            "\(variable) is required. Set the .env variable for the \(server) server host."
        case .duplicateAccount(let email):
            "The .env file defines the account \(email) more than once."
        }
    }
}

// MARK: - .env parsing

/// A small, dependency-free parser for the `.env` format.
///
/// Supported syntax matches what most dotenv implementations accept:
/// `#` comments, an optional `export ` prefix, single- and double-quoted
/// values, escaped newlines in double quotes, and trailing comments on
/// unquoted values. Keys are normalized to uppercase.
public struct DotEnv: Sendable, Equatable {
    public private(set) var values: [String: String]

    public init(values: [String: String] = [:]) {
        var normalized: [String: String] = [:]
        for (key, value) in values {
            normalized[key.uppercased()] = value
        }
        self.values = normalized
    }

    public subscript(key: String) -> String? {
        values[key.uppercased()]
    }

    public static func parse(_ contents: String) -> DotEnv {
        var env = DotEnv()
        let normalized = contents
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count))
                    .trimmingCharacters(in: .whitespaces)
            }

            guard let separator = line.firstIndex(of: "=") else { continue }

            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard isValidKey(key) else { continue }

            let rawValue = String(line[line.index(after: separator)...])
            env.values[key.uppercased()] = parseValue(rawValue)
        }

        return env
    }

    /// Loads and parses a `.env` file. Missing files are an error; use
    /// ``loadFirst(at:)`` to try a list of candidate paths.
    public static func load(at url: URL) throws -> DotEnv {
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            return parse(contents)
        } catch {
            throw EnvironmentConfigurationError.unreadableFile(
                "\(url.path): \(error.localizedDescription)"
            )
        }
    }

    /// Loads the first existing regular file in `urls`, preserving order.
    public static func loadFirst(at urls: [URL]) throws -> (url: URL, dotEnv: DotEnv)? {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            return (url, try load(at: url))
        }
        return nil
    }

    /// Returns a copy where `overrides` replace matching keys. The process
    /// environment uses this so explicit variables win over the file.
    public func merging(overrides: [String: String]) -> DotEnv {
        var merged = self
        for (key, value) in overrides {
            merged.values[key.uppercased()] = value
        }
        return merged
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard let first = key.first, first == "_" || first.isLetter else { return false }
        return key.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func parseValue(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let first = text.first else { return "" }

        if first == "\"" {
            return parseQuoted(text, quote: "\"", processesEscapes: true)
                ?? stripInlineComment(text).trimmingCharacters(in: .whitespaces)
        }
        if first == "'" {
            return parseQuoted(text, quote: "'", processesEscapes: false)
                ?? stripInlineComment(text).trimmingCharacters(in: .whitespaces)
        }
        return stripInlineComment(text).trimmingCharacters(in: .whitespaces)
    }

    private static func parseQuoted(
        _ text: String,
        quote: Character,
        processesEscapes: Bool
    ) -> String? {
        var result = ""
        var escaped = false
        var index = text.index(after: text.startIndex)

        while index < text.endIndex {
            let character = text[index]

            if escaped {
                if processesEscapes {
                    switch character {
                    case "n": result.append("\n")
                    case "r": result.append("\r")
                    case "t": result.append("\t")
                    case "\\": result.append("\\")
                    case "\"": result.append("\"")
                    case "'": result.append("'")
                    default:
                        result.append("\\")
                        result.append(character)
                    }
                } else {
                    result.append(character)
                }
                escaped = false
            } else if processesEscapes && character == "\\" {
                escaped = true
            } else if character == quote {
                let rest = text[text.index(after: index)...]
                    .trimmingCharacters(in: .whitespaces)
                if rest.isEmpty || rest.hasPrefix("#") {
                    return result
                }
                result.append(character)
            } else {
                result.append(character)
            }

            index = text.index(after: index)
        }

        return nil
    }

    private static func stripInlineComment(_ text: String) -> String {
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if character == "#", previous == nil || previous?.isWhitespace == true {
                return String(text[..<index])
            }
            previous = character
        }
        return text
    }
}

// MARK: - Account configuration

/// One account described by a `.env` file. The password is deliberately kept
/// out of `MailAccount` so it is never encoded into the account database.
public struct EnvironmentAccount: Sendable, Equatable {
    public let account: MailAccount
    public let password: String?

    public init(account: MailAccount, password: String?) {
        self.account = account
        self.password = password
    }
}

/// Reads account credentials from `MAILR_ACCOUNT_<PREFIX>_*` variables.
///
/// Each account is described by a prefix. Only `EMAIL` is required; the
/// provider can be inferred from well-known domains, and server hosts can be
/// overridden for custom mail servers.
public enum EnvironmentAccounts {
    public static let variablePrefix = "MAILR_ACCOUNT_"
    public static let fileVariable = "MAILR_ENV_FILE"

    /// All `MAILR_ACCOUNT_*` accounts in `values`, ordered by prefix.
    public static func accounts(from values: [String: String]) throws -> [EnvironmentAccount] {
        let fieldsByPrefix = try parseFields(values)
        var result: [EnvironmentAccount] = []
        var seenEmails = Set<String>()
        var seenIDs = Set<UUID>()

        for prefix in fieldsByPrefix.keys.sorted() {
            let entry = try makeAccount(prefix: prefix, fields: fieldsByPrefix[prefix] ?? [:])
            let email = entry.account.emailAddress.lowercased()

            guard seenEmails.insert(email).inserted else {
                throw EnvironmentConfigurationError.duplicateAccount(email)
            }
            guard seenIDs.insert(entry.account.id).inserted else {
                throw EnvironmentConfigurationError.duplicateAccount(email)
            }

            result.append(entry)
        }

        return result
    }

    /// Reads `.env` from the first available location and overlays explicit
    /// `MAILR_ACCOUNT_*` process-environment variables on top.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidateURLs: [URL]? = nil
    ) throws -> [EnvironmentAccount] {
        var file = DotEnv()

        if let explicitPath = environment[fileVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitPath.isEmpty {
            let expandedPath = (explicitPath as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw EnvironmentConfigurationError.missingFile(explicitPath)
            }
            file = try DotEnv.load(at: url)
        } else if let found = try DotEnv.loadFirst(at: candidateURLs ?? defaultCandidateURLs()) {
            file = found.dotEnv
        }

        return try accounts(from: file.merging(overrides: environment).values)
    }

    /// Default `.env` locations, in priority order.
    ///
    /// The current directory covers `swift run` and command-line launches.
    /// The bundle resource covers the macOS app built by `Scripts/build-app.sh`.
    public static func defaultCandidateURLs(
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        applicationSupportDirectory: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> [URL] {
        var urls = [currentDirectory.appendingPathComponent(".env")]

        if let bundleResourceURL {
            urls.append(bundleResourceURL.appendingPathComponent("Mailr.env"))
        }
        if let applicationSupportDirectory {
            urls.append(applicationSupportDirectory.appendingPathComponent("Mailr/.env"))
        }
        urls.append(homeDirectory.appendingPathComponent(".config/mailr/.env"))

        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// Updates accounts defined in the environment and appends new ones.
    /// Accounts that are not mentioned in `.env` are left untouched, so
    /// removing a block from the file never deletes local mail.
    public static func merge(
        _ environmentAccounts: [EnvironmentAccount],
        into accounts: [MailAccount]
    ) -> [MailAccount] {
        var merged = accounts

        for entry in environmentAccounts {
            var candidate = entry.account
            let email = candidate.emailAddress.lowercased()

            let index = merged.firstIndex(where: { $0.id == candidate.id })
                ?? merged.firstIndex(where: { $0.emailAddress.lowercased() == email })

            if let index {
                // Keep any identifier assigned by the app so Keychain entries
                // and cached mail stay attached to this account.
                candidate.id = merged[index].id
                merged[index] = candidate
            } else {
                merged.append(candidate)
            }
        }

        return merged
    }

    // MARK: Parsing

    private enum Field: String, CaseIterable {
        case id = "ID"
        case name = "NAME"
        case email = "EMAIL"
        case password = "PASSWORD"
        case provider = "PROVIDER"
        case imapHost = "IMAP_HOST"
        case imapPort = "IMAP_PORT"
        case imapSecurity = "IMAP_SECURITY"
        case imapUsername = "IMAP_USERNAME"
        case smtpHost = "SMTP_HOST"
        case smtpPort = "SMTP_PORT"
        case smtpSecurity = "SMTP_SECURITY"
        case smtpUsername = "SMTP_USERNAME"
    }

    private static func parseFields(
        _ values: [String: String]
    ) throws -> [String: [Field: String]] {
        var parsed: [String: [Field: String]] = [:]

        for (rawKey, value) in values {
            let key = rawKey.uppercased()
            guard key.hasPrefix(variablePrefix) else { continue }

            let remainder = String(key.dropFirst(variablePrefix.count))
            guard let (prefix, field) = split(remainder) else {
                throw EnvironmentConfigurationError.unknownVariable(rawKey)
            }

            parsed[prefix, default: [:]][field] = value
        }

        return parsed
    }

    private static func split(_ remainder: String) -> (String, Field)? {
        let fields = Field.allCases.sorted { $0.rawValue.count > $1.rawValue.count }
        for field in fields {
            let suffix = "_\(field.rawValue)"
            guard remainder.hasSuffix(suffix) else { continue }

            let prefix = String(remainder.dropLast(suffix.count))
            guard !prefix.isEmpty else { return nil }
            return (prefix, field)
        }
        return nil
    }

    private static func makeAccount(
        prefix: String,
        fields: [Field: String]
    ) throws -> EnvironmentAccount {
        let emailKey = "\(variablePrefix)\(prefix)_EMAIL"
        let email = (fields[.email] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !email.isEmpty else {
            throw EnvironmentConfigurationError.missingValue(emailKey)
        }
        guard email.contains("@"),
              !email.hasPrefix("@"),
              !email.hasSuffix("@") else {
            throw EnvironmentConfigurationError.invalidEmail(email)
        }

        let provider = try resolveProvider(for: email, fields: fields, prefix: prefix)

        var incoming = provider.incomingDefaults
            ?? ServerSettings(host: "", port: 993, security: .tls, username: "")
        var outgoing = provider.outgoingDefaults
            ?? ServerSettings(host: "", port: 465, security: .tls, username: "")

        try applyServer(
            &incoming,
            fields: fields,
            prefix: prefix,
            host: .imapHost,
            port: .imapPort,
            security: .imapSecurity,
            username: .imapUsername
        )
        try applyServer(
            &outgoing,
            fields: fields,
            prefix: prefix,
            host: .smtpHost,
            port: .smtpPort,
            security: .smtpSecurity,
            username: .smtpUsername
        )

        if incoming.username.isEmpty { incoming.username = email }
        if outgoing.username.isEmpty { outgoing.username = email }

        if provider != .demo {
            guard !incoming.host.isEmpty else {
                throw EnvironmentConfigurationError.missingServer(
                    "IMAP",
                    variable: "\(variablePrefix)\(prefix)_IMAP_HOST"
                )
            }
            guard !outgoing.host.isEmpty else {
                throw EnvironmentConfigurationError.missingServer(
                    "SMTP",
                    variable: "\(variablePrefix)\(prefix)_SMTP_HOST"
                )
            }
        }

        let rawName = (fields[.name] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = rawName.isEmpty ? defaultDisplayName(for: email) : rawName

        let id: UUID
        if let rawID = fields[.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawID.isEmpty {
            guard let parsed = UUID(uuidString: rawID) else {
                throw EnvironmentConfigurationError.invalidIdentifier(
                    rawID,
                    variable: "\(variablePrefix)\(prefix)_ID"
                )
            }
            id = parsed
        } else {
            id = stableID(for: email.lowercased())
        }

        let password = fields[.password].flatMap { $0.isEmpty ? nil : $0 }

        let account = MailAccount(
            id: id,
            displayName: displayName,
            emailAddress: email,
            provider: provider,
            incoming: incoming,
            outgoing: outgoing,
            isDemo: provider == .demo
        )

        return EnvironmentAccount(account: account, password: password)
    }

    private static func resolveProvider(
        for email: String,
        fields: [Field: String],
        prefix: String
    ) throws -> ProviderKind {
        if let rawProvider = fields[.provider]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawProvider.isEmpty {
            let normalized = rawProvider
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
            guard let provider = ProviderKind(rawValue: normalized) else {
                throw EnvironmentConfigurationError.invalidProvider(
                    rawProvider,
                    variable: "\(variablePrefix)\(prefix)_PROVIDER"
                )
            }
            return provider
        }

        return inferredProvider(for: email)
    }

    private static func inferredProvider(for email: String) -> ProviderKind {
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

    private static func applyServer(
        _ server: inout ServerSettings,
        fields: [Field: String],
        prefix: String,
        host: Field,
        port: Field,
        security: Field,
        username: Field
    ) throws {
        if let rawHost = fields[host]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawHost.isEmpty {
            server.host = rawHost
        }

        if let rawPort = fields[port]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPort.isEmpty {
            guard let parsed = Int(rawPort), (1...65_535).contains(parsed) else {
                throw EnvironmentConfigurationError.invalidPort(
                    rawPort,
                    variable: "\(variablePrefix)\(prefix)_\(port.rawValue)"
                )
            }
            server.port = parsed
        }

        if let rawSecurity = fields[security]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawSecurity.isEmpty {
            switch rawSecurity.lowercased() {
            case "tls", "ssl", "implicit", "implicit-tls", "secure":
                server.security = .tls
            case "plaintext", "plain", "none", "insecure", "clear":
                server.security = .plaintext
            default:
                throw EnvironmentConfigurationError.invalidSecurity(
                    rawSecurity,
                    variable: "\(variablePrefix)\(prefix)_\(security.rawValue)"
                )
            }
        }

        if let rawUsername = fields[username] {
            server.username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func defaultDisplayName(for email: String) -> String {
        let localPart = email.split(separator: "@", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return localPart.isEmpty ? email : localPart
    }

    /// A deterministic UUID so re-reading the same `.env` file updates the
    /// same account instead of creating duplicates.
    private static func stableID(for email: String) -> UUID {
        let digest = SHA256.hash(data: Data("mailr-account:\(email)".utf8))
        var bytes = Array(digest.prefix(16))

        // RFC 4122 version 4 / variant bits.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let uuid = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid)
    }
}
