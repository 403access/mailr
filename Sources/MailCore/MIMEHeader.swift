import Foundation
import CoreFoundation

// MARK: - Charset decoding

public enum TextDecoder {
    public static func decode(_ data: Data, charset: String?) -> String {
        guard !data.isEmpty else { return "" }

        let normalized = normalizeCharset(charset)
        if let encoding = encoding(named: normalized),
           let string = String(data: data, encoding: encoding) {
            return stripBOM(string)
        }
        if let string = String(data: data, encoding: .utf8) {
            return stripBOM(string)
        }
        return stripBOM(String(decoding: data, as: UTF8.self))
    }

    private static func normalizeCharset(_ charset: String?) -> String {
        guard var value = charset?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return "utf-8"
        }
        if let star = value.firstIndex(of: "*") {
            value = String(value[..<star])
        }
        return value
    }

    private static func encoding(named name: String) -> String.Encoding? {
        switch name {
        case "utf-8", "utf8", "unicode-1-1-utf-8":
            return .utf8
        case "us-ascii", "ascii", "ansi_x3.4-1968":
            return .ascii
        case "iso-8859-1", "latin1", "latin-1", "iso8859-1", "cp819":
            return .isoLatin1
        case "windows-1252", "cp1252", "x-cp1252":
            return .windowsCP1252
        case "macintosh", "mac", "x-mac-roman":
            return .macOSRoman
        case "utf-16", "utf16", "ucs-2":
            return .utf16
        case "utf-16be":
            return .utf16BigEndian
        case "utf-16le":
            return .utf16LittleEndian
        default:
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            return String.Encoding(rawValue: nsEncoding)
        }
    }

    private static func stripBOM(_ string: String) -> String {
        if string.hasPrefix("\u{FEFF}") {
            return String(string.dropFirst())
        }
        return string
    }
}

// MARK: - Transfer encodings

public enum QuotedPrintable {
    public static func decode(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D { // "="
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 2
                    continue
                }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A {
                    index += 3
                    continue
                }
                if index + 2 < bytes.count,
                   let high = hexValue(bytes[index + 1]),
                   let low = hexValue(bytes[index + 2]) {
                    output.append(high << 4 | low)
                    index += 3
                    continue
                }
            }
            output.append(byte)
            index += 1
        }
        return Data(output)
    }

    /// Header (`=?...?Q?...?=`) flavour: underscore means space.
    public static func decodeWord(_ data: Data) -> Data {
        let spaced = Data(data.map { $0 == 0x5F ? 0x20 : $0 })
        return decode(spaced)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}

public enum TransferCoding {
    public static func decode(_ data: Data, encoding: String?) -> Data {
        switch encoding?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "base64":
            return decodeBase64(data)
        case "quoted-printable":
            return QuotedPrintable.decode(data)
        default:
            return data
        }
    }

    public static func decodeBase64(_ data: Data) -> Data {
        let filtered = data.filter { byte in
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2B, 0x2F, 0x3D:
                return true
            default:
                return false
            }
        }
        guard !filtered.isEmpty else { return Data() }

        // A truncated preview may end mid-quantum. Trim it back to a valid
        // multiple of four characters before decoding.
        var trimmed = filtered
        let remainder = trimmed.count % 4
        if remainder != 0 {
            trimmed = trimmed.dropLast(remainder)
        }
        return Data(base64Encoded: Data(trimmed), options: .ignoreUnknownCharacters) ?? Data()
    }
}

// MARK: - RFC 2047 encoded words

public enum RFC2047 {
    public static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }

        let pattern = #"=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }

        let matches = regex.matches(in: input, range: NSRange(input.startIndex..., in: input))
        guard !matches.isEmpty else { return input }

        var output = ""
        var cursor = input.startIndex
        var hasPrevious = false

        for match in matches {
            guard let range = Range(match.range, in: input) else { continue }
            let between = input[cursor..<range.lowerBound]

            // Whitespace between two encoded words is not significant.
            if !(hasPrevious && between.allSatisfy(\.isWhitespace)) {
                output += between
            }

            let charset = match.range(at: 1).location != NSNotFound
                ? (Range(match.range(at: 1), in: input).map { String(input[$0]) } ?? "utf-8")
                : "utf-8"
            let encoding = Range(match.range(at: 2), in: input).map { String(input[$0]) } ?? "b"
            let payload = Range(match.range(at: 3), in: input).map { String(input[$0]) } ?? ""

            if let decoded = decodeWord(charset: charset, encoding: encoding, payload: payload) {
                output += decoded
            } else {
                output += input[range]
            }

            cursor = range.upperBound
            hasPrevious = true
        }

        output += input[cursor...]
        return output
    }

    private static func decodeWord(charset: String, encoding: String, payload: String) -> String? {
        let bytes = Data(payload.utf8)
        let decoded: Data
        switch encoding.lowercased() {
        case "b":
            decoded = TransferCoding.decodeBase64(bytes)
        case "q":
            decoded = QuotedPrintable.decodeWord(bytes)
        default:
            return nil
        }
        guard !decoded.isEmpty else { return "" }
        return TextDecoder.decode(decoded, charset: charset)
    }
}

// MARK: - Headers and structured values

public struct HeaderMap: Sendable, Hashable {
    public struct Field: Sendable, Hashable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public private(set) var fields: [Field]

    public init(fields: [Field] = []) {
        self.fields = fields
    }

    public subscript(_ name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func values(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    public func decoded(_ name: String) -> String? {
        self[name].map(RFC2047.decode)
    }

    public mutating func append(_ name: String, _ value: String) {
        fields.append(Field(name: name, value: value))
    }

    public static func parse(_ data: Data) -> HeaderMap {
        let text = String(data: data, encoding: .utf8)
            ?? TextDecoder.decode(data, charset: "iso-8859-1")
        return parse(text)
    }

    public static func parse(_ text: String) -> HeaderMap {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var fields: [Field] = []

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let string = String(line)
            if string.isEmpty { break }

            if string.first == " " || string.first == "\t" {
                guard var last = fields.popLast() else { continue }
                last.value += " " + string.trimmingCharacters(in: .whitespaces)
                fields.append(last)
                continue
            }

            guard let colon = string.firstIndex(of: ":") else { continue }
            let name = String(string[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(string[string.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            fields.append(Field(name: name, value: value))
        }

        return HeaderMap(fields: fields)
    }
}

/// A header value made of a main token plus semicolon-separated parameters,
/// such as `text/plain; charset=utf-8` or `attachment; filename="a.pdf"`.
public struct StructuredHeader: Hashable, Sendable {
    public var value: String
    public var parameters: [String: String]

    public init(_ raw: String?) {
        guard let raw, !raw.isEmpty else {
            self.value = ""
            self.parameters = [:]
            return
        }

        let segments = StructuredHeader.split(raw, separator: ";")
        let head = segments.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.value = head

        var parameters: [String: String] = [:]
        for segment in segments.dropFirst() {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            var key = trimmed[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // RFC 2231 extended parameters use a trailing asterisk
            // (`filename*`). Treat them as the base parameter name.
            if key.hasSuffix("*") {
                key = String(key.dropLast())
            }
            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                value = value.replacingOccurrences(of: "\\\"", with: "\"")
                value = value.replacingOccurrences(of: "\\\\", with: "\\")
            }
            parameters[key] = Self.decodeRFC2231(value)
        }
        self.parameters = parameters
    }

    public subscript(parameter name: String) -> String? {
        parameters[name.lowercased()]
    }

    private static func split(_ raw: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false

        for character in raw {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\", inQuotes {
                escaped = true
                current.append(character)
                continue
            }
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
                continue
            }
            if character == separator, !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result
    }

    /// Handles the common RFC 2231 form `utf-8''na%C3%AFve.pdf`.
    private static func decodeRFC2231(_ value: String) -> String {
        guard value.contains("''") else { return RFC2047.decode(value) }
        let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return RFC2047.decode(value) }
        let charset = String(pieces[0])
        let encoded = String(pieces[2])
        let percentDecoded = encoded.removingPercentEncoding ?? encoded
        if charset.lowercased().hasPrefix("utf-8") {
            return percentDecoded
        }
        return TextDecoder.decode(Data(percentDecoded.utf8), charset: charset)
    }
}

public struct MediaType: Hashable, Sendable {
    public let type: String
    public let subtype: String
    public let parameters: [String: String]

    public init(_ raw: String?) {
        let structured = StructuredHeader(raw)
        let pieces = structured.value.split(separator: "/", maxSplits: 1)
        if pieces.count == 2 {
            self.type = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
            self.subtype = pieces[1].trimmingCharacters(in: .whitespaces).lowercased()
        } else if let single = pieces.first, !single.isEmpty {
            self.type = single.lowercased()
            self.subtype = "plain"
        } else {
            self.type = "text"
            self.subtype = "plain"
        }
        self.parameters = structured.parameters
    }

    public var mimeType: String { "\(type)/\(subtype)" }
    public var charset: String? { parameters["charset"] }
    public var boundary: String? { parameters["boundary"] }
    public var name: String? { parameters["name"] }
    public var isMultipart: Bool { type == "multipart" }
    public var isText: Bool { type == "text" }
}
