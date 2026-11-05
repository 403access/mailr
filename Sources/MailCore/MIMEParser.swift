import Foundation

// MARK: - Dates

public enum MailDate {
    public static func parse(_ raw: String?) -> Date? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        // Remove trailing timezone comments, e.g. `(PST)`.
        value = value.replacingOccurrences(
            of: "\\s*\\([^)]*\\)\\s*$",
            with: "",
            options: .regularExpression
        )

        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm Z",
            "EEE, d MMM yyyy HH:mm:ss",
            "d MMM yyyy HH:mm:ss",
            "EEE, d MMM yy HH:mm:ss Z",
            "d MMM yy HH:mm:ss Z"
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }

        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        return nil
    }

    public static func parseInternalDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: raw.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - MIME tree

public struct MIMEPart: Sendable {
    public var headers: HeaderMap
    public var body: Data
    public var children: [MIMEPart]
    public var mediaType: MediaType
    public var disposition: StructuredHeader?
    public var transferEncoding: String?
    public var contentID: String?

    public var filename: String? {
        if let name = disposition?[parameter: "filename"], !name.isEmpty {
            return name
        }
        if let name = mediaType.name, !name.isEmpty {
            return name
        }
        return nil
    }

    public var decodedBody: Data {
        TransferCoding.decode(body, encoding: transferEncoding)
    }

    public var isMultipart: Bool {
        mediaType.isMultipart && !children.isEmpty
    }
}

public enum MIMEParser {
    public static func parse(_ data: Data) -> MIMEPart {
        parsePart(data, depth: 0)
    }

    static func parsePart(_ data: Data, depth: Int) -> MIMEPart {
        let (headerData, bodyData) = splitHeaderBody(data)
        let headers = HeaderMap.parse(headerData)
        let mediaType = MediaType(headers["Content-Type"])
        let dispositionRaw = headers["Content-Disposition"]
        let disposition = dispositionRaw.map { StructuredHeader($0) }

        var children: [MIMEPart] = []
        if mediaType.isMultipart, let boundary = mediaType.boundary, depth < 12 {
            let chunks = splitMultipart(bodyData, boundary: boundary)
            children = chunks.map { parsePart($0, depth: depth + 1) }
        }

        let contentID = headers["Content-ID"]?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n<>"))

        return MIMEPart(
            headers: headers,
            body: bodyData,
            children: children,
            mediaType: mediaType,
            disposition: disposition,
            transferEncoding: headers["Content-Transfer-Encoding"],
            contentID: contentID
        )
    }

    static func splitHeaderBody(_ data: Data) -> (Data, Data) {
        if let range = data.range(of: Data("\r\n\r\n".utf8)) {
            return (data[..<range.lowerBound], data[range.upperBound...])
        }
        if let range = data.range(of: Data("\n\n".utf8)) {
            return (data[..<range.lowerBound], data[range.upperBound...])
        }
        return (data, Data())
    }

    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        guard !boundary.isEmpty else { return [] }
        let marker = Data(("--" + boundary).utf8)

        struct Delimiter {
            var start: Data.Index
            var afterLine: Data.Index
            var closing: Bool
        }

        var delimiters: [Delimiter] = []
        var searchStart = body.startIndex

        while searchStart < body.endIndex,
              let range = body.range(of: marker, in: searchStart..<body.endIndex) {
            let atLineStart = range.lowerBound == body.startIndex
                || body[body.index(before: range.lowerBound)] == 0x0A
            guard atLineStart else {
                searchStart = range.upperBound
                continue
            }

            var cursor = range.upperBound
            var closing = false
            if cursor < body.endIndex, body[cursor] == 0x2D {
                let next = body.index(after: cursor)
                if next < body.endIndex, body[next] == 0x2D {
                    closing = true
                    cursor = body.index(after: next)
                }
            }

            if let newline = body[cursor...].firstIndex(of: 0x0A) {
                let afterLine = body.index(after: newline)
                delimiters.append(Delimiter(start: range.lowerBound, afterLine: afterLine, closing: closing))
                if closing { break }
                searchStart = afterLine
            } else {
                delimiters.append(Delimiter(start: range.lowerBound, afterLine: body.endIndex, closing: closing))
                break
            }
        }

        var parts: [Data] = []
        for (index, delimiter) in delimiters.enumerated() where !delimiter.closing {
            let start = delimiter.afterLine
            let end = index + 1 < delimiters.count ? delimiters[index + 1].start : body.endIndex
            guard start <= end else { continue }
            var slice = body[start..<end]
            while slice.last == 0x0A || slice.last == 0x0D {
                slice = slice.dropLast()
            }
            if !slice.isEmpty {
                parts.append(Data(slice))
            }
        }
        return parts
    }
}

// MARK: - Parsed message

public struct ParsedMessage: Sendable {
    public var headers: HeaderMap
    public var subject: String
    public var from: [EmailAddress]
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var date: Date?
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var text: String?
    public var html: String?
    public var attachments: [MailAttachment]
    public var hasAttachments: Bool

    public init(headers: HeaderMap) {
        self.headers = headers
        self.subject = RFC2047.decode(headers["Subject"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if self.subject.isEmpty { self.subject = "(No subject)" }
        self.from = EmailAddress.parseList(headers["From"] ?? "")
        self.to = EmailAddress.parseList(headers["To"] ?? "")
        self.cc = EmailAddress.parseList(headers["Cc"] ?? "")
        self.date = MailDate.parse(headers["Date"])
        self.messageID = ParsedMessage.cleanID(headers["Message-ID"])
        self.inReplyTo = ParsedMessage.cleanID(headers["In-Reply-To"])
        self.references = (headers["References"] ?? "")
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }

        let mediaType = MediaType(headers["Content-Type"])
        let disposition = headers["Content-Disposition"].map { StructuredHeader($0) }
        self.hasAttachments = mediaType.mimeType == "multipart/mixed"
            || disposition?.value.lowercased() == "attachment"

        self.text = nil
        self.html = nil
        self.attachments = []
    }

    private static func cleanID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n<>"))
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum MessageParser {
    public static func parseHeaderInfo(_ data: Data) -> ParsedMessage {
        let (headerData, _) = MIMEParser.splitHeaderBody(data)
        return ParsedMessage(headers: HeaderMap.parse(headerData))
    }

    public static func parse(_ data: Data) -> ParsedMessage {
        let root = MIMEParser.parse(data)
        var message = ParsedMessage(headers: root.headers)

        var textParts: [String] = []
        var htmlParts: [String] = []
        var attachments: [MailAttachment] = []
        collect(
            part: root,
            into: &textParts,
            html: &htmlParts,
            attachments: &attachments
        )

        message.text = textParts.isEmpty ? nil : textParts.joined(separator: "\n\n")
        var html = htmlParts.isEmpty ? nil : htmlParts.joined(separator: "\n")
        if let htmlValue = html {
            html = inlineImages(in: htmlValue, attachments: attachments)
        }
        message.html = html
        message.attachments = attachments

        let visible = attachments.contains { $0.isVisibleAttachment }
        message.hasAttachments = message.hasAttachments || visible
        return message
    }

    public static func previewSnippet(headers: HeaderMap, partialBody: Data) -> String {
        guard !partialBody.isEmpty else { return "" }

        let root = MIMEPart(
            headers: headers,
            body: partialBody,
            children: [],
            mediaType: MediaType(headers["Content-Type"]),
            disposition: nil,
            transferEncoding: headers["Content-Transfer-Encoding"],
            contentID: nil
        )

        let source: String?
        if root.mediaType.isMultipart, let boundary = root.mediaType.boundary {
            let chunks = MIMEParser.splitMultipart(partialBody, boundary: boundary)
            let parsedChildren = chunks.map { MIMEParser.parsePart($0, depth: 1) }
            source = firstDisplayText(in: parsedChildren)
        } else if root.mediaType.mimeType == "text/html" {
            source = stripHTML(TextDecoder.decode(root.decodedBody, charset: root.mediaType.charset))
        } else {
            source = TextDecoder.decode(root.decodedBody, charset: root.mediaType.charset)
        }

        guard let source else { return "" }
        return summarize(source)
    }

    // MARK: Extraction

    private static func collect(
        part: MIMEPart,
        into text: inout [String],
        html: inout [String],
        attachments: inout [MailAttachment]
    ) {
        if part.isMultipart {
            for child in part.children {
                collect(part: child, into: &text, html: &html, attachments: &attachments)
            }
            return
        }

        let disposition = part.disposition?.value.lowercased()
        let isInline = disposition == "inline"
        let filename = part.filename

        if let filename, !filename.isEmpty {
            let attachment = MailAttachment(
                filename: RFC2047.decode(filename),
                mimeType: part.mediaType.mimeType,
                data: part.decodedBody,
                isInline: isInline,
                contentID: part.contentID
            )
            attachments.append(attachment)
            return
        }

        if disposition == "attachment" {
            attachments.append(
                MailAttachment(
                    filename: defaultFilename(for: part),
                    mimeType: part.mediaType.mimeType,
                    data: part.decodedBody,
                    isInline: false,
                    contentID: part.contentID
                )
            )
            return
        }

        switch part.mediaType.mimeType {
        case "text/plain":
            text.append(TextDecoder.decode(part.decodedBody, charset: part.mediaType.charset))
        case "text/html":
            html.append(TextDecoder.decode(part.decodedBody, charset: part.mediaType.charset))
        case "message/rfc822":
            attachments.append(
                MailAttachment(
                    filename: "message.eml",
                    mimeType: "message/rfc822",
                    data: part.decodedBody,
                    isInline: false,
                    contentID: part.contentID
                )
            )
        default:
            if let contentID = part.contentID, part.mediaType.type == "image" {
                attachments.append(
                    MailAttachment(
                        filename: filename ?? "inline",
                        mimeType: part.mediaType.mimeType,
                        data: part.decodedBody,
                        isInline: true,
                        contentID: contentID
                    )
                )
            } else if !part.decodedBody.isEmpty {
                attachments.append(
                    MailAttachment(
                        filename: defaultFilename(for: part),
                        mimeType: part.mediaType.mimeType,
                        data: part.decodedBody,
                        isInline: false,
                        contentID: part.contentID
                    )
                )
            }
        }
    }

    private static func firstDisplayText(in parts: [MIMEPart]) -> String? {
        for part in parts {
            if part.isMultipart {
                if let nested = firstDisplayText(in: part.children) {
                    return nested
                }
                continue
            }
            guard part.filename == nil, part.disposition?.value.lowercased() != "attachment" else {
                continue
            }
            switch part.mediaType.mimeType {
            case "text/plain":
                return TextDecoder.decode(part.decodedBody, charset: part.mediaType.charset)
            case "text/html":
                let decoded = TextDecoder.decode(part.decodedBody, charset: part.mediaType.charset)
                return stripHTML(decoded)
            default:
                continue
            }
        }
        return nil
    }

    private static func defaultFilename(for part: MIMEPart) -> String {
        switch part.mediaType.type {
        case "image": return "image"
        case "audio": return "audio"
        case "video": return "video"
        case "text": return "document.txt"
        default: return "attachment"
        }
    }

    private static func inlineImages(in html: String, attachments: [MailAttachment]) -> String {
        var result = html
        for attachment in attachments where attachment.isInline {
            guard let rawID = attachment.contentID, !rawID.isEmpty else { continue }
            let contentID = rawID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            let dataURL = "data:\(attachment.mimeType);base64,\(attachment.data.base64EncodedString())"
            result = result.replacingOccurrences(of: "cid:<\(contentID)>", with: dataURL)
            result = result.replacingOccurrences(of: "cid:\(contentID)", with: dataURL)
            let encodedID = contentID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? contentID
            result = result.replacingOccurrences(of: "cid:\(encodedID)", with: dataURL)
        }
        return result
    }

    // MARK: Text helpers

    public static func stripHTML(_ html: String) -> String {
        var value = html
        value = value.replacingOccurrences(
            of: "(?is)<(script|style|head)\\b[^>]*>.*?</\\1>",
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?i)</p\\s*>", with: "\n\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "(?i)</div\\s*>", with: "\n", options: .regularExpression)
        value = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "&nbsp;", with: " ")
        value = value.replacingOccurrences(of: "&amp;", with: "&")
        value = value.replacingOccurrences(of: "&lt;", with: "<")
        value = value.replacingOccurrences(of: "&gt;", with: ">")
        value = value.replacingOccurrences(of: "&quot;", with: "\"")
        value = value.replacingOccurrences(of: "&#39;", with: "'")
        return value
    }

    private static func summarize(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsed.count > 180 else { return collapsed }
        let prefix = collapsed.prefix(180)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }
}
