import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Errors

public enum ThunderbirdCredentialError: LocalizedError, Equatable, Sendable {
    case nssNotFound(String)
    case nssInitializationFailed(Int32)
    case profileLocked
    case decryptionFailed(host: String, code: Int32)
    case invalidLoginsFile(String)

    public var errorDescription: String? {
        switch self {
        case .nssNotFound(let detail):
            "Could not find Thunderbird's NSS libraries: \(detail)"
        case .nssInitializationFailed(let code):
            "Could not open the Thunderbird credential database (NSS error \(code)). Quit Thunderbird and try again."
        case .profileLocked:
            "This Thunderbird profile is protected by a primary password. Disable or unlock it in Thunderbird, then try again."
        case .decryptionFailed(let host, let code):
            "Could not decrypt the saved password for \(host) (NSS error \(code))."
        case .invalidLoginsFile(let detail):
            "Could not read Thunderbird's logins.json: \(detail)"
        }
    }
}

// MARK: - Credentials

public struct ThunderbirdCredential: Hashable, Sendable {
    public enum Scheme: String, Sendable {
        case imap
        case smtp
        case mailbox
        case pop3
        case oauth
        case other
    }

    public var hostname: String
    public var host: String
    public var scheme: Scheme
    public var username: String
    public var password: String
    public var isOAuth: Bool

    public init(
        hostname: String,
        host: String,
        scheme: Scheme,
        username: String,
        password: String,
        isOAuth: Bool = false
    ) {
        self.hostname = hostname
        self.host = host
        self.scheme = scheme
        self.username = username
        self.password = password
        self.isOAuth = isOAuth
    }

    public var displayName: String { "\(scheme.rawValue)://\(host) (\(username))" }
}

public enum ThunderbirdCredentials {
    /// Decrypts the stored login entries for a profile. Thunderbird uses NSS
    /// Secret Decoder Ring encryption, so this loads the NSS libraries shipped
    /// with the Thunderbird application.
    public static func read(
        profile: ThunderbirdProfile,
        nssDirectory: URL? = nil
    ) throws -> [ThunderbirdCredential] {
        let loginsURL = profile.path.appendingPathComponent("logins.json")
        let loginsData: Data
        do {
            loginsData = try Data(contentsOf: loginsURL)
        } catch {
            throw ThunderbirdCredentialError.invalidLoginsFile(error.localizedDescription)
        }

        let file: LoginsFile
        do {
            file = try JSONDecoder().decode(LoginsFile.self, from: loginsData)
        } catch {
            throw ThunderbirdCredentialError.invalidLoginsFile(error.localizedDescription)
        }

        let directory = try locateNSSDirectory(explicit: nssDirectory)
        lock.lock()
        defer { lock.unlock() }

        let nss = try ThunderbirdNSS(directory: directory)
        let initStatus = nss.initialize(profile.path)
        guard initStatus == 0 else {
            throw ThunderbirdCredentialError.nssInitializationFailed(initStatus)
        }
        defer { nss.shutdown() }

        var credentials: [ThunderbirdCredential] = []
        for login in file.logins {
            guard let encryptedUsername = login.encryptedUsername,
                  let encryptedPassword = login.encryptedPassword,
                  !encryptedUsername.isEmpty,
                  !encryptedPassword.isEmpty else {
                continue
            }

            let scheme = scheme(for: login.hostname)
            let host = host(for: login.hostname)
            let isOAuth = scheme == .oauth || host.lowercased().contains("accounts.google.com")

            let username: String
            do {
                username = try nss.decrypt(encryptedUsername, host: host)
            } catch let error as ThunderbirdCredentialError {
                throw error
            } catch {
                throw ThunderbirdCredentialError.decryptionFailed(host: host, code: 0)
            }

            if isOAuth {
                credentials.append(
                    ThunderbirdCredential(
                        hostname: login.hostname,
                        host: host,
                        scheme: .oauth,
                        username: username,
                        password: "",
                        isOAuth: true
                    )
                )
                continue
            }

            let password: String
            do {
                password = try nss.decrypt(encryptedPassword, host: host)
            } catch let error as ThunderbirdCredentialError {
                throw error
            } catch {
                throw ThunderbirdCredentialError.decryptionFailed(host: host, code: 0)
            }

            credentials.append(
                ThunderbirdCredential(
                    hostname: login.hostname,
                    host: host,
                    scheme: scheme,
                    username: username,
                    password: password
                )
            )
        }
        return credentials
    }

    // MARK: Parsing

    private struct LoginsFile: Decodable {
        struct Login: Decodable {
            var hostname: String
            var encryptedUsername: String?
            var encryptedPassword: String?
            var encType: Int?
        }

        var logins: [Login]
    }

    private static func scheme(for hostname: String) -> ThunderbirdCredential.Scheme {
        let raw = hostname
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .lowercased() ?? ""
        switch raw {
        case "imap":
            return .imap
        case "smtp":
            return .smtp
        case "mailbox":
            return .mailbox
        case "pop3", "pop":
            return .pop3
        case "oauth":
            return .oauth
        default:
            return .other
        }
    }

    private static func host(for hostname: String) -> String {
        if let host = URLComponents(string: hostname)?.host, !host.isEmpty {
            return host
        }
        // `mailbox://user@host` and similar URIs always parse, but keep a
        // simple fallback for malformed entries.
        if let schemeRange = hostname.range(of: "://") {
            let rest = hostname[schemeRange.upperBound...]
            let withoutPath = rest.split(separator: "/").first.map(String.init) ?? String(rest)
            if let at = withoutPath.lastIndex(of: "@") {
                return String(withoutPath[withoutPath.index(after: at)...])
            }
            return withoutPath
        }
        return hostname
    }

    // MARK: NSS discovery

    private static let lock = NSRecursiveLock()

    private static func locateNSSDirectory(explicit: URL?) throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let explicit {
            candidates.append(explicit)
        }
        if let environment = ProcessInfo.processInfo.environment["MAILR_NSS_PATH"],
           !environment.isEmpty {
            candidates.append(URL(fileURLWithPath: (environment as NSString).expandingTildeInPath))
        }

        #if os(macOS)
        let home = URL(fileURLWithPath: NSHomeDirectory())
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/Applications/Thunderbird.app/Contents/MacOS"),
            home.appendingPathComponent("Applications/Thunderbird.app/Contents/MacOS")
        ])
        #else
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/usr/lib"),
            URL(fileURLWithPath: "/usr/lib64"),
            URL(fileURLWithPath: "/usr/lib/x86_64-linux-gnu"),
            URL(fileURLWithPath: "/usr/lib/aarch64-linux-gnu")
        ])
        #endif

        for candidate in candidates {
            #if os(macOS)
            let nss = candidate.appendingPathComponent("libnss3.dylib")
            #else
            let nss = candidate.appendingPathComponent("libnss3.so")
            #endif
            if fileManager.fileExists(atPath: nss.path) {
                return candidate
            }
        }

        throw ThunderbirdCredentialError.nssNotFound(
            "Tried \(candidates.map(\.path).joined(separator: ", ")). Set MAILR_NSS_PATH or pass --nss."
        )
    }
}

// MARK: - NSS bridge

private final class ThunderbirdNSS {
    private typealias InitFunction = @convention(c) (UnsafePointer<CChar>) -> Int32
    private typealias ShutdownFunction = @convention(c) () -> Int32
    private typealias DecryptFunction = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?
    ) -> Int32
    private typealias FreeItemFunction = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias GetErrorFunction = @convention(c) () -> Int32

    private struct SECItem {
        var type: UInt32
        var data: UnsafeMutablePointer<UInt8>?
        var len: UInt32
    }

    private let nssHandle: UnsafeMutableRawPointer
    private var mozglueHandle: UnsafeMutableRawPointer? = nil
    private let nssInit: InitFunction
    private let nssShutdown: ShutdownFunction
    private let decryptFunction: DecryptFunction
    private let freeItemFunction: FreeItemFunction
    private let getErrorFunction: GetErrorFunction

    init(directory: URL) throws {
        #if os(macOS)
        let mozgluePath = directory.appendingPathComponent("libmozglue.dylib").path
        mozglueHandle = dlopen(mozgluePath, RTLD_NOW | RTLD_GLOBAL)
        let nssPath = directory.appendingPathComponent("libnss3.dylib").path
        #else
        let nssPath = directory.appendingPathComponent("libnss3.so").path
        #endif

        guard let handle = dlopen(nssPath, RTLD_NOW | RTLD_GLOBAL) else {
            let detail = dlerror().map { String(cString: $0) } ?? nssPath
            throw ThunderbirdCredentialError.nssNotFound(detail)
        }
        nssHandle = handle

        nssInit = try Self.load(handle, "NSS_Init")
        nssShutdown = try Self.load(handle, "NSS_Shutdown")
        decryptFunction = try Self.load(handle, "PK11SDR_Decrypt")
        freeItemFunction = try Self.load(handle, "SECITEM_FreeItem")
        getErrorFunction = try Self.load(handle, "PR_GetError")
    }

    deinit {
        dlclose(nssHandle)
        if let mozglueHandle {
            dlclose(mozglueHandle)
        }
    }

    func initialize(_ profilePath: URL) -> Int32 {
        profilePath.path.withCString { nssInit($0) }
    }

    func shutdown() {
        _ = nssShutdown()
    }

    func decrypt(_ base64: String, host: String) throws -> String {
        guard let decoded = Data(base64Encoded: base64) else {
            throw ThunderbirdCredentialError.decryptionFailed(host: host, code: SecError.badDER)
        }

        var buffer = [UInt8](decoded)
        var output = SECItem(type: 0, data: nil, len: 0)
        var status: Int32 = -1

        buffer.withUnsafeMutableBufferPointer { pointer in
            var input = SECItem(
                type: 0,
                data: pointer.baseAddress,
                len: UInt32(pointer.count)
            )
            withUnsafeMutablePointer(to: &input) { inputPointer in
                withUnsafeMutablePointer(to: &output) { outputPointer in
                    status = decryptFunction(
                        UnsafeMutableRawPointer(inputPointer),
                        UnsafeMutableRawPointer(outputPointer),
                        nil
                    )
                }
            }
        }

        defer {
            if output.data != nil {
                withUnsafeMutablePointer(to: &output) { pointer in
                    freeItemFunction(UnsafeMutableRawPointer(pointer), 0)
                }
            }
        }

        guard status == 0, let data = output.data else {
            let code = getErrorFunction()
            if code == SecError.badPassword || code == SecError.lockedPassword {
                throw ThunderbirdCredentialError.profileLocked
            }
            throw ThunderbirdCredentialError.decryptionFailed(host: host, code: code)
        }

        let bytes = Data(bytes: data, count: Int(output.len))
        return String(data: bytes, encoding: .utf8)
            ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func load<T>(_ handle: UnsafeMutableRawPointer, _ name: String) throws -> T {
        guard let symbol = dlsym(handle, name) else {
            throw ThunderbirdCredentialError.nssNotFound("Missing NSS symbol \(name).")
        }
        return unsafeBitCast(symbol, to: T.self)
    }
}

private enum SecError {
    // SEC_ERROR_BASE is -0x2000.
    static let badDER: Int32 = -8183
    static let badPassword: Int32 = -8177
    static let lockedPassword: Int32 = -8180
}
