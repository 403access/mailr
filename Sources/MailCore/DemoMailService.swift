import Foundation

/// A fully local mailbox used for first-launch demoing and for trying the UI
/// without configuring a server. State is stored in the shared SQLite
/// database, so flags, deletions, and sent messages survive relaunches.
public actor DemoMailService: MailService {
    private let database: MailDatabase
    private let accountID: UUID
    private var seeded = false

    /// Pass the app's database to persist the demo mailbox. Omitting it uses a
    /// private in-memory database, which keeps tests and previews isolated.
    public init(database: MailDatabase? = nil) {
        self.database = database ?? MailDatabase(inMemory: true)
        self.accountID = MailAccount.demoID
    }

    public func listMailboxes() async throws -> [Mailbox] {
        try seedIfNeeded()
        return Mailbox.sorted(try database.loadMailboxes(accountID: accountID))
    }

    public func fetchMessages(mailbox: String, limit: Int) async throws -> [MessageSummary] {
        try seedIfNeeded()
        try await simulateLatency()
        try requireMailbox(mailbox)
        return try database.loadMessages(accountID: accountID, mailbox: mailbox, limit: limit)
    }

    public func fetchMessage(mailbox: String, uid: UInt32) async throws -> MailMessage {
        try seedIfNeeded()
        try await simulateLatency()
        guard let message = try database.loadMessage(accountID: accountID, mailbox: mailbox, uid: uid) else {
            throw MailError.commandFailed("That message is no longer available.")
        }
        return message
    }

    public func setFlags(
        mailbox: String,
        uid: UInt32,
        flags: Set<MessageFlag>,
        enabled: Bool
    ) async throws {
        try seedIfNeeded()
        try await simulateLatency(120)
        try database.updateFlags(
            accountID: accountID,
            mailbox: mailbox,
            uid: uid,
            isRead: flags.contains(.seen) ? enabled : nil,
            isFlagged: flags.contains(.flagged) ? enabled : nil,
            isAnswered: flags.contains(.answered) ? enabled : nil
        )
    }

    public func move(mailbox: String, uid: UInt32, to destination: String) async throws {
        try seedIfNeeded()
        try await simulateLatency(180)
        guard destination != mailbox else { return }
        try requireMailbox(destination)
        guard try database.moveMessage(
            accountID: accountID,
            from: mailbox,
            uid: uid,
            to: destination
        ) != nil else {
            throw MailError.commandFailed("That message is no longer available.")
        }
    }

    public func delete(mailbox: String, uid: UInt32) async throws {
        try seedIfNeeded()
        if mailbox == "Trash" {
            try database.deleteMessage(accountID: accountID, mailbox: mailbox, uid: uid)
            return
        }
        try await move(mailbox: mailbox, uid: uid, to: "Trash")
    }

    public func send(_ message: OutgoingMessage) async throws {
        try seedIfNeeded()
        try await simulateLatency(500)
        guard !message.allRecipients.isEmpty else {
            throw MailError.invalidMessage("Add at least one recipient.")
        }

        let uid = try database.maxUID(accountID: accountID) + 1
        let now = Date()
        let summary = MessageSummary(
            uid: uid,
            mailbox: "Sent",
            subject: message.subject.isEmpty ? "(No subject)" : message.subject,
            from: [message.from],
            to: message.to,
            cc: message.cc,
            date: now,
            snippet: String(message.text.prefix(160)),
            size: message.text.utf8.count,
            isRead: true,
            hasAttachments: !message.attachments.isEmpty,
            messageID: "<demo-\(uid)@mailr.app>",
            inReplyTo: message.inReplyTo,
            references: message.references
        )

        let attachments = message.attachments.map {
            MailAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
        }

        let body = MailMessage(
            summary: summary,
            text: message.text,
            html: DemoSeed.plainTextHTML(message.text),
            attachments: attachments
        )

        try database.saveMessage(body, accountID: accountID)
    }

    public func close() async {}

    // MARK: Helpers

    private func seedIfNeeded() throws {
        guard !seeded else { return }
        seeded = true

        let boxes = try database.loadMailboxes(accountID: accountID)
        guard boxes.isEmpty else { return }

        let seed = DemoSeed.make()
        try database.saveMailboxes(seed.mailboxes, accountID: accountID)
        for body in seed.bodies.values {
            try database.saveMessage(body, accountID: accountID)
        }
    }

    private func requireMailbox(_ path: String) throws {
        let boxes = try database.loadMailboxes(accountID: accountID)
        guard boxes.contains(where: { $0.path == path }) else {
            throw MailError.commandFailed("No mailbox named \(path).")
        }
    }

    private func simulateLatency(_ milliseconds: Int = 250) async throws {
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
}

// MARK: - Seed data

private enum DemoSeed {
    struct Seed {
        var mailboxes: [Mailbox]
        var messages: [String: [MessageSummary]]
        var bodies: [String: MailMessage]
    }

    static func plainTextHTML(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        return """
        <div style="font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif; \
        font-size: 14px; line-height: 1.6; max-width: 720px;">\(escaped)</div>
        """
    }

    static func make() -> Seed {
        let now = Date()
        let calendar = Calendar.current

        func ago(days: Int = 0, hours: Int = 0) -> Date {
            let base = calendar.date(byAdding: .day, value: -days, to: now) ?? now
            return calendar.date(byAdding: .hour, value: -hours, to: base) ?? now
        }

        let mailboxes: [Mailbox] = [
            Mailbox(path: "INBOX", name: "Inbox", role: .inbox, delimiter: "/"),
            Mailbox(path: "Drafts", name: "Drafts", role: .drafts, delimiter: "/"),
            Mailbox(path: "Sent", name: "Sent", role: .sent, delimiter: "/"),
            Mailbox(path: "Archive", name: "Archive", role: .archive, delimiter: "/"),
            Mailbox(path: "Junk", name: "Junk", role: .junk, delimiter: "/"),
            Mailbox(path: "Trash", name: "Trash", role: .trash, delimiter: "/")
        ]

        let me = EmailAddress(address: "demo@mailr.app", name: "Mailr Demo")

        let mira = EmailAddress(address: "mira@northstudio.example", name: "Mira Chen")
        let alex = EmailAddress(address: "alex.novak@example.com", name: "Alex Novak")
        let team = EmailAddress(address: "hello@mailr.app", name: "The Mailr Team")
        let signal = EmailAddress(address: "weekly@signal.example", name: "The Signal")
        let billing = EmailAddress(address: "billing@northwind.example", name: "Northwind Studio")
        let parcel = EmailAddress(address: "tracking@parcel.example", name: "Parcel Updates")

        let notesAttachment = MailAttachment(
            filename: "Aurora-notes.md",
            mimeType: "text/markdown",
            data: Data("""
            # Aurora composer — review notes

            - Keep the compose window compact; collapse Cc/Bcc by default.
            - Use a single accent color for Send.
            - Drafts should autosave after 5 seconds of inactivity.
            - Reply/forward should preserve the original body as a quote.

            Owner: Mira
            Due: Friday
            """.utf8)
        )

        let invoiceAttachment = MailAttachment(
            filename: "Invoice-1042.txt",
            mimeType: "text/plain",
            data: Data("""
            NORTHWIND STUDIO
            Invoice #1042

            Design retainers — October        $4,800.00
            Hosting and tooling                  $120.00
            ------------------------------------------
            Total                              $4,920.00

            Payment due within 14 days.
            """.utf8)
        )

        var messages: [String: [MessageSummary]] = [:]
        var bodies: [String: MailMessage] = [:]

        // 1. Welcome
        let welcomeUID: UInt32 = 101
        let welcome = MessageSummary(
            uid: welcomeUID,
            mailbox: "INBOX",
            subject: "Welcome to Mailr",
            from: [team],
            to: [me],
            date: ago(hours: 0),
            snippet: "A small, native mail client that stays out of your way. Here is a quick tour of what you can do.",
            size: 18_400,
            isRead: false,
            messageID: "<welcome@mailr.app>"
        )
        messages["INBOX", default: []].append(welcome)
        bodies["INBOX#\(welcomeUID)"] = MailMessage(
            summary: welcome,
            text: "Welcome to Mailr. A small, native mail client that stays out of your way.",
            html: """
            <div style="font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif; font-size: 15px; line-height: 1.65; max-width: 660px;">
              <div style="font-size: 12px; letter-spacing: 0.08em; text-transform: uppercase; color: #8a8f98; margin-bottom: 14px;">Mailr</div>
              <h1 style="font-size: 30px; line-height: 1.15; margin: 0 0 16px; letter-spacing: -0.02em;">A calmer place for email.</h1>
              <p style="margin: 0 0 14px;">Mailr is a small, native mail client built with SwiftUI. It connects directly to your IMAP and SMTP servers — no middleman, no tracking pixels, no data collection.</p>
              <p style="margin: 0 0 14px;">This demo mailbox is stored entirely on this device. Try it out:</p>
              <ul style="margin: 0 0 20px; padding-left: 22px;">
                <li style="margin-bottom: 6px;">Select a message to read it, and watch it mark itself as read.</li>
                <li style="margin-bottom: 6px;">Star, delete, or reply from the toolbar.</li>
                <li style="margin-bottom: 6px;">Use the compose button to write something.</li>
              </ul>
              <div style="border-left: 3px solid #4c8dff; padding: 12px 16px; background: rgba(76, 141, 255, 0.08); border-radius: 6px; margin-bottom: 22px;">
                <strong>Ready for real mail?</strong> Add an account from Settings. Mailr supports any provider with direct TLS (IMAP 993 / SMTP 465).
              </div>
              <p style="margin: 0; color: #8a8f98; font-size: 13px;">— The Mailr Team</p>
            </div>
            """
        )

        // 2. Design review (unread, attachment)
        let reviewUID: UInt32 = 102
        let review = MessageSummary(
            uid: reviewUID,
            mailbox: "INBOX",
            subject: "Design review: Aurora composer",
            from: [mira],
            to: [me],
            cc: [alex],
            date: ago(hours: 2),
            snippet: "I went through the compose flow again this morning. A few notes on spacing, the attachment tray, and autosave.",
            size: 42_800,
            isRead: false,
            hasAttachments: true,
            messageID: "<aurora-review@northstudio.example>",
            references: ["<thread-aurora@northstudio.example>"]
        )
        messages["INBOX", default: []].append(review)
        bodies["INBOX#\(reviewUID)"] = MailMessage(
            summary: review,
            text: "I went through the compose flow again this morning. Notes attached.",
            html: """
            <div style="font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif; font-size: 15px; line-height: 1.65; max-width: 680px;">
              <h2 style="font-size: 21px; margin: 0 0 14px; letter-spacing: -0.01em;">Aurora composer — review notes</h2>
              <p style="margin: 0 0 14px;">Hi there,</p>
              <p style="margin: 0 0 14px;">I went through the compose flow again this morning. It is close — the structure feels right. A few notes before we lock it:</p>
              <ol style="margin: 0 0 18px; padding-left: 22px;">
                <li style="margin-bottom: 8px;"><strong>Attachment tray.</strong> Files should appear as compact chips below the subject, not inside the body editor.</li>
                <li style="margin-bottom: 8px;"><strong>Autosave.</strong> Five seconds of idle time is enough. Show a quiet “Saved” indicator rather than a modal.</li>
                <li style="margin-bottom: 8px;"><strong>Reply context.</strong> Keep the quoted text collapsed by default, with the sender and date visible.</li>
              </ol>
              <p style="margin: 0 0 18px;">I dropped the full list into the attached markdown file so nothing gets lost in the thread.</p>
              <p style="margin: 0 0 4px;">Thanks,</p>
              <p style="margin: 0; color: #555;">Mira</p>
              <hr style="border: none; border-top: 1px solid rgba(127,127,127,0.25); margin: 22px 0;">
              <p style="margin: 0; font-size: 12px; color: #8a8f98;">Mira Chen · Design · North Studio</p>
            </div>
            """,
            attachments: [notesAttachment]
        )

        // 3. Weekly digest (read)
        let digestUID: UInt32 = 103
        let digest = MessageSummary(
            uid: digestUID,
            mailbox: "INBOX",
            subject: "The Signal — issue 47",
            from: [signal],
            to: [me],
            date: ago(days: 1, hours: 3),
            snippet: "This week: the quiet return of RSS, a field guide to focus, and why the best interfaces disappear.",
            size: 61_200,
            isRead: true,
            messageID: "<signal-47@signal.example>"
        )
        messages["INBOX", default: []].append(digest)
        bodies["INBOX#\(digestUID)"] = MailMessage(
            summary: digest,
            text: "The Signal issue 47.",
            html: """
            <div style="font-family: Georgia, 'Times New Roman', serif; font-size: 16px; line-height: 1.7; max-width: 680px;">
              <div style="font-family: -apple-system, sans-serif; font-size: 12px; letter-spacing: 0.12em; text-transform: uppercase; color: #b0603f; margin-bottom: 10px;">The Signal · Issue 47</div>
              <h1 style="font-size: 32px; line-height: 1.15; margin: 0 0 18px;">The quiet return of the personal feed</h1>
              <p style="margin: 0 0 16px;">For a decade, the feed was something an algorithm assembled for us. Lately, a smaller movement has been quietly rebuilding feeds that people assemble for themselves — RSS readers, hand-curated newsletters, and slow social tools.</p>
              <div style="background: #f3efe7; border-radius: 10px; padding: 18px 20px; margin: 24px 0;">
                <div style="font-family: -apple-system, sans-serif; font-size: 12px; letter-spacing: 0.08em; text-transform: uppercase; color: #8a6d4b; margin-bottom: 8px;">Also inside</div>
                <ul style="margin: 0; padding-left: 20px;">
                  <li style="margin-bottom: 4px;">A field guide to deep focus</li>
                  <li style="margin-bottom: 4px;">Why the best interfaces disappear</li>
                  <li>Five notebooks worth keeping</li>
                </ul>
              </div>
              <p style="margin: 0 0 16px;">The through-line is unsurprising: when software stops trying to capture attention, it starts to feel like a tool again.</p>
              <p style="margin: 0; font-family: -apple-system, sans-serif; font-size: 13px; color: #8a8f98;">You are receiving this because you subscribed to The Signal.</p>
            </div>
            """
        )

        // 4. Invoice (read, flagged, attachment)
        let invoiceUID: UInt32 = 104
        let invoice = MessageSummary(
            uid: invoiceUID,
            mailbox: "INBOX",
            subject: "Invoice #1042 from Northwind Studio",
            from: [billing],
            to: [me],
            date: ago(days: 1, hours: 8),
            snippet: "Your October invoice is attached. The total is $4,920.00, due within 14 days.",
            size: 24_300,
            isRead: true,
            isFlagged: true,
            hasAttachments: true,
            messageID: "<invoice-1042@northwind.example>"
        )
        messages["INBOX", default: []].append(invoice)
        bodies["INBOX#\(invoiceUID)"] = MailMessage(
            summary: invoice,
            text: "Invoice #1042 attached. Total $4,920.00.",
            html: """
            <div style="font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif; font-size: 15px; line-height: 1.65; max-width: 620px;">
              <h2 style="font-size: 21px; margin: 0 0 14px;">Invoice #1042</h2>
              <p style="margin: 0 0 14px;">Hi,</p>
              <p style="margin: 0 0 14px;">Your October invoice is attached. The total is <strong>$4,920.00</strong>, due within 14 days.</p>
              <table style="border-collapse: collapse; width: 100%; margin: 20px 0; font-size: 14px;">
                <tr style="text-align: left; color: #8a8f98;"><th style="padding: 6px 0; font-weight: 600;">Item</th><th style="padding: 6px 0; text-align: right; font-weight: 600;">Amount</th></tr>
                <tr><td style="padding: 8px 0; border-top: 1px solid rgba(127,127,127,0.2);">Design retainers — October</td><td style="padding: 8px 0; border-top: 1px solid rgba(127,127,127,0.2); text-align: right;">$4,800.00</td></tr>
                <tr><td style="padding: 8px 0; border-top: 1px solid rgba(127,127,127,0.2);">Hosting and tooling</td><td style="padding: 8px 0; border-top: 1px solid rgba(127,127,127,0.2); text-align: right;">$120.00</td></tr>
                <tr><td style="padding: 8px 0; border-top: 2px solid rgba(127,127,127,0.35); font-weight: 600;">Total</td><td style="padding: 8px 0; border-top: 2px solid rgba(127,127,127,0.35); text-align: right; font-weight: 600;">$4,920.00</td></tr>
              </table>
              <p style="margin: 0; color: #555;">Northwind Studio · Billing</p>
            </div>
            """,
            attachments: [invoiceAttachment]
        )

        // 5. Plain text thread
        let skiUID: UInt32 = 105
        let ski = MessageSummary(
            uid: skiUID,
            mailbox: "INBOX",
            subject: "Re: Ski weekend",
            from: [alex],
            to: [me],
            date: ago(days: 2, hours: 5),
            snippet: "Works for me. I can drive up Friday after work if we leave by six.",
            size: 6_400,
            isRead: true,
            messageID: "<ski-2@example.com>",
            inReplyTo: "<ski-1@example.com>",
            references: ["<ski-1@example.com>"]
        )
        messages["INBOX", default: []].append(ski)
        bodies["INBOX#\(skiUID)"] = MailMessage(
            summary: ski,
            text: """
            Works for me. I can drive up Friday after work if we leave by six.

            I booked the cabin for two nights — Saturday and Sunday. There is a
            wood stove and, according to the listing, "reliable Wi-Fi". I have
            my doubts about the Wi-Fi.

            Should I bring the big coffee pot?

            — Alex

            On Tuesday, you wrote:
            > Thinking about the first weekend of December. Are you in?
            """,
            html: nil
        )

        // 6. Package (read)
        let parcelUID: UInt32 = 106
        let parcelMessage = MessageSummary(
            uid: parcelUID,
            mailbox: "INBOX",
            subject: "Your package arrives today",
            from: [parcel],
            to: [me],
            date: ago(days: 3),
            snippet: "Out for delivery. Estimated arrival between 2:00 and 5:00 PM.",
            size: 12_100,
            isRead: true,
            messageID: "<parcel-8812@parcel.example>"
        )
        messages["INBOX", default: []].append(parcelMessage)
        bodies["INBOX#\(parcelUID)"] = MailMessage(
            summary: parcelMessage,
            text: "Your package is out for delivery.",
            html: """
            <div style="font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif; font-size: 15px; line-height: 1.6; max-width: 600px;">
              <div style="background: #eef3ff; border-radius: 12px; padding: 22px; margin-bottom: 20px;">
                <div style="font-size: 12px; letter-spacing: 0.08em; text-transform: uppercase; color: #5b7bb5; margin-bottom: 6px;">Out for delivery</div>
                <div style="font-size: 22px; font-weight: 600; margin-bottom: 4px;">Arriving today</div>
                <div style="color: #5b7bb5;">Estimated between 2:00 and 5:00 PM</div>
              </div>
              <p style="margin: 0 0 12px;">Tracking number <strong>MR-8812-4471</strong></p>
              <p style="margin: 0; color: #8a8f98; font-size: 13px;">Parcel Updates · This is an automated message.</p>
            </div>
            """
        )

        // Draft
        let draftUID: UInt32 = 201
        let draft = MessageSummary(
            uid: draftUID,
            mailbox: "Drafts",
            subject: "Offsite ideas",
            from: [me],
            to: [],
            date: ago(hours: 20),
            snippet: "Rough notes for the January offsite — keep it light, one afternoon outside.",
            size: 1_900,
            isRead: true,
            messageID: "<draft-offsite@mailr.app>"
        )
        messages["Drafts", default: []].append(draft)
        bodies["Drafts#\(draftUID)"] = MailMessage(
            summary: draft,
            text: """
            Rough notes for the January offsite:

            - One afternoon outside, weather permitting
            - Two short demos, not five
            - Leave space for an unstructured conversation
            - End by 4

            Still need a venue.
            """,
            html: nil
        )

        // Sent
        let sentUID: UInt32 = 301
        let sent = MessageSummary(
            uid: sentUID,
            mailbox: "Sent",
            subject: "Re: Ski weekend",
            from: [me],
            to: [alex],
            date: ago(days: 2, hours: 6),
            snippet: "In. I can be ready by six on Friday. I will bring the coffee.",
            size: 5_100,
            isRead: true,
            messageID: "<ski-3@mailr.app>",
            inReplyTo: "<ski-2@example.com>",
            references: ["<ski-1@example.com>", "<ski-2@example.com>"]
        )
        messages["Sent", default: []].append(sent)
        bodies["Sent#\(sentUID)"] = MailMessage(
            summary: sent,
            text: "In. I can be ready by six on Friday. I will bring the coffee.\n\n— Demo",
            html: nil
        )

        return Seed(mailboxes: mailboxes, messages: messages, bodies: bodies)
    }
}
