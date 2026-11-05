import XCTest
@testable import MailCore

final class PlaceholderTests: XCTestCase {
    func testCoreLoads() {
        XCTAssertEqual(MailboxRole.inbox.displayName, "Inbox")
    }
}
