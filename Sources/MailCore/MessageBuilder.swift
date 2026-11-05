import Foundation

public enum MessageBuilder {
    public static func build(_ message: OutgoingMessage) -> Data {
        let outerBoundary = "mailr_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))"
        let alternativeBoundary = "mailr_alt_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"
        let domain = message.from.address.split(separator: "@").last.map(String.init) ?? "mailr.local"
        let messageID = "<\(UUID().uuidString.lowercased())@\(domain)>"

        var headers: [String] = [
            "From: \(formatAddress(message.from))"
        ]
        if !message.to.isEmpty {
            headers.append("To: \(message.to.map(formatAddress).joined(separator: ", "))")
        }
        if !message.cc.isEmpty {
            headers.append("Cc: \(message.cc.map(formatAddress).joined(separator: ", "))")
        }
        headers.append("Subject: \(encodeHeader(message.subject.isEmpty ? "(No subject)" : message.subject))")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        headers.append("Date: \(formatter.string(from: Date()))")
        headers.append("Message-ID: \(messageID)")
        headers.append("MIME-Version: 1.0")

        if let inReplyTo = message.inReplyTo, !inReplyTo.isEmpty {
            let safeID = sanitizeMessageID(inReplyTo)
            headers.append("In-Reply-To: <\(safeID)>")
        }
        let referenceIDs = message.references.map(sanitizeMessageID).filter { !$0.isEmpty }
        if !referenceIDs.isEmpty {
            headers.append("References: \(referenceIDs.map { "<\($0)>" }.joined(separator: " "))")
        }

        var body = ""
        let normalizedText = message.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let alternative = """
        --\(alternativeBoundary)
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: base64

        \(base64Lines(Data(normalizedText.utf8)))
        --\(alternativeBoundary)
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: base64

        \(base64Lines(Data(plainTextHTML(message.text).utf8)))
        --\(alternativeBoundary)--

        """

        if message.attachments.isEmpty {
            headers.append("Content-Type: multipart/alternative; boundary=\"\(alternativeBoundary)\"")
            body = alternative
        } else {
            headers.append("Content-Type: multipart/mixed; boundary=\"\(outerBoundary)\"")

            var mixed = "--\(outerBoundary)\r\n"
            mixed += "Content-Type: multipart/alternative; boundary=\"\(alternativeBoundary)\"\r\n\r\n"
            mixed += alternative

            for attachment in message.attachments {
                mixed += "--\(outerBoundary)\r\n"
                mixed += "Content-Type: \(attachment.mimeType); name=\"\(asciiFilename(attachment.filename))\"\r\n"
                mixed += "Content-Transfer-Encoding: base64\r\n"
                mixed += "Content-Disposition: attachment; filename=\"\(asciiFilename(attachment.filename))\""
                if !attachment.filename.allSatisfy(\.isASCII) {
                    let encoded = attachment.filename
                        .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "._-")))
                        ?? attachment.filename
                    mixed += "; filename*=UTF-8''\(encoded)"
                }
                mixed += "\r\n\r\n"
                mixed += base64Lines(attachment.data)
                mixed += "\r\n"
            }
            mixed += "--\(outerBoundary)--\r\n"
            body = mixed
        }

        let headerText = headers.joined(separator: "\r\n")
        let raw = headerText + "\r\n\r\n" + body
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        return Data(normalized.utf8)
    }

    private static func plainTextHTML(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
        return """
        <!doctype html><html><body><div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; \
        font-size: 15px; line-height: 1.6; color: #222;">\(escaped)</div></body></html>
        """
    }

    static func formatAddress(_ address: EmailAddress) -> String {
        let safeAddress = sanitizeAddress(address.address)
        guard let name = address.name, !name.isEmpty else { return safeAddress }
        let encoded = encodeHeader(name)
        if encoded.hasPrefix("=?") {
            return "\(encoded) <\(safeAddress)>"
        }
        if encoded.contains(where: { "(),:;<>@[\\]\"".contains($0) }) {
            let escaped = encoded.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(safeAddress)>"
        }
        return "\(encoded) <\(safeAddress)>"
    }

    static func sanitizeAddress(_ address: String) -> String {
        address
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    static func encodeHeader(_ value: String) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        guard singleLine.allSatisfy(\.isASCII) else {
            return "=?UTF-8?B?\(Data(singleLine.utf8).base64EncodedString())?="
        }
        return singleLine
    }

    static func sanitizeMessageID(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "<", with: "")
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    static func asciiFilename(_ filename: String) -> String {
        let fallback = String(filename.map { character -> Character in
            if character.isASCII, character != "\"", character != "\\" {
                return character
            }
            return "_"
        })
        return fallback.isEmpty ? "attachment" : fallback
    }

    static func base64Lines(_ data: Data) -> String {
        let encoded = data.base64EncodedString()
        var lines: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 76, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(String(encoded[index..<end]))
            index = end
        }
        return lines.joined(separator: "\r\n")
    }
}
