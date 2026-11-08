import Foundation
import MailCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct MailrImportCommand {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return
        }

        do {
            let options = try ImportOptions(arguments: arguments)
            let code = try await run(options)
            if code != 0 { exit(code) }
        } catch {
            writeError(error.localizedDescription)
            writeError("")
            printUsage()
            exit(2)
        }
    }

    // MARK: - Commands

    private static func run(_ options: ImportOptions) async throws -> Int32 {
        let roots = options.root.map { [$0] } ?? ThunderbirdProfiles.defaultRoots()
        let profiles = try selectProfiles(options: options, roots: roots)

        if options.command == .list {
            list(profiles: profiles, roots: roots)
            return 0
        }

        let databaseURL = options.databaseURL ?? MailDatabase.defaultURL
        print("Mailr database: \(databaseURL.path)")
        print("")

        let database = MailDatabase(fileURL: databaseURL)

        if options.command == .credentials {
            var failed = false
            for profile in profiles {
                print("Profile: \(profile.name)")
                do {
                    let summary = try ThunderbirdCredentialImporter.importCredentials(
                        profile: profile,
                        database: database,
                        nssDirectory: options.nssDirectory,
                        dryRun: options.dryRun
                    )
                    printCredentialSummary(summary)
                } catch {
                    writeError("  \(error.localizedDescription)")
                    failed = true
                }
                print("")
            }
            if options.dryRun {
                print("Dry run complete. No passwords were written.")
            }
            return failed ? 1 : 0
        }

        var totalMessages = 0
        var hadIssues = false

        for profile in profiles {
            print("Profile: \(profile.name)")
            print("  \(profile.path.path)")

            let importer: ThunderbirdImporter
            do {
                importer = try ThunderbirdImporter(profile: profile)
            } catch {
                writeError("  Could not read this profile: \(error.localizedDescription)")
                hadIssues = true
                continue
            }

            let summary = try importer.importInto(
                database: database,
                options: options.importOptions
            )
            totalMessages += summary.messageCount
            hadIssues = hadIssues || !summary.issues.isEmpty
            printSummary(summary)

            if options.importPasswords {
                do {
                    let credentialSummary = try ThunderbirdCredentialImporter.importCredentials(
                        profile: profile,
                        database: database,
                        nssDirectory: options.nssDirectory,
                        dryRun: options.importOptions.dryRun
                    )
                    printCredentialSummary(credentialSummary)
                } catch {
                    hadIssues = true
                    writeError("  Password import: \(error.localizedDescription)")
                }
            }
            print("")
        }

        if options.importOptions.dryRun {
            print("Dry run complete. No changes were written.")
        } else {
            print("Imported \(totalMessages) message\(totalMessages == 1 ? "" : "s").")
            print("Quit and reopen Mailr to see the imported accounts and mail.")
        }
        if hadIssues {
            print("Some items need attention; see the notes above.")
        }

        return 0
    }

    // MARK: - Listing

    private static func list(profiles: [ThunderbirdProfile], roots: [URL]) {
        print("Thunderbird data directories:")
        for root in roots {
            print("  \(root.path)")
        }
        print("")

        for profile in profiles {
            print("Profile: \(profile.name)\(profile.isDefault ? " (default)" : "")")
            print("  \(profile.path.path)")

            let importer: ThunderbirdImporter
            do {
                importer = try ThunderbirdImporter(profile: profile)
            } catch {
                writeError("  Could not read this profile: \(error.localizedDescription)")
                print("")
                continue
            }

            let accounts = importer.accounts()
            if accounts.isEmpty {
                print("  Accounts: none")
            } else {
                print("  Accounts:")
                for account in accounts {
                    print("    \(account.emailAddress)  [\(account.serverType.displayName)]")
                    if let incoming = account.incoming {
                        let tls = account.incomingUsesStartTLS ? "STARTTLS (unsupported)" : incoming.security.displayName
                        print("      incoming  \(incoming.host):\(incoming.port)  \(tls)")
                    }
                    if let outgoing = account.outgoing {
                        let tls = account.outgoingUsesStartTLS ? "STARTTLS (unsupported)" : outgoing.security.displayName
                        print("      outgoing  \(outgoing.host):\(outgoing.port)  \(tls)")
                    }
                    for issue in account.issues {
                        print("      note      \(issue)")
                    }
                }
            }

            let sources = importer.localSources(includeIMAPCache: true)
            if sources.isEmpty {
                print("  Local mail: none")
            } else {
                print("  Local mail:")
                for source in sources {
                    let folders = ThunderbirdLocalStore.discoverFolders(in: source)
                    print("    \(source.label)  (\(source.serverType.displayName), \(folders.count) folder\(folders.count == 1 ? "" : "s"))")
                    print("      \(source.directory.path)")
                    for folder in folders.prefix(12) {
                        print("        \(folder.path)  [\(folder.format == .mbox ? "mbox" : "maildir")]")
                    }
                    if folders.count > 12 {
                        print("        … \(folders.count - 12) more")
                    }
                }
            }

            let logins = profile.path.appendingPathComponent("logins.json")
            if FileManager.default.fileExists(atPath: logins.path) {
                print("  Passwords: encrypted by Thunderbird; run `mailr-import credentials` to import them.")
            }
            print("")
        }
    }

    // MARK: - Summary

    private static func printSummary(_ summary: ThunderbirdImportSummary) {
        if !summary.accountsCreated.isEmpty {
            print(summary.isDryRun ? "  Would create accounts:" : "  Created accounts:")
            for email in summary.accountsCreated {
                print("    \(email)")
            }
        }
        if !summary.accountsUpdated.isEmpty {
            print(summary.isDryRun ? "  Would update accounts:" : "  Updated accounts:")
            for email in summary.accountsUpdated {
                print("    \(email)")
            }
        }
        if !summary.accountsSkipped.isEmpty {
            print("  Skipped accounts:")
            for email in summary.accountsSkipped {
                print("    \(email)")
            }
        }
        if let name = summary.localAccountName, let email = summary.localAccountEmail {
            print("  Local mail account:")
            print("    \(name) <\(email)>")
            print("    \(summary.mailboxes.count) mailbox\(summary.mailboxes.count == 1 ? "" : "es"), \(summary.messageCount) message\(summary.messageCount == 1 ? "" : "s")")
        }
        if !summary.issues.isEmpty {
            print("  Notes:")
            for issue in summary.issues {
                print("    \(issue)")
            }
        }
        if summary.accountsCreated.isEmpty,
           summary.accountsUpdated.isEmpty,
           summary.localAccountName == nil,
           summary.issues.isEmpty {
            print("  Nothing to import.")
        }
    }

    private static func printCredentialSummary(_ summary: ThunderbirdCredentialImportSummary) {
        if !summary.imported.isEmpty {
            print("  Imported passwords:")
            for email in summary.imported {
                print("    \(email)")
            }
        }
        if !summary.wouldImport.isEmpty {
            print("  Would import passwords:")
            for email in summary.wouldImport {
                print("    \(email)")
            }
        }
        if !summary.oauthSkipped.isEmpty {
            print("  OAuth entries skipped (Mailr needs an app password):")
            for entry in summary.oauthSkipped {
                print("    \(entry)")
            }
        }
        if !summary.unmatched.isEmpty {
            print("  Unmatched Thunderbird logins:")
            for entry in summary.unmatched {
                print("    \(entry)")
            }
        }
        if summary.imported.isEmpty,
           summary.wouldImport.isEmpty,
           summary.oauthSkipped.isEmpty,
           summary.unmatched.isEmpty {
            print("  No saved Thunderbird passwords found.")
        }
    }

    // MARK: - Profile selection

    private static func selectProfiles(
        options: ImportOptions,
        roots: [URL]
    ) throws -> [ThunderbirdProfile] {
        var discovered: [ThunderbirdProfile] = []

        for selector in options.profileSelectors {
            let candidate = URL(fileURLWithPath: (selector as NSString).expandingTildeInPath)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                if let direct = try? ThunderbirdProfiles.discover(root: candidate) {
                    discovered.append(contentsOf: direct)
                }
            }
        }

        do {
            discovered.append(contentsOf: try ThunderbirdProfiles.discoverAll(roots: roots))
        } catch {
            // An explicit --profile still works when the platform default
            // directory is missing.
            if discovered.isEmpty { throw error }
        }
        discovered = deduplicateProfiles(discovered)

        if options.allProfiles {
            return discovered
        }

        guard !options.profileSelectors.isEmpty else {
            if discovered.count == 1 {
                return discovered
            }
            guard !discovered.isEmpty else {
                throw ImportCLIError.noProfiles
            }
            let names = discovered.map { "  \($0.name)  \($0.path.path)" }.joined(separator: "\n")
            throw ImportCLIError.profileSelectionRequired(names)
        }

        var selected: [ThunderbirdProfile] = []
        for selector in options.profileSelectors {
            let standardized = URL(fileURLWithPath: (selector as NSString).expandingTildeInPath)
                .standardizedFileURL
            let matches = discovered.filter { profile in
                profile.id == standardized.path
                    || profile.name.caseInsensitiveCompare(selector) == .orderedSame
                    || profile.path.lastPathComponent.caseInsensitiveCompare(selector) == .orderedSame
            }
            guard let match = matches.first else {
                throw ImportCLIError.profileNotFound(selector)
            }
            selected.append(match)
        }

        return deduplicateProfiles(selected)
    }

    private static func deduplicateProfiles(_ profiles: [ThunderbirdProfile]) -> [ThunderbirdProfile] {
        var seen = Set<String>()
        return profiles.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Output

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func printUsage() {
        print("""
        mailr-import — import Thunderbird account settings and local mail into Mailr

        USAGE:
          mailr-import list [options]
          mailr-import import [options]
          mailr-import credentials [options]

        COMMANDS:
          list                 Show Thunderbird profiles, accounts, and local mail folders.
          import               Import the selected profile(s). This is the default.
          credentials          Decrypt saved Thunderbird passwords and write them to Mailr's Keychain.

        OPTIONS:
          --profile <name|path>  Select a profile by name, folder name, or path.
                                 Repeat to import more than one profile.
          --all-profiles         Import every discovered profile.
          --root <path>          Thunderbird data directory (default: platform location).
          --database <path>      Mailr SQLite database (default: Application Support/Mailr/mailr.sqlite3).
          --accounts-only        Import account settings, not local mail.
          --mail-only            Import local mail, not account settings.
          --include-imap-cache   Also import Thunderbird's offline IMAP caches.
          --import-passwords     Also import saved Thunderbird passwords during `import`.
          --overwrite            Update Mailr accounts that already use the same email address.
          --nss <path>           Directory containing Thunderbird's libnss3 libraries.
          --dry-run              Report what would be imported without writing anything.
          -h, --help             Show this help.

        NOTES:
          Saved passwords are decrypted through Thunderbird's own NSS libraries.
          A Thunderbird primary password must be disabled or unlocked first.
          OAuth2 entries are reported but cannot be used as Mailr passwords.
          STARTTLS-only servers are skipped unless the provider has an implicit-TLS
          default that Mailr can use instead.
        """)
    }
}

// MARK: - Arguments

private struct ImportOptions {
    enum Command {
        case list
        case importMail
        case credentials
    }

    var command: Command = .importMail
    var root: URL?
    var profiles: [String] = []
    var allProfiles = false
    var accountsOnly = false
    var mailOnly = false
    var includeIMAPCache = false
    var overwrite = false
    var importPasswords = false
    var dryRun = false
    var databaseURL: URL?
    var nssDirectory: URL?

    var profileSelectors: [String] { profiles }

    var importOptions: ThunderbirdImportOptions {
        ThunderbirdImportOptions(
            includeAccounts: !mailOnly,
            includeMail: !accountsOnly,
            includeIMAPCache: includeIMAPCache,
            overwriteAccounts: overwrite,
            dryRun: dryRun
        )
    }

    init(arguments: [String]) throws {
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]

            switch argument {
            case "list":
                command = .list
            case "import":
                command = .importMail
            case "credentials":
                command = .credentials
            case "--profile":
                index += 1
                guard index < arguments.count else {
                    throw ImportCLIError.missingValue("--profile")
                }
                profiles.append(arguments[index])
            case "--all-profiles":
                allProfiles = true
            case "--root":
                index += 1
                guard index < arguments.count else {
                    throw ImportCLIError.missingValue("--root")
                }
                root = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath)
            case "--database":
                index += 1
                guard index < arguments.count else {
                    throw ImportCLIError.missingValue("--database")
                }
                databaseURL = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath)
            case "--accounts-only":
                accountsOnly = true
            case "--mail-only":
                mailOnly = true
            case "--include-imap-cache":
                includeIMAPCache = true
            case "--overwrite":
                overwrite = true
            case "--import-passwords":
                importPasswords = true
            case "--dry-run":
                dryRun = true
            case "--nss":
                index += 1
                guard index < arguments.count else {
                    throw ImportCLIError.missingValue("--nss")
                }
                nssDirectory = URL(fileURLWithPath: (arguments[index] as NSString).expandingTildeInPath)
            default:
                if argument.hasPrefix("--profile=") {
                    profiles.append(String(argument.dropFirst("--profile=".count)))
                } else if argument.hasPrefix("--root=") {
                    root = URL(fileURLWithPath: (String(argument.dropFirst("--root=".count)) as NSString).expandingTildeInPath)
                } else if argument.hasPrefix("--database=") {
                    databaseURL = URL(fileURLWithPath: (String(argument.dropFirst("--database=".count)) as NSString).expandingTildeInPath)
                } else if argument.hasPrefix("--nss=") {
                    nssDirectory = URL(fileURLWithPath: (String(argument.dropFirst("--nss=".count)) as NSString).expandingTildeInPath)
                } else {
                    throw ImportCLIError.unknownArgument(argument)
                }
            }

            index += 1
        }

        if accountsOnly && mailOnly {
            throw ImportCLIError.conflictingOptions("--accounts-only", "--mail-only")
        }
    }
}

private enum ImportCLIError: LocalizedError {
    case noProfiles
    case profileNotFound(String)
    case profileSelectionRequired(String)
    case missingValue(String)
    case unknownArgument(String)
    case conflictingOptions(String, String)

    var errorDescription: String? {
        switch self {
        case .noProfiles:
            "No Thunderbird profiles were found."
        case .profileNotFound(let selector):
            "No Thunderbird profile matched “\(selector)”."
        case .profileSelectionRequired(let names):
            "Several Thunderbird profiles were found. Choose one with --profile, or use --all-profiles:\n\(names)"
        case .missingValue(let option):
            "\(option) needs a value."
        case .unknownArgument(let argument):
            "Unknown argument “\(argument)”."
        case .conflictingOptions(let first, let second):
            "\(first) and \(second) cannot be used together."
        }
    }
}
