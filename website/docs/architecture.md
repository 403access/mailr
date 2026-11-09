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
    LocalMailService.swift  MailService backed by imported local mail
    ThunderbirdProfiles.swift Thunderbird profiles.ini and prefs.js parsing
    ThunderbirdAccounts.swift Thunderbird account/local-folder mapping
    ThunderbirdLocalStore.swift mbox and Maildir scanning and parsing
    ThunderbirdImporter.swift Account and local-mail import orchestration
    StableIdentifier.swift  Deterministic account UUIDs for imports
    HostMailStore.swift     Host server configuration, wire types, HTTP client
    HostMailServer.swift    HTTP server, router, and async action bridge
    HostMailSync.swift      Host-side IMAP downloader and origin proxy
    HostMailService.swift   Client MailService backed by the host HTTP API
    Tagging.swift           Editable tags, Ollama classifier, keyword fallback
    DemoMailService.swift   Seeded offline mailbox
  MailrServer/              Standalone host server executable
  MailrImport/              mailr-import command-line tool
  Mailr/                    SwiftUI app
    AppModel.swift          MainActor observable state and actions
    RootView.swift          Adaptive iPhone / iPad+Mac shells
    SidebarView.swift       Accounts, mailboxes, iPhone mailbox drawer
    OverviewView.swift      Stats dashboard across all accounts and mailboxes
    MessageListView.swift   Message browser, tag filter, rows
    MessageDetailView.swift Reader, tags, actions, attachment export
    TagViews.swift          Tag chips, picker, filter bar, and tag editor
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
list, and selection, and calls into an `IMAPMailService` when host mode is off,
or `HostMailService` when the host server owns the accounts. The demo uses
`DemoMailService`; imported local mail can use `LocalMailService`. Reads and
writes go through `MailDatabase`, a small synchronous SQLite store serialized
with a recursive lock.

In host mode, `HostMailSyncEngine` opens the IMAP connections, downloads
mail into `host-mail.sqlite3`, and proxies user actions back to the origin.
Clients discover accounts from `GET /v1/accounts` and never open IMAP
themselves.

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
- The optional host server runs as a separate HTTP process, writes to
  `Mailr/host-mail.sqlite3`, and owns the IMAP connections. It downloads mail
  without deleting it from the origin server. Messages carry an `on_mailbox`
  flag so the reader can distinguish mailbox-only, host-only, and mirrored mail.
- Clients in host mode keep an offline cache in their own `mailr.sqlite3` and
  use the host for new mail, actions, and sending.
- Tag definitions, per-message assignments, and classification state live in
  `host-mail.sqlite3`. The host classifies new mail with a local Ollama model
  and exposes tags over `/v1/tags`, `/v1/messages/tags`, and `/v1/classify`.
