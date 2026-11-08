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
        let server = HostMailServer(port: port, host: host, database: database)

        do {
            try server.start()
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }

        let boundPort = server.boundPort ?? port
        print("Mailr host archive listening on http://\(host):\(boundPort)")
        print("Database: \(databaseURL.path)")
        print("Set MAILR_HOST_SERVER=http://\(host):\(boundPort) in .env if the client uses another address.")
        print("Press Control-C to stop.")

        dispatchMain()
    }
}
