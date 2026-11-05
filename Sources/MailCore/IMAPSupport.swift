import Foundation

enum IMAPPiece: Sendable {
    case line(String)
    case literal(Data)
}

struct IMAPFetchRecord: Sendable {
    struct Literal: Sendable {
        var context: String
        var data: Data
    }

    var sequence: Int?
    var text: String
    var literals: [Literal]
}

enum IMAPSupport {
    static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func literalLength(in line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("}") else { return nil }
        guard let open = trimmed.lastIndex(of: "{") else { return nil }

        var number = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        if number.hasSuffix("+") { number = number.dropLast() }
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        return Int(number)
    }

    static func isTaggedCompletion(_ line: String) -> Bool {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, !line.hasPrefix("*") else { return false }
        let status = parts[1].uppercased()
        return status == "OK" || status == "NO" || status == "BAD"
    }

    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    static func flags(in text: String) -> Set<String> {
        guard let raw = firstCapture(#"\bFLAGS\s+\(([^)]*)\)"#, in: text) else { return [] }
        return Set(raw.split(whereSeparator: \.isWhitespace).map { String($0).uppercased() })
    }

    static func exists(in lines: [String]) -> Int {
        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 3, parts[0] == "*", parts[2].uppercased() == "EXISTS",
               let count = Int(parts[1]) {
                return count
            }
        }
        return 0
    }

    // MARK: - Tokenizer

    enum Token: Equatable, Sendable {
        case atom(String)
        case quoted(String)
        case open
        case close

        var stringValue: String? {
            switch self {
            case .atom(let value), .quoted(let value): value
            case .open, .close: nil
            }
        }
    }

    static func tokenize(_ input: String) -> [Token] {
        var tokens: [Token] = []
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]

            if character == " " || character == "\t" || character == "\r" || character == "\n" {
                index = input.index(after: index)
                continue
            }

            if character == "(" {
                tokens.append(.open)
                index = input.index(after: index)
                continue
            }
            if character == ")" {
                tokens.append(.close)
                index = input.index(after: index)
                continue
            }

            if character == "\"" {
                index = input.index(after: index)
                var value = ""
                var escaped = false
                while index < input.endIndex {
                    let next = input[index]
                    if escaped {
                        value.append(next)
                        escaped = false
                    } else if next == "\\" {
                        escaped = true
                    } else if next == "\"" {
                        index = input.index(after: index)
                        break
                    } else {
                        value.append(next)
                    }
                    index = input.index(after: index)
                }
                tokens.append(.quoted(value))
                continue
            }

            var atom = ""
            while index < input.endIndex {
                let next = input[index]
                if next == " " || next == "\t" || next == "\r" || next == "\n" || next == "(" || next == ")" {
                    break
                }
                atom.append(next)
                index = input.index(after: index)
            }
            if !atom.isEmpty {
                tokens.append(.atom(atom))
            }
        }

        return tokens
    }

    static func mailboxName(from token: Token?) -> String? {
        switch token {
        case .atom(let value), .quoted(let value):
            if value.uppercased() == "NIL" { return nil }
            return value
        default:
            return nil
        }
    }

    /// Parses `* LIST (\HasNoChildren \Sent) "/" "Sent Items"`.
    static func parseList(
        _ line: String
    ) -> (flags: Set<String>, delimiter: String?, name: String)? {
        guard line.uppercased().hasPrefix("* LIST ") else { return nil }
        let tokens = tokenize(line)
        guard let listIndex = tokens.firstIndex(where: {
            if case .atom(let value) = $0 { return value.uppercased() == "LIST" }
            return false
        }) else { return nil }

        var index = tokens.index(after: listIndex)
        guard index < tokens.endIndex, tokens[index] == .open else { return nil }
        index = tokens.index(after: index)

        var flags: Set<String> = []
        while index < tokens.endIndex, tokens[index] != .close {
            if let value = tokens[index].stringValue {
                flags.insert(value)
            }
            index = tokens.index(after: index)
        }
        guard index < tokens.endIndex else { return nil }
        index = tokens.index(after: index)

        guard index < tokens.endIndex else { return nil }
        let delimiter = mailboxName(from: tokens[index])
        index = tokens.index(after: index)

        guard index < tokens.endIndex else { return nil }
        let name = mailboxName(from: tokens[index])
        guard let name else { return nil }
        return (flags, delimiter, name)
    }

    /// Parses `* STATUS "INBOX" (MESSAGES 12 UNSEEN 3)`.
    static func parseStatus(_ line: String) -> [String: Int]? {
        guard line.uppercased().hasPrefix("* STATUS ") else { return nil }
        let tokens = tokenize(line)
        guard let statusIndex = tokens.firstIndex(where: {
            if case .atom(let value) = $0 { return value.uppercased() == "STATUS" }
            return false
        }) else { return nil }

        var index = tokens.index(after: statusIndex)
        guard index < tokens.endIndex else { return nil }
        // Skip the mailbox name (quoted or atom; may contain spaces).
        index = tokens.index(after: index)
        guard index < tokens.endIndex, tokens[index] == .open else { return nil }
        index = tokens.index(after: index)

        var result: [String: Int] = [:]
        while index < tokens.endIndex, tokens[index] != .close {
            guard let key = tokens[index].stringValue else { break }
            index = tokens.index(after: index)
            guard index < tokens.endIndex, let rawValue = tokens[index].stringValue, let value = Int(rawValue) else {
                break
            }
            result[key.uppercased()] = value
            index = tokens.index(after: index)
        }
        return result
    }

    // MARK: - Fetch responses

    static func parseFetchRecords(_ pieces: [IMAPPiece]) -> [IMAPFetchRecord] {
        var records: [IMAPFetchRecord] = []
        var current: IMAPFetchRecord?
        var context = ""

        func finish() {
            if let current { records.append(current) }
            current = nil
        }

        for piece in pieces {
            switch piece {
            case .line(let line):
                let upper = line.uppercased()
                if upper.hasPrefix("* ") {
                    if upper.contains(" FETCH ") {
                        finish()
                        let sequence = firstCapture(#"^\*\s+(\d+)\s+FETCH"#, in: line).flatMap(Int.init)
                        current = IMAPFetchRecord(sequence: sequence, text: line, literals: [])
                    } else {
                        finish()
                    }
                    context = line
                } else if current != nil {
                    if isTaggedCompletion(line) {
                        finish()
                    } else {
                        current?.text += "\n" + line
                        context = line
                    }
                }
            case .literal(let data):
                current?.literals.append(.init(context: context, data: data))
            }
        }

        finish()
        return records
    }

    struct PartLiteralContext {
        static func header(_ literal: IMAPFetchRecord.Literal) -> Bool {
            literal.context.uppercased().contains("BODY[HEADER")
        }

        static func preview(_ literal: IMAPFetchRecord.Literal) -> Bool {
            literal.context.uppercased().contains("BODY[TEXT")
        }

        static func fullMessage(_ literal: IMAPFetchRecord.Literal) -> Bool {
            literal.context.uppercased().contains("BODY[]")
        }
    }

    // MARK: - Mailbox naming

    static func displayName(for path: String, delimiter: String?) -> String {
        let decoded = IMAPUTF7.decode(path)
        if decoded.uppercased() == "INBOX" { return "Inbox" }
        if let delimiter, !delimiter.isEmpty {
            let components = decoded.components(separatedBy: delimiter).filter { !$0.isEmpty }
            if let last = components.last { return last }
        }
        return decoded
    }

    static func role(path: String, flags: Set<String>) -> MailboxRole {
        let normalizedFlags = Set(flags.map { $0.uppercased() })
        let upperPath = path.uppercased()
        if upperPath == "INBOX" { return .inbox }

        let lowered = path.lowercased()
        if normalizedFlags.contains("\\SENT") || lowered.contains("sent") { return .sent }
        if normalizedFlags.contains("\\DRAFTS") || lowered.contains("draft") { return .drafts }
        if normalizedFlags.contains("\\TRASH") || lowered.contains("trash") || lowered.contains("deleted") { return .trash }
        if normalizedFlags.contains("\\JUNK") || lowered.contains("junk") || lowered.contains("spam") { return .junk }
        if normalizedFlags.contains("\\ARCHIVE") || normalizedFlags.contains("\\ALL")
            || lowered.contains("archive") || lowered.contains("all mail") {
            return .archive
        }
        return .other
    }
}

// MARK: - Modified UTF-7 (RFC 3501, section 5.1.3)

public enum IMAPUTF7 {
    public static func decode(_ input: String) -> String {
        guard input.contains("&") else { return input }

        var output = ""
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]
            guard character == "&" else {
                output.append(character)
                index = input.index(after: index)
                continue
            }

            let next = input.index(after: index)
            guard next < input.endIndex else {
                output.append("&")
                break
            }

            if input[next] == "-" {
                output.append("&")
                index = input.index(after: next)
                continue
            }

            var cursor = next
            var encoded = ""
            var foundTerminator = false
            while cursor < input.endIndex {
                if input[cursor] == "-" {
                    foundTerminator = true
                    break
                }
                encoded.append(input[cursor])
                cursor = input.index(after: cursor)
            }

            guard foundTerminator else {
                output.append("&")
                index = next
                continue
            }

            var base64 = encoded.replacingOccurrences(of: ",", with: "+")
            let remainder = base64.count % 4
            if remainder != 0 {
                base64 += String(repeating: "=", count: 4 - remainder)
            }

            if let data = Data(base64Encoded: base64), let decoded = String(data: data, encoding: .utf16BigEndian) {
                output += decoded
            } else {
                output += "&" + encoded + "-"
            }
            index = input.index(after: cursor)
        }

        return output
    }
}
