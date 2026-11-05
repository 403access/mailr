import XCTest
@testable import MailCore

final class IMAPTests: XCTestCase {
    func testLiteralLength() {
        XCTAssertEqual(IMAPSupport.literalLength(in: "A0001 OK [READ] {342}"), 342)
        XCTAssertEqual(IMAPSupport.literalLength(in: "foo {12+}"), 12)
        XCTAssertNil(IMAPSupport.literalLength(in: "foo {bar}"))
        XCTAssertNil(IMAPSupport.literalLength(in: "foo"))
    }

    func testListParsing() {
        let parsed = IMAPSupport.parseList("* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent Items\"")
        XCTAssertEqual(parsed?.flags, ["\\HasNoChildren", "\\Sent"])
        XCTAssertEqual(parsed?.delimiter, "/")
        XCTAssertEqual(parsed?.name, "Sent Items")

        let nested = IMAPSupport.parseList("* LIST () NIL INBOX")
        XCTAssertEqual(nested?.name, "INBOX")
        XCTAssertNil(nested?.delimiter)
    }

    func testStatusParsing() throws {
        let status = try XCTUnwrap(
            IMAPSupport.parseStatus("* STATUS \"Sent Mail\" (MESSAGES 12 UNSEEN 3 UIDNEXT 90)")
        )
        XCTAssertEqual(status["MESSAGES"], 12)
        XCTAssertEqual(status["UNSEEN"], 3)
        XCTAssertEqual(status["UIDNEXT"], 90)
    }

    func testFetchRecordParsingWithLiterals() {
        let header = Data("Subject: Test\r\nFrom: a@b.c\r\n\r\n".utf8)
        let pieces: [IMAPPiece] = [
            .line("* 12 FETCH (UID 42 FLAGS (\\Seen \\Flagged) INTERNALDATE \"05-Nov-2026 10:00:00 +0000\" RFC822.SIZE 123 BODY[HEADER.FIELDS (SUBJECT FROM)] {\(header.count)}"),
            .literal(header),
            .line(" BODY[TEXT]<0> {12}"),
            .literal(Data("Preview body".utf8)),
            .line(")"),
            .line("A0002 OK FETCH completed")
        ]

        let records = IMAPSupport.parseFetchRecords(pieces)
        XCTAssertEqual(records.count, 1)
        let record = records[0]
        XCTAssertEqual(record.sequence, 12)
        XCTAssertEqual(IMAPSupport.firstCapture(#"\bUID\s+(\d+)"#, in: record.text), "42")
        XCTAssertEqual(IMAPSupport.flags(in: record.text), ["\\SEEN", "\\FLAGGED"])
        XCTAssertEqual(record.literals.count, 2)
        XCTAssertEqual(record.literals[0].data, header)
        XCTAssertTrue(IMAPSupport.PartLiteralContext.header(record.literals[0]))
        XCTAssertTrue(IMAPSupport.PartLiteralContext.preview(record.literals[1]))
    }

    func testMultipleFetchRecords() {
        let pieces: [IMAPPiece] = [
            .line("* 1 FETCH (UID 10 FLAGS ())"),
            .line("* 2 FETCH (UID 11 FLAGS (\\Seen))"),
            .line("A0003 OK done")
        ]
        let records = IMAPSupport.parseFetchRecords(pieces)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.sequence), [1, 2])
    }

    func testModifiedUTF7() {
        XCTAssertEqual(IMAPUTF7.decode("Entw&APw-rfe"), "Entwürfe")
        XCTAssertEqual(IMAPUTF7.decode("A&-B"), "A&B")
        XCTAssertEqual(IMAPUTF7.decode("[Gmail]/Sent Mail"), "[Gmail]/Sent Mail")
        XCTAssertEqual(IMAPUTF7.decode("&AOk-"), "é")
    }

    func testMailboxRoles() {
        XCTAssertEqual(IMAPSupport.role(path: "INBOX", flags: []), .inbox)
        XCTAssertEqual(IMAPSupport.role(path: "[Gmail]/Sent Mail", flags: []), .sent)
        XCTAssertEqual(IMAPSupport.role(path: "Deleted Items", flags: []), .trash)
        XCTAssertEqual(IMAPSupport.role(path: "Projects", flags: ["\\Archive"]), .archive)
    }

    func testQuoting() {
        XCTAssertEqual(IMAPSupport.quote(#"Sent "Items""#), #""Sent \"Items\"""#)
        XCTAssertEqual(IMAPSupport.quote(#"a\b"#), #""a\\b""#)
        XCTAssertEqual(IMAPSupport.quote("a\r\nb"), #""ab""#)
    }
}
