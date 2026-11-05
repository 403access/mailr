import XCTest
@testable import MailCore

final class MessageBuilderTests: XCTestCase {
    func testBuildRoundTripsThroughParser() throws {
        let outgoing = OutgoingMessage(
            from: EmailAddress(address: "demo@mailr.app", name: "Mailr Demo"),
            to: [EmailAddress(address: "mira@example.com", name: "Mira Chen")],
            cc: [EmailAddress(address: "alex@example.com", name: "Alex Novak")],
            subject: "Grüße aus Mailr",
            text: "Hello\nWorld — this is a test.",
            attachments: [
                OutgoingAttachment(
                    filename: "notes.txt",
                    mimeType: "text/plain",
                    data: Data("attachment body".utf8)
                )
            ],
            inReplyTo: "<original@example.com>",
            references: ["<thread@example.com>", "<original@example.com>"]
        )

        let raw = MessageBuilder.build(outgoing)
        let text = try XCTUnwrap(String(data: raw, encoding: .utf8))

        XCTAssertTrue(text.contains("From: Mailr Demo <demo@mailr.app>"))
        XCTAssertTrue(text.contains("To: Mira Chen <mira@example.com>"))
        XCTAssertTrue(text.contains("Cc: Alex Novak <alex@example.com>"))
        XCTAssertTrue(text.contains("Subject: =?UTF-8?B?"))
        XCTAssertTrue(text.contains("In-Reply-To: <original@example.com>"))
        XCTAssertTrue(text.contains("References: <thread@example.com> <original@example.com>"))
        XCTAssertTrue(text.contains("filename=\"notes.txt\""))

        // Every newline must be part of a CRLF pair.
        let withoutCRLF = text.replacingOccurrences(of: "\r\n", with: "")
        XCTAssertFalse(withoutCRLF.contains("\n"))
        XCTAssertFalse(withoutCRLF.contains("\r"))

        let parsed = MessageParser.parse(raw)
        XCTAssertEqual(parsed.subject, "Grüße aus Mailr")
        XCTAssertEqual(parsed.to.first?.name, "Mira Chen")
        XCTAssertNotNil(parsed.text)
        XCTAssertTrue(parsed.text?.contains("Hello") == true)
        XCTAssertTrue(parsed.text?.contains("World") == true)
        XCTAssertTrue(parsed.html?.contains("Hello") == true)
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments.first?.filename, "notes.txt")
        XCTAssertEqual(
            parsed.attachments.first.map { String(decoding: $0.data, as: UTF8.self) },
            "attachment body"
        )
    }

    func testBuildWithoutAttachmentsUsesAlternative() throws {
        let outgoing = OutgoingMessage(
            from: EmailAddress(address: "a@example.com"),
            to: [EmailAddress(address: "b@example.com")],
            subject: "Plain",
            text: "Just text"
        )
        let raw = MessageBuilder.build(outgoing)
        let text = try XCTUnwrap(String(data: raw, encoding: .utf8))

        XCTAssertTrue(text.contains("Content-Type: multipart/alternative;"))
        XCTAssertFalse(text.contains("multipart/mixed"))
        XCTAssertTrue(text.contains("Content-Type: text/plain; charset=utf-8"))
        XCTAssertTrue(text.contains("Content-Type: text/html; charset=utf-8"))
    }

    func testNonASCIIAttachmentFilename() throws {
        let outgoing = OutgoingMessage(
            from: EmailAddress(address: "a@example.com"),
            to: [EmailAddress(address: "b@example.com")],
            subject: "Files",
            text: "See attached",
            attachments: [
                OutgoingAttachment(
                    filename: "Rechnung März.pdf",
                    mimeType: "application/pdf",
                    data: Data([0x25, 0x50, 0x44, 0x46])
                )
            ]
        )
        let raw = MessageBuilder.build(outgoing)
        let text = try XCTUnwrap(String(data: raw, encoding: .utf8))
        XCTAssertTrue(text.contains("filename*=UTF-8''Rechnung%20M%C3%A4rz.pdf"))
        XCTAssertTrue(text.contains("filename=\"Rechnung M_rz.pdf\""))
    }

    func testHeaderInjectionIsNeutralized() {
        let outgoing = OutgoingMessage(
            from: EmailAddress(address: "a@example.com"),
            to: [EmailAddress(address: "b@example.com")],
            subject: "Hello\r\nBcc: evil@example.com",
            text: "body"
        )
        let raw = MessageBuilder.build(outgoing)
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(text.contains("\r\nBcc:"))
    }
}
