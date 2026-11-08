import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - HTTP primitives

public struct HostHTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public init(
        method: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public struct HostHTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data

    public init(status: Int, contentType: String = "application/json", body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HostHTTPResponse {
        do {
            return HostHTTPResponse(status: status, body: try JSONEncoder().encode(value))
        } catch {
            let fallback = #"{"error":"Could not encode the response."}"#
            return HostHTTPResponse(status: 500, body: Data(fallback.utf8))
        }
    }

    public static func error(_ message: String, status: Int) -> HostHTTPResponse {
        let body = (try? JSONEncoder().encode(HostErrorResponse(error: message)))
            ?? Data(#"{"error":"Request failed."}"#.utf8)
        return HostHTTPResponse(status: status, body: body)
    }

    var serialized: Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 201: reason = "Created"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        case 500: reason = "Internal Server Error"
        default: reason = "Error"
        }

        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

// MARK: - Request parsing

enum HostHTTPParseResult {
    case incomplete
    case malformed(String)
    case request(HostHTTPRequest)
}

enum HostHTTPParser {
    static let maximumHeaderBytes = 64 * 1024
    static let maximumBodyBytes = 64 * 1024 * 1024

    static func parse(_ data: Data) -> HostHTTPParseResult {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerRange = data.range(of: separator) else {
            if data.count > maximumHeaderBytes {
                return .malformed("Request headers are too large.")
            }
            return .incomplete
        }

        let headerData = data[data.startIndex..<headerRange.lowerBound]
        let bodyStart = headerRange.upperBound
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .malformed("Request headers are not valid UTF-8.")
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            return .malformed("The request line is missing.")
        }

        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else {
            return .malformed("The request line is malformed.")
        }

        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0, contentLength <= maximumBodyBytes else {
            return .malformed("The request body is too large.")
        }
        guard data.count - bodyStart >= contentLength else {
            return .incomplete
        }

        let body = data[bodyStart..<(bodyStart + contentLength)]

        let components = URLComponents(string: "http://localhost\(target)")
        let path = components?.path ?? target
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            if let value = item.value {
                query[item.name] = value
            }
        }

        return .request(
            HostHTTPRequest(
                method: method,
                path: path,
                query: query,
                headers: headers,
                body: Data(body)
            )
        )
    }
}

// MARK: - Router

/// Maps host archive HTTP routes onto ``MailDatabase``. It is intentionally
/// synchronous so it can be unit tested without opening a socket.
public struct HostMailRouter: Sendable {
    public let database: MailDatabase

    public init(database: MailDatabase) {
        self.database = database
    }

    public func handle(_ request: HostHTTPRequest) -> HostHTTPResponse {
        do {
            switch (request.method, request.path) {
            case ("GET", "/health"):
                return .json(HostMailHealth(
                    status: "ok",
                    messageCount: (try? database.messageCount()) ?? 0,
                    databasePath: database.fileURL?.path ?? ":memory:"
                ))

            case ("POST", "/v1/sync/mailbox"):
                let payload = try decode(HostMailboxSyncRequest.self, request.body)
                try database.syncMailbox(
                    payload.messages,
                    accountID: payload.accountID,
                    mailbox: payload.mailbox,
                    absentUIDs: payload.absentUIDs
                )
                return .json(HostSyncResponse(stored: payload.messages.count))

            case ("GET", "/v1/messages/list"):
                let accountID = try uuid(request.query["accountID"])
                let mailbox = try text(request.query["mailbox"])
                let limit = Int(request.query["limit"] ?? "200") ?? 200
                let messages = try database.loadMessages(
                    accountID: accountID,
                    mailbox: mailbox,
                    limit: min(max(limit, 1), 1_000)
                )
                return .json(messages)

            case ("POST", "/v1/messages"):
                let payload = try decode(HostMessageEnvelope.self, request.body)
                try database.saveMessage(payload.message, accountID: payload.accountID)
                return .json(HostSyncResponse(stored: 1))

            case ("GET", "/v1/messages"):
                let accountID = try uuid(request.query["accountID"])
                let mailbox = try text(request.query["mailbox"])
                let uid = try uid(request.query["uid"])
                let message = try database.loadMessage(
                    accountID: accountID,
                    mailbox: mailbox,
                    uid: uid
                )
                return .json(HostMessageResponse(message: message))

            case ("DELETE", "/v1/messages"):
                let accountID = try uuid(request.query["accountID"])
                let mailbox = try text(request.query["mailbox"])
                let uid = try uid(request.query["uid"])
                try database.deleteMessage(accountID: accountID, mailbox: mailbox, uid: uid)
                return .json(HostDeleteResponse(deleted: true))

            case ("POST", "/v1/move"):
                let payload = try decode(HostMoveRequest.self, request.body)
                let moved = try database.moveMessage(
                    accountID: payload.accountID,
                    from: payload.source,
                    uid: payload.uid,
                    to: payload.destination
                ) != nil
                return .json(HostMoveResponse(moved: moved))

            case ("POST", "/v1/flags"):
                let payload = try decode(HostFlagsRequest.self, request.body)
                try database.updateFlags(
                    accountID: payload.accountID,
                    mailbox: payload.mailbox,
                    uid: payload.uid,
                    isRead: payload.isRead,
                    isFlagged: payload.isFlagged,
                    isAnswered: payload.isAnswered
                )
                return .json(HostSyncResponse(stored: 1))

            case ("GET", "/v1/storage"):
                let accountID = try uuid(request.query["accountID"])
                let mailbox = try text(request.query["mailbox"])
                let uid = try uid(request.query["uid"])
                let onHost = try database.hasMessage(
                    accountID: accountID,
                    mailbox: mailbox,
                    uid: uid
                )
                let onMailbox = (try database.isOnMailbox(
                    accountID: accountID,
                    mailbox: mailbox,
                    uid: uid
                )) ?? false
                return .json(HostStorageResponse(
                    accountID: accountID,
                    mailbox: mailbox,
                    uid: uid,
                    onMailbox: onMailbox,
                    onHost: onHost
                ))

            case ("GET", "/v1/mailboxes"):
                let accountID = try uuid(request.query["accountID"])
                return .json(try database.loadMailboxes(accountID: accountID))

            case ("POST", "/v1/mailboxes"):
                let payload = try decode(HostMailboxListRequest.self, request.body)
                try database.saveMailboxes(payload.mailboxes, accountID: payload.accountID)
                return .json(HostSyncResponse(stored: payload.mailboxes.count))

            default:
                return .error("No route for \(request.method) \(request.path).", status: 404)
            }
        } catch let error as RouteError {
            return .error(error.message, status: 400)
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    private struct RouteError: Error {
        let message: String
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RouteError(message: "Invalid JSON body: \(error.localizedDescription)")
        }
    }

    private func uuid(_ raw: String?) throws -> UUID {
        guard let raw, let value = UUID(uuidString: raw) else {
            throw RouteError(message: "A valid accountID is required.")
        }
        return value
    }

    private func uid(_ raw: String?) throws -> UInt32 {
        guard let raw, let value = UInt32(raw) else {
            throw RouteError(message: "A valid uid is required.")
        }
        return value
    }

    private func text(_ raw: String?) throws -> String {
        guard let raw, !raw.isEmpty else {
            throw RouteError(message: "A mailbox is required.")
        }
        return raw
    }
}

// MARK: - Server

/// A small loopback-only HTTP server that keeps every message the client has
/// retrieved. It is intentionally dependency-free and speaks just enough
/// HTTP/1.1 for the Mailr host archive.
public final class HostMailServer: @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public let database: MailDatabase
    public private(set) var boundPort: UInt16?

    private let router: HostMailRouter
    private let queue = DispatchQueue(label: "app.mailr.host-server", attributes: .concurrent)
    private let stateLock = NSLock()
    private var socketFD: Int32 = -1
    private var running = false

    public init(
        port: UInt16 = 8787,
        host: String = "127.0.0.1",
        database: MailDatabase = MailDatabase(fileURL: MailDatabase.hostURL)
    ) {
        self.port = port
        self.host = host
        self.database = database
        self.router = HostMailRouter(database: database)
    }

    deinit {
        stop()
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !running else { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw HostMailError.unavailable("Could not create a listening socket (\(errno)).")
        }

        var reuse: Int32 = 1
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        #if canImport(Darwin)
        setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        #endif

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian

        let numericHost = host.lowercased() == "localhost" ? "127.0.0.1" : host
        var networkAddress = in_addr()
        guard inet_pton(AF_INET, numericHost, &networkAddress) == 1 else {
            close(fd)
            throw HostMailError.unavailable("“\(host)” is not a valid IPv4 address.")
        }
        address.sin_addr = networkAddress

        let bindResult: Int32 = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw HostMailError.unavailable(
                "Could not bind to \(host):\(port) (\(code)). "
                    + "Another Mailr host archive may already be running."
            )
        }

        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw HostMailError.unavailable("Could not listen on \(host):\(port) (\(code)).")
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult: Int32 = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(fd, socketAddress, &boundLength)
            }
        }
        if nameResult == 0 {
            boundPort = UInt16(bigEndian: boundAddress.sin_port)
        }

        socketFD = fd
        running = true
        queue.async { [weak self] in
            self?.acceptLoop(fd)
        }
    }

    public func stop() {
        stateLock.lock()
        let fd = socketFD
        socketFD = -1
        running = false
        stateLock.unlock()

        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    // MARK: Connections

    private func acceptLoop(_ fd: Int32) {
        while true {
            var clientAddress = sockaddr()
            var clientLength = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fd, &clientAddress, &clientLength)

            if client < 0 {
                if errno == EINTR { continue }
                break
            }

            configure(client)
            queue.async { [weak self] in
                guard let self else {
                    close(client)
                    return
                }
                self.handleClient(client)
                close(client)
            }
        }
    }

    private func configure(_ client: Int32) {
        var reuse: Int32 = 1
        #if canImport(Darwin)
        setsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        #endif
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(
            client,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    private func handleClient(_ client: Int32) {
        var buffer = Data()

        while buffer.count <= HostHTTPParser.maximumBodyBytes + HostHTTPParser.maximumHeaderBytes {
            switch HostHTTPParser.parse(buffer) {
            case .request(let request):
                let response = router.handle(request)
                writeAll(client, response.serialized)
                return

            case .malformed(let message):
                let response = HostHTTPResponse.error(message, status: 400)
                writeAll(client, response.serialized)
                return

            case .incomplete:
                var chunk = [UInt8](repeating: 0, count: 16 * 1024)
                let count = recv(client, &chunk, chunk.count, 0)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }

        let response = HostHTTPResponse.error("The request is too large.", status: 413)
        writeAll(client, response.serialized)
    }

    private func writeAll(_ client: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let sent = send(client, base.advanced(by: offset), raw.count - offset, 0)
                if sent <= 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += sent
            }
        }
    }
}
