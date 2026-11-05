import XCTest
@testable import MailCore

final class MIMETests: XCTestCase {
    func testRFC2047Base64AndQuotedPrintable() {
        XCTAssertEqual(RFC2047.decode("=?UTF-8?B?VGVzdCDwn5iA?="), "Test 😀")
        XCTAssertEqual(RFC2047.decode("=?UTF-8?Q?Mira_Chen?="), "Mira Chen")
        XCTAssertEqual(
            RFC2047.decode("=?UTF-8?B?R3LDvMOfZQ==?= =?UTF-8?B?IHVuZCBTaWVn?="),
            "Grüße und Sieg"
        )
        XCTAssertEqual(RFC2047.decode("plain text"), "plain text")
    }

    func testHeaderUnfoldingAndLookup() {
        let raw = """
        Subject: Hello
         world
        From: Jane <jane@example.com>
        X-Test: one
        X-Test: two

        """
        let headers = HeaderMap.parse(raw)
        XCTAssertEqual(headers["subject"], "Hello world")
        XCTAssertEqual(headers["FROM"], "Jane <jane@example.com>")
        XCTAssertEqual(headers.values("x-test"), ["one", "two"])
    }

    func testEmailAddressList() {
        let addresses = EmailAddress.parseList(
            "\"Doe, Jane\" <jane@example.com>, bob@example.com (Bob), Team: carol@example.com;"
        )
        XCTAssertEqual(addresses.count, 3)
        XCTAssertEqual(addresses[0].name, "Doe, Jane")
        XCTAssertEqual(addresses[0].address, "jane@example.com")
        XCTAssertEqual(addresses[1].address, "bob@example.com")
        XCTAssertEqual(addresses[1].name, nil)
        XCTAssertEqual(addresses[2].address, "carol@example.com")
    }

    func testStructuredHeaderAndRFC2231Filename() {
        let header = StructuredHeader(
            "attachment; filename=\"fallback.txt\"; filename*=UTF-8''na%C3%AFve%20notes.txt"
        )
        XCTAssertEqual(header.value, "attachment")
        XCTAssertEqual(header[parameter: "filename"], "naïve notes.txt")
    }

    func testQuotedPrintable() {
        let encoded = Data("Hello=20world=0D=0A=3Ddone".utf8)
        let decoded = QuotedPrintable.decode(encoded)
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "Hello world\r\n=done")
    }

    func testMultipartMessageExtraction() throws {
        let raw = """
        From: =?UTF-8?Q?Mira_Chen?= <mira@example.com>
        To: Demo <demo@mailr.app>
        Subject: =?UTF-8?B?RGVzaWduIHJldmlldw==?=
        Date: Thu, 5 Nov 2026 10:00:00 +0100
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: multipart/alternative; boundary="alt"

        --alt
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Hello=20world
        --alt
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: base64

        PGI+SGlnaDwvYj4=
        --alt--
        --outer
        Content-Type: application/octet-stream; name="report.bin"
        Content-Disposition: attachment; filename="report.bin"
        Content-Transfer-Encoding: base64

        SGVsbG8=
        --outer--
        """
            .replacingOccurrences(of: "\n", with: "\r\n")

        let parsed = MessageParser.parse(Data(raw.utf8))
        XCTAssertEqual(parsed.subject, "Design review")
        XCTAssertEqual(parsed.from.first?.name, "Mira Chen")
        XCTAssertEqual(parsed.text, "Hello world")
        XCTAssertEqual(parsed.html, "<b>High</b>")
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments[0].filename, "report.bin")
        XCTAssertEqual(String(data: parsed.attachments[0].data, encoding: .utf8), "Hello")
        XCTAssertTrue(parsed.hasAttachments)
    }

    func testPreviewSnippetFromTruncatedMultipart() {
        let headers = HeaderMap.parse(
            "Content-Type: multipart/alternative; boundary=\"b\"\r\nMIME-Version: 1.0"
        )
        let partial = """
        --b
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: 7bit

        A short preview of the message.
        --b
        Content-Type: text/html; charset=utf-8

        <p>HTML version</p>
        """
        let snippet = MessageParser.previewSnippet(
            headers: headers,
            partialBody: Data(partial.utf8)
        )
        XCTAssertEqual(snippet, "A short preview of the message.")
    }

    func testHTMLSnippetStripsMarkup() {
        let snippet = MessageParser.previewSnippet(
            headers: HeaderMap.parse("Content-Type: text/html; charset=utf-8"),
            partialBody: Data("<p>Hello <b>there</b>&nbsp;friend</p>".utf8)
        )
        XCTAssertEqual(snippet, "Hello there friend")
    }

    func testDateParsing() throws {
        let date = try XCTUnwrap(MailDate.parse("Thu, 5 Nov 2026 10:00:00 +0100"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(calendar.component(.hour, from: date), 9)
        XCTAssertNotNil(MailDate.parseInternalDate("05-Nov-2026 10:00:00 +0000"))
    }
}
