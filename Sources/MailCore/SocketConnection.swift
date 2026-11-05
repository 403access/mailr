import Foundation
import Network

/// A small async byte-stream wrapper around `NWConnection`.
///
/// Mailr deliberately supports implicit TLS only. That covers the standard
/// modern ports (IMAP 993, SMTP 465) used by iCloud, Gmail, Fastmail, Yahoo,
/// Zoho and self-hosted servers. STARTTLS-only ports are rejected up front
/// rather than silently sending credentials in the clear.
public actor SocketConnection {
    private let host: String
    private let port: UInt16
    private let useTLS: Bool
    private let serverName: String
    private let queue = DispatchQueue(label: "app.mailr.socket")

    private var connection: NWConnection?
    private var buffer = Data()
    private var closed = false

    public init(host: String, port: UInt16, useTLS: Bool, serverName: String? = nil) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.serverName = serverName ?? host
    }

    public func connect(timeout: TimeInterval = 30) async throws {
        guard connection == nil else { return }

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout)
        tcp.noDelay = true

        let parameters: NWParameters
        if useTLS {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            serverName.withCString { name in
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, name)
            }
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        parameters.allowLocalEndpointReuse = true

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw MailError.connection("Invalid port \(port).")
        }

        let newConnection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: parameters
        )
        connection = newConnection
        closed = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let once = OneShotContinuation(continuation)

            newConnection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(returning: ())
                case .failed(let error):
                    once.resume(throwing: MailError.connection(error.localizedDescription))
                case .cancelled:
                    once.resume(throwing: MailError.connection("The connection was cancelled."))
                case .waiting(let error):
                    // `waiting` can recover (for example, while Wi-Fi comes up).
                    // The timeout task below eventually reports a useful error.
                    _ = error
                default:
                    break
                }
            }
            newConnection.start(queue: queue)

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                once.resume(throwing: MailError.connection("Connecting to \(host) timed out."))
            }
        }
    }

    public func readLine() async throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                var line = String(decoding: lineData, as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                return line
            }

            if buffer.count > 4 * 1024 * 1024 {
                throw MailError.protocolViolation("A server response line was too long.")
            }
            let chunk = try await receiveChunk()
            if chunk.isEmpty { continue }
            buffer.append(chunk)
        }
    }

    public func readExact(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        while buffer.count < count {
            let chunk = try await receiveChunk()
            if chunk.isEmpty { continue }
            buffer.append(chunk)
        }
        let data = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return data
    }

    public func write(_ string: String) async throws {
        try await write(Data(string.utf8))
    }

    public func write(_ data: Data) async throws {
        guard let connection, !closed else {
            throw MailError.connection("The connection is not open.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MailError.connection(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func close() {
        closed = true
        buffer.removeAll()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func receiveChunk() async throws -> Data {
        guard let connection, !closed else {
            throw MailError.connection("The connection is not open.")
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: MailError.connection(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: MailError.connection("The server closed the connection."))
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

/// Guards a continuation so competing callbacks (state change vs. timeout)
/// cannot resume it twice.
private final class OneShotContinuation<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, any Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let stored = continuation
        continuation = nil
        lock.unlock()
        stored?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let stored = continuation
        continuation = nil
        lock.unlock()
        stored?.resume(throwing: error)
    }
}
