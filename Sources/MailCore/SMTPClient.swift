import Foundation

/// Minimal SMTP submission client: EHLO, AUTH (LOGIN or PLAIN), MAIL, RCPT,
/// DATA. It opens one fresh TLS connection per outgoing message.
public actor SMTPClient {
    private let host: String
    private let port: UInt16
    private let security: ServerSecurity
    private let username: String
    private let password: String

    private var connection: SocketConnection?

    public init(
        host: String,
        port: Int,
        security: ServerSecurity,
        username: String,
        password: String
    ) {
        self.host = host
        self.port = UInt16(clamping: port)
        self.security = security
        self.username = username
        self.password = password
    }

    public func send(_ rawMessage: Data, from: String, recipients: [String]) async throws {
        guard !host.isEmpty, port > 0 else {
            throw MailError.notConfigured("The outgoing mail server is not configured.")
        }
        guard !recipients.isEmpty else {
            throw MailError.invalidMessage("Add at least one recipient.")
        }

        let socket = SocketConnection(
            host: host,
            port: port,
            useTLS: security == .tls,
            serverName: host
        )
        connection = socket

        do {
            try await socket.connect()
            let greeting = try await readReply()
            guard greeting.code == 220 else {
                throw MailError.connection("The SMTP server refused the connection: \(greeting.text)")
            }

            let ehlo = try await command("EHLO mailr.local")
            guard ehlo.code == 250 else {
                throw MailError.connection("The SMTP server rejected EHLO: \(ehlo.text)")
            }

            if !username.isEmpty {
                try await authenticate(using: capabilities(from: ehlo))
            }

            let safeFrom = sanitizeEnvelopeAddress(from)
            let mail = try await command("MAIL FROM:<\(safeFrom)>")
            guard mail.code == 250 else {
                throw MailError.commandFailed("The server rejected the sender: \(mail.text)")
            }

            for recipient in recipients {
                let safeRecipient = sanitizeEnvelopeAddress(recipient)
                let reply = try await command("RCPT TO:<\(safeRecipient)>")
                guard reply.code == 250 || reply.code == 251 || reply.code == 252 else {
                    throw MailError.commandFailed("The server rejected \(recipient): \(reply.text)")
                }
            }

            let dataReply = try await command("DATA")
            guard dataReply.code == 354 else {
                throw MailError.commandFailed("The server rejected the message body: \(dataReply.text)")
            }

            try await socket.write(dotStuffed(rawMessage) + ".\r\n")

            let accepted = try await readReply()
            guard accepted.code == 250 else {
                throw MailError.commandFailed("The server rejected the message: \(accepted.text)")
            }

            _ = try? await command("QUIT")
        } catch {
            await socket.close()
            connection = nil
            throw error
        }

        await socket.close()
        connection = nil
    }

    // MARK: - Authentication

    private func authenticate(using mechanisms: Set<String>) async throws {
        if mechanisms.contains("LOGIN") {
            try await authenticateLogin()
        } else if mechanisms.contains("PLAIN") {
            try await authenticatePlain()
        } else {
            throw MailError.unsupported(
                "This server does not offer a supported authentication method. Enable SMTP AUTH or use an app password."
            )
        }
    }

    private func authenticateLogin() async throws {
        let start = try await command("AUTH LOGIN")
        guard start.code == 334 else {
            throw MailError.authentication("The server rejected AUTH LOGIN: \(start.text)")
        }

        let userReply = try await command(Data(username.utf8).base64EncodedString())
        guard userReply.code == 334 else {
            throw MailError.authentication(userReply.text)
        }

        let passwordReply = try await command(Data(password.utf8).base64EncodedString())
        guard passwordReply.code == 235 else {
            throw MailError.authentication(passwordReply.text)
        }
    }

    private func authenticatePlain() async throws {
        let token = Data("\0\(username)\0\(password)".utf8).base64EncodedString()
        var reply = try await command("AUTH PLAIN \(token)")

        if reply.code == 334 {
            reply = try await command(token)
        }
        guard reply.code == 235 else {
            throw MailError.authentication(reply.text)
        }
    }

    private func capabilities(from reply: SMTPReply) -> Set<String> {
        var mechanisms: Set<String> = []
        for line in reply.continuations {
            let payload: String
            if line.count > 4 {
                payload = String(line.dropFirst(4))
            } else {
                payload = line
            }
            let upper = payload.uppercased()
            if upper.hasPrefix("AUTH ") || upper.hasPrefix("AUTH=") {
                let tokens = payload
                    .replacingOccurrences(of: "=", with: " ")
                    .split(whereSeparator: \.isWhitespace)
                    .dropFirst()
                    .map { String($0).uppercased() }
                mechanisms.formUnion(tokens)
            }
        }
        return mechanisms
    }

    // MARK: - Protocol plumbing

    private struct SMTPReply: Sendable {
        var code: Int
        var lines: [String]

        var continuations: [String] { lines }

        var text: String { lines.joined(separator: " ") }
    }

    private func command(_ text: String) async throws -> SMTPReply {
        guard let connection else {
            throw MailError.connection("Not connected to the outgoing mail server.")
        }
        try await connection.write(text + "\r\n")
        return try await readReply()
    }

    private func readReply() async throws -> SMTPReply {
        guard let connection else {
            throw MailError.connection("Not connected to the outgoing mail server.")
        }

        var lines: [String] = []
        var code: Int?

        while true {
            let line = try await connection.readLine()
            lines.append(line)

            if code == nil {
                guard line.count >= 3, let parsed = Int(line.prefix(3)) else {
                    throw MailError.protocolViolation("Unexpected SMTP reply: \(line)")
                }
                code = parsed
            }

            if line.count == 3 { break }
            if line.count > 3 {
                let separatorIndex = line.index(line.startIndex, offsetBy: 3)
                if line[separatorIndex] == " " { break }
            }
        }

        return SMTPReply(code: code ?? 0, lines: lines)
    }

    private func sanitizeEnvelopeAddress(_ address: String) -> String {
        address
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func dotStuffed(_ message: Data) -> String {
        let text = String(decoding: message, as: UTF8.self)
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let stuffed = lines.map { $0.hasPrefix(".") ? "." + $0 : $0 }
        return stuffed.joined(separator: "\r\n") + "\r\n"
    }
}
