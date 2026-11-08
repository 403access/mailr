import Foundation
import MailCore

// A tiny host-side archive for Mailr.
//
// Run it with `make server` (or `swift run MailrServer`) while Mailr is open.
// Every message the client retrieves is mirrored here over loopback HTTP, so
// the reader can tell whether a message is still in the IMAP mailbox, only in
// this archive, or in both.

@main
struct MailrServerCommand {
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        let arguments = CommandLine.arguments

        func value(flag: String, environment variable: String) -> String? {
            if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count {
                return arguments[index + 1]
            }
            return environment[variable]
        }

        let rawPort = value(flag: "--port", environment: "MAILR_HOST_PORT") ?? "8787"
        guard let port = UInt16(rawPort), port > 0 else {
            FileHandle.standardError.write(Data("Invalid port: \(rawPort)\n".utf8))
            exit(2)
        }

        let host = value(flag: "--host", environment: "MAILR_HOST_BIND") ?? "127.0.0.1"
        let databasePath = value(flag: "--database", environment: "MAILR_HOST_DATABASE")
        let databaseURL = databasePath.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        } ?? MailDatabase.hostURL

        let database = MailDatabase(fileURL: databaseURL)

        func positiveInt(_ key: String, default defaultValue: Int) -> Int {
            guard let raw = environment[key], let value = Int(raw), value > 0 else {
                return defaultValue
            }
            return value
        }

        func enabled(_ key: String) -> Bool {
            guard let raw = environment[key]?.lowercased() else { return false }
            return ["1", "true", "yes", "on"].contains(raw)
        }

        let syncConfiguration = HostMailSyncEngine.Configuration(
            interval: TimeInterval(positiveInt("MAILR_HOST_SYNC_INTERVAL", default: 300)),
            messageLimit: positiveInt("MAILR_HOST_SYNC_LIMIT", default: 100),
            prefetchBodyLimit: positiveInt("MAILR_HOST_PREFETCH", default: 20),
            syncAllMailboxes: enabled("MAILR_HOST_SYNC_ALL")
        )
        let syncEngine = HostMailSyncEngine(
            database: database,
            configuration: syncConfiguration
        )
        let server = HostMailServer(
            port: port,
            host: host,
            database: database,
            syncEngine: syncEngine
        )

        do {
            try server.start()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }

        let boundPort = server.boundPort ?? port
        print("Mailr host server listening on http://\(host):\(boundPort)")
        print("Database: \(databaseURL.path)")
        print("IMAP sync: every \(Int(syncConfiguration.interval))s, newest \(syncConfiguration.messageLimit) messages per mailbox")
        print("Set MAILR_HOST_SERVER=http://\(host):\(boundPort) in .env if the client uses another address.")
        print("Press Control-C to stop.")

        dispatchMain()
    }
}
