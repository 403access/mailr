import Foundation

/// Passwords used by the host server when it connects to IMAP. The file is
/// readable only by the current user (0600) and lives next to the host
/// database. It exists because the background host process cannot reliably
/// access Keychain items created by another binary without a GUI prompt.
public struct HostCredentialStore: Sendable {
    public let fileURL: URL

    public static var defaultURL: URL {
        MailDatabase.defaultURL
            .deletingLastPathComponent()
            .appendingPathComponent("host-credentials.json")
    }

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
    }

    public func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return [:]
        }
        return file.passwords.reduce(into: [:]) { result, entry in
            result[entry.key.lowercased()] = entry.value
        }
    }

    public func password(forEmail email: String) -> String? {
        load()[email.lowercased()]
    }

    public func setPassword(_ password: String, forEmail email: String) throws {
        var passwords = load()
        passwords[email.lowercased()] = password
        try save(passwords)
    }

    public func setPasswords(_ newPasswords: [String: String]) throws {
        var passwords = load()
        for (email, password) in newPasswords {
            passwords[email.lowercased()] = password
        }
        try save(passwords)
    }

    public func removePassword(forEmail email: String) throws {
        var passwords = load()
        passwords.removeValue(forKey: email.lowercased())
        try save(passwords)
    }

    private func save(_ passwords: [String: String]) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )

            let data = try JSONEncoder().encode(File(version: 1, passwords: passwords))
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw HostMailError.unavailable(
                "Could not save host credentials: \(error.localizedDescription)"
            )
        }
    }

    private struct File: Codable {
        var version: Int
        var passwords: [String: String]

        init(version: Int, passwords: [String: String]) {
            self.version = version
            self.passwords = passwords
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            passwords = try container.decodeIfPresent([String: String].self, forKey: .passwords) ?? [:]
        }
    }
}
