---
sidebar_position: 5
title: Architecture
description: How Mailr is organised, from the cross-platform MailCore engine to the SwiftUI app.
---

# Architecture

```text
Sources/
  MailCore/                 Cross-platform engine (also a SwiftPM library)
    Models.swift            Accounts, mailboxes, messages, attachments, errors
    MIMEHeader.swift        Header maps, RFC 2047/2231, charsets, structured headers
    MIMEParser.swift        MIME tree, transfer decoding, body/attachment extraction
    IMAPSupport.swift       IMAP tokenizer/parsers, modified UTF-7, fetch records
    IMAPClient.swift        Async IMAP client, literals, flags, move, append
    IMAPMailService.swift   Account-level service with reconnects
    SMTPClient.swift        EHLO, AUTH LOGIN/PLAIN, DATA, dot-stuffing
    MessageBuilder.swift    RFC 5322 / MIME composition
    SocketConnection.swift  Async TLS byte stream on Network.framework
    MailService.swift       Service protocol, account store, Keychain store
    MailDatabase.swift      Synchronous SQLite store for local mail data
    HostMailStore.swift     Host archive configuration, wire types, HTTP client
    HostMailServer.swift    Loopback HTTP server and request router
    DemoMailService.swift   Seeded offline mailbox
  MailrServer/              Standalone host archive executable
  Mailr/                    SwiftUI app
    AppModel.swift          MainActor observable state and actions
    RootView.swift          Adaptive iPhone / iPad+Mac shells
    SidebarView.swift       Accounts, mailboxes, iPhone mailbox drawer
    MessageListView.swift   Message browser and rows
    MessageDetailView.swift Reader, actions, attachment export
    HTMLMessageView.swift   Locked-down WKWebView (iOS and macOS)
    ComposeView.swift       Compose sheet and file importer
    SettingsView.swift      Account management and Privacy entry
    AccountEditorView.swift Provider presets, IMAP/SMTP settings, test
    AppLock.swift           Face ID / Touch ID lock state via LocalAuthentication
    LockScreenView.swift    Opaque unlock cover
    SecuritySettingsView.swift App Lock setup page
    Platform.swift          iOS/macOS conditional helpers
Tests/MailCoreTests/        Parser, builder, IMAP, and demo-service tests
project.yml                 XcodeGen definition for the iOS app
Support/Info.plist          macOS bundle metadata
Support/Mailr.entitlements  iOS Keychain access group
Support/Icon/               Generated app-icon masters
Scripts/build-app.sh        macOS .app bundler
Scripts/make-icon.sh        Regenerates the app icon (macOS + iOS)
```

## Modules

`MailCore` has no UI dependencies and can be reused. The iOS target compiles it
as an embedded framework; the macOS target consumes the same sources as the
`MailCore` SwiftPM library.

The app layer is a thin `MainActor` model over the service protocol. Views never
talk to a socket directly: `AppModel` owns the current account, mailbox, message
list, and selection, and calls into an `IMAPMailService` (or `DemoMailService` in
demo mode). Reads and writes go through `MailDatabase`, a small synchronous
SQLite store serialized with a recursive lock.

## Connection flow

1. `SocketConnection` opens a TLS connection through Network.framework, using
   the system trust store and a 30-second connect timeout.
2. `IMAPClient` speaks the protocol: capability discovery, login, mailbox
   listing, fetch with literals, flag changes, move, and append.
3. `IMAPMailService` wraps the client with reconnect handling and exposes
   account-level operations.
4. `MIMEParser` turns fetched message bodies into a tree of text, HTML, and
   attachment parts.
5. `HTMLMessageView` renders sanitised HTML in a locked-down `WKWebView`.

Outgoing mail is built by `MessageBuilder` (RFC 5322/MIME, CRLF, header-injection
defence) and sent by `SMTPClient` using EHLO plus AUTH LOGIN or PLAIN.

## Storage

- Accounts, mailboxes, message summaries, bodies, and attachment blobs are stored
  in a single SQLite database at `Application Support/Mailr/mailr.sqlite3`.
- The database uses WAL journaling and is created with `0600` permissions; the
  containing directory is `0700` on macOS.
- Passwords live in the Keychain, keyed by account UUID — never in the database.
- Pre-SQLite `accounts.json` files are imported once and renamed
  `accounts.json.migrated`.
- Message lists show cached rows immediately, then refresh from the server. The
  cache keeps the newest 100 messages per mailbox.
- The demo mailbox is seeded into the same database the first time it is opened.
- The optional host archive runs as a separate loopback HTTP process and writes
  to `Mailr/host-mail.sqlite3`. Messages carry an `on_mailbox` flag so the reader
  can distinguish mailbox-only, host-only, and mirrored mail.
