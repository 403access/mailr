import Foundation

/// A small, single-connection IMAP client. Commands are serialized by the
/// actor; the service layer creates one client per account.
public actor IMAPClient {
    private let host: String
    private let port: UInt16
    private let security: ServerSecurity
    private let username: String
    private let password: String

    private var connection: SocketConnection?
    private var tagCounter = 0
    private var capabilities: Set<String> = []
    private var selectedMailbox: String?
    private var selectedExists = 0

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

    // MARK: - Connection lifecycle

    public func connect() async throws {
        guard connection == nil else { return }
        guard !host.isEmpty, port > 0 else {
            throw MailError.notConfigured("The incoming mail server is not configured.")
        }

        let socket = SocketConnection(
            host: host,
            port: port,
            useTLS: security == .tls,
            serverName: host
        )

        do {
            try await socket.connect()
            connection = socket

            let greeting = try await socket.readLine()
            let upperGreeting = greeting.uppercased()
            guard upperGreeting.hasPrefix("* OK") || upperGreeting.hasPrefix("* PREAUTH") else {
                throw MailError.connection("The server refused the connection: \(greeting)")
            }

            capabilities = try await capability()

            if !upperGreeting.hasPrefix("* PREAUTH") {
                if capabilities.contains("LOGINDISABLED") {
                    try await authenticatePlain()
                } else {
                    _ = try await execute("LOGIN \(IMAPSupport.quote(username)) \(IMAPSupport.quote(password))")
                }
                capabilities = try await capability()
            }
        } catch {
            await socket.close()
            connection = nil
            throw error
        }
    }

    public func disconnect() async {
        if connection != nil {
            _ = try? await execute("LOGOUT")
        }
        await connection?.close()
        connection = nil
        selectedMailbox = nil
        selectedExists = 0
    }

    // MARK: - Mailboxes

    public func listMailboxes() async throws -> [Mailbox] {
        let pieces = try await execute(#"LIST "" "*""#)

        struct Listing {
            var path: String
            var flags: Set<String>
            var delimiter: String?
        }

        var listings: [Listing] = []
        for case .line(let line) in pieces {
            guard let parsed = IMAPSupport.parseList(line) else { continue }
            if parsed.flags.contains("\\Noselect") || parsed.flags.contains("\\NonExistent") {
                continue
            }
            listings.append(Listing(path: parsed.name, flags: parsed.flags, delimiter: parsed.delimiter))
        }

        var boxes = listings.map { listing in
            Mailbox(
                path: listing.path,
                name: IMAPSupport.displayName(for: listing.path, delimiter: listing.delimiter),
                role: IMAPSupport.role(path: listing.path, flags: listing.flags),
                delimiter: listing.delimiter
            )
        }

        // STATUS is one round trip per folder. Large accounts can have
        // hundreds of folders, so ask for the important roles first and stop
        // spending time on optional counts once the budget is exhausted.
        let statusBudget: TimeInterval = {
            guard let raw = ProcessInfo.processInfo.environment["MAILR_IMAP_STATUS_BUDGET"],
                  let value = TimeInterval(raw) else {
                return 5
            }
            return max(0, value)
        }()
        let started = Date()
        let order = boxes.indices.sorted {
            boxes[$0].role.sortIndex < boxes[$1].role.sortIndex
        }

        for index in order {
            let role = boxes[index].role
            if role == .other, Date().timeIntervalSince(started) >= statusBudget {
                continue
            }
            guard let status = try? await status(path: boxes[index].path) else {
                continue
            }
            boxes[index].totalCount = status["MESSAGES"] ?? 0
            boxes[index].unreadCount = status["UNSEEN"] ?? 0
        }

        return Mailbox.sorted(boxes)
    }

    private func status(path: String) async throws -> [String: Int] {
        let pieces = try await execute("STATUS \(IMAPSupport.quote(path)) (MESSAGES UNSEEN UIDNEXT)")
        for case .line(let line) in pieces {
            if let parsed = IMAPSupport.parseStatus(line) {
                return parsed
            }
        }
        return [:]
    }

    private func select(mailbox: String) async throws {
        if selectedMailbox == mailbox { return }

        debugLog("SELECT \(IMAPSupport.quote(mailbox))")
        let pieces = try await execute("SELECT \(IMAPSupport.quote(mailbox))")
        let lines = pieces.compactMap { piece -> String? in
            if case .line(let line) = piece { return line }
            return nil
        }
        selectedMailbox = mailbox
        selectedExists = IMAPSupport.exists(in: lines)
    }

    // MARK: - Reading mail

    public func fetchSummaries(mailbox: String, limit: Int) async throws -> [MessageSummary] {
        try await select(mailbox: mailbox)
        guard selectedExists > 0, limit > 0 else { return [] }

        let start = max(1, selectedExists - limit + 1)
        let fields = [
            "DATE", "FROM", "TO", "CC", "SUBJECT", "MESSAGE-ID",
            "IN-REPLY-TO", "REFERENCES", "CONTENT-TYPE", "CONTENT-TRANSFER-ENCODING"
        ].joined(separator: " ")

        let command = "FETCH \(start):* (UID FLAGS INTERNALDATE RFC822.SIZE "
            + "BODY.PEEK[HEADER.FIELDS (\(fields))] BODY.PEEK[TEXT]<0.1024>)"
        let pieces = try await execute(command)
        let records = IMAPSupport.parseFetchRecords(pieces)

        var summaries: [MessageSummary] = []
        for record in records {
            guard let uidString = IMAPSupport.firstCapture(#"\bUID\s+(\d+)"#, in: record.text),
                  let uid = UInt32(uidString) else {
                continue
            }

            let headerData = record.literals.first(where: IMAPSupport.PartLiteralContext.header)?.data
            let previewData = record.literals.first(where: IMAPSupport.PartLiteralContext.preview)?.data ?? Data()

            let headers = headerData.map(HeaderMap.parse) ?? HeaderMap()
            let info = headerData.map(MessageParser.parseHeaderInfo)
                ?? ParsedMessage(headers: headers)
            let snippet = MessageParser.previewSnippet(headers: headers, partialBody: previewData)

            summaries.append(
                makeSummary(
                    uid: uid,
                    mailbox: mailbox,
                    record: record,
                    info: info,
                    snippet: snippet
                )
            )
        }

        return summaries.sorted {
            if $0.date == $1.date { return $0.uid > $1.uid }
            return $0.date > $1.date
        }
    }

    public func fetchMessage(mailbox: String, uid: UInt32) async throws -> MailMessage {
        try await select(mailbox: mailbox)

        let pieces = try await execute(
            "UID FETCH \(uid) (UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[])"
        )
        let records = IMAPSupport.parseFetchRecords(pieces)

        guard let record = records.first,
              let literal = record.literals.first(where: IMAPSupport.PartLiteralContext.fullMessage) else {
            throw MailError.commandFailed("The message could not be downloaded.")
        }

        let parsed = MessageParser.parse(literal.data)
        let snippetSource = parsed.text ?? parsed.html.map(MessageParser.stripHTML) ?? ""
        let snippet = String(snippetSource
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(180))

        let summary = makeSummary(
            uid: uid,
            mailbox: mailbox,
            record: record,
            info: parsed,
            snippet: snippet
        )

        return MailMessage(
            summary: summary,
            text: parsed.text,
            html: parsed.html,
            attachments: parsed.attachments
        )
    }

    private func makeSummary(
        uid: UInt32,
        mailbox: String,
        record: IMAPFetchRecord,
        info: ParsedMessage,
        snippet: String
    ) -> MessageSummary {
        let flags = IMAPSupport.flags(in: record.text)
        let internalDate = IMAPSupport.firstCapture(#"INTERNALDATE\s+"([^"]*)""#, in: record.text)
            .flatMap(MailDate.parseInternalDate)
        let size = IMAPSupport.firstCapture(#"RFC822\.SIZE\s+(\d+)"#, in: record.text).flatMap(Int.init) ?? 0

        return MessageSummary(
            uid: uid,
            mailbox: mailbox,
            subject: info.subject,
            from: info.from,
            to: info.to,
            cc: info.cc,
            date: info.date ?? internalDate ?? Date(),
            snippet: snippet,
            size: size,
            isRead: flags.contains("\\SEEN"),
            isFlagged: flags.contains("\\FLAGGED"),
            isAnswered: flags.contains("\\ANSWERED"),
            hasAttachments: info.hasAttachments,
            messageID: info.messageID,
            inReplyTo: info.inReplyTo,
            references: info.references
        )
    }

    // MARK: - Mutations

    public func setFlags(
        mailbox: String,
        uid: UInt32,
        flags: Set<MessageFlag>,
        enabled: Bool
    ) async throws {
        guard !flags.isEmpty else { return }
        try await select(mailbox: mailbox)
        let names = flags.map(\.rawValue).joined(separator: " ")
        let operation = enabled ? "+FLAGS.SILENT" : "-FLAGS.SILENT"
        _ = try await execute("UID STORE \(uid) \(operation) (\(names))")
    }

    public func move(mailbox: String, uid: UInt32, to destination: String) async throws {
        try await select(mailbox: mailbox)

        if capabilities.contains("MOVE") {
            _ = try await execute("UID MOVE \(uid) \(IMAPSupport.quote(destination))")
        } else {
            _ = try await execute("UID COPY \(uid) \(IMAPSupport.quote(destination))")
            _ = try await execute("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
            if capabilities.contains("UIDPLUS") {
                _ = try await execute("UID EXPUNGE \(uid)")
            } else {
                _ = try await execute("EXPUNGE")
            }
        }
        selectedMailbox = nil
    }

    public func deletePermanently(mailbox: String, uid: UInt32) async throws {
        try await select(mailbox: mailbox)
        _ = try await execute("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)")
        if capabilities.contains("UIDPLUS") {
            _ = try await execute("UID EXPUNGE \(uid)")
        } else {
            _ = try await execute("EXPUNGE")
        }
        selectedMailbox = nil
    }

    public func append(_ raw: Data, to path: String, flags: [String] = []) async throws {
        guard let connection else {
            throw MailError.connection("Not connected to the incoming mail server.")
        }

        let tag = makeTag()
        let flagPart = flags.isEmpty ? "" : " (\(flags.joined(separator: " ")))"
        try await connection.write("\(tag) APPEND \(IMAPSupport.quote(path))\(flagPart) {\(raw.count)}\r\n")

        let continuation = try await connection.readLine()
        guard continuation.hasPrefix("+") else {
            throw MailError.commandFailed("The server rejected the message: \(continuation)")
        }

        try await connection.write(raw)
        try await connection.write("\r\n")

        let pieces = try await readResponse(tag: tag, connection: connection)
        try ensureOK(pieces, tag: tag, command: "APPEND")
        selectedMailbox = nil
    }

    // MARK: - Command plumbing

    private func capability() async throws -> Set<String> {
        let pieces = try await execute("CAPABILITY")
        var result: Set<String> = []
        for case .line(let line) in pieces {
            guard line.uppercased().hasPrefix("* CAPABILITY ") else { continue }
            let values = line.split(separator: " ").dropFirst(2).map { String($0).uppercased() }
            result.formUnion(values)
        }
        return result
    }

    private func authenticatePlain() async throws {
        guard let connection else {
            throw MailError.connection("Not connected to the incoming mail server.")
        }

        let tag = makeTag()
        try await connection.write("\(tag) AUTHENTICATE PLAIN\r\n")
        let challenge = try await connection.readLine()
        guard challenge.hasPrefix("+") else {
            throw MailError.authentication("The server rejected the authentication method: \(challenge)")
        }

        let token = Data("\0\(username)\0\(password)".utf8).base64EncodedString()
        try await connection.write(token + "\r\n")

        let pieces = try await readResponse(tag: tag, connection: connection)
        try ensureOK(pieces, tag: tag, command: "AUTHENTICATE")
    }

    private func execute(_ command: String) async throws -> [IMAPPiece] {
        guard let connection else {
            throw MailError.connection("Not connected to the incoming mail server.")
        }

        let tag = makeTag()
        try await connection.write("\(tag) \(command)\r\n")
        let pieces = try await readResponse(tag: tag, connection: connection)
        let label = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? "command"
        try ensureOK(pieces, tag: tag, command: label)
        return pieces
    }

    private func readResponse(tag: String, connection: SocketConnection) async throws -> [IMAPPiece] {
        var pieces: [IMAPPiece] = []

        while true {
            let line = try await connection.readLine()
            pieces.append(.line(line))

            if let length = IMAPSupport.literalLength(in: line) {
                let data = try await connection.readExact(length)
                pieces.append(.literal(data))
                continue
            }

            if line.uppercased().hasPrefix(tag.uppercased() + " ") {
                return pieces
            }

            if line.uppercased().hasPrefix("* BYE") {
                throw MailError.connection("The server closed the session: \(line)")
            }
        }
    }

    private func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["MAILR_IMAP_DEBUG"] == "1" else {
            return
        }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private func ensureOK(_ pieces: [IMAPPiece], tag: String, command: String) throws {
        let lastLine = pieces.reversed().compactMap { piece -> String? in
            if case .line(let line) = piece { return line }
            return nil
        }.first ?? ""

        guard lastLine.uppercased().hasPrefix(tag.uppercased() + " OK") else {
            let cleaned = lastLine.replacingOccurrences(of: tag + " ", with: "")
            if cleaned.uppercased().contains("AUTHENTICATIONFAILED")
                || cleaned.uppercased().contains("INVALID CREDENTIALS")
                || cleaned.uppercased().contains("LOGIN FAILED") {
                throw MailError.authentication(cleaned)
            }
            throw MailError.commandFailed("\(command) failed: \(cleaned)")
        }
    }

    private func makeTag() -> String {
        tagCounter += 1
        return "A" + String(format: "%04d", tagCounter)
    }
}
