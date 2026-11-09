---
sidebar_position: 4
title: Features
description: What Mailr does, from IMAP and SMTP to the MIME engine and demo mode.
---

# Features

## Navigation

- **iPhone-first navigation.** Mailboxes live in a slide-in drawer, so the
  message list is the root screen; messages push into the reader.
- **iPad and Mac** use a three-column split view.
- **Overview dashboard.** A single page aggregates message and unread counts,
  recent activity, top senders, and per-account and per-mailbox breakdowns
  across every account. Open it from the sidebar or with ⌘0.

## Mail

- **Real IMAP.** Mailbox discovery, unread counts, message lists, flags, mark
  read/unread, flagging, moving, and deleting to Trash.
- **Real SMTP.** Multipart text/HTML messages, attachments,
  In-Reply-To/References headers, and a best-effort copy in the Sent folder.
- **Search and refresh.** Local search, pull-to-refresh, and refresh on launch
  or when the app becomes active.
- **Local cache.** The message list is shown from SQLite immediately, then
  refreshed from the server. The newest 100 messages per mailbox are cached;
  older mail is fetched again when it returns to the window.
- **Host server.** The Mac owns the IMAP connections: it downloads mail without
  deleting it from the origin server, and iPhone/iPad clients sync accounts,
  mailboxes, messages, flags, moves, deletes, and sends through it. Mail that
  later disappears from the IMAP mailbox stays readable, and each opened message
  shows whether it is on the mailbox, only on the host, or both.
- **Local email tags.** The host classifies mail with a small Ollama model and
  shares editable tags with every client. Starter tags cover action items,
  newsletters, receipts, notifications, personal mail, and work. A keyword
  matcher keeps tagging usable when Ollama is offline, and tags can always be
  added or removed manually. Filter the message list by tag from the chip bar.

## Migrating from Thunderbird

- **Account import.** `mailr-import` reads a Thunderbird profile's
  `profiles.ini` and `prefs.js` and imports IMAP/SMTP servers, usernames, email
  addresses, and display names.
- **Local mail import.** Local folders, POP3 stores, and optionally IMAP offline
  caches are copied into an offline **Local Mail** account. mbox and Maildir are
  both supported, including nested `.sbd` folders, attachments, flags, and
  Thunderbird's `X-Mozilla-Status` read/flag bits.
- **Repeatable.** Re-running the import updates the same local account and
  mailboxes instead of creating duplicates.
- **Saved passwords.** `mailr-import credentials` decrypts Thunderbird's
  NSS-encrypted `logins.json`/`key4.db` entries through Thunderbird's own NSS
  libraries and writes matching passwords to the host credential file. A
  primary password must be unlocked or disabled. OAuth2 entries cannot be
  reused and need an app password.

## MIME

- **A real MIME engine.** Multipart trees, base64 and quoted-printable,
  RFC 2047 encoded words, RFC 2231 filenames, charset conversion, and inline
  `cid:` images turned into data URLs.

## Reading and writing

- **Safe HTML reader.** JavaScript is disabled, a strict Content Security Policy
  is applied, and remote images are blocked until you explicitly load them.
  Link clicks open in your browser.
- **Attachments.** View, download/save with the system file exporter, or attach
  files while composing.
- **Compose** supports multipart text and HTML, attachments, and reply headers.

## Platform integration

- Keychain password storage
- Optional App Lock with Face ID / Touch ID and device passcode fallback
- Aurora light theme (dark mode planned)
- Adaptive sheets
- Native share and file export

## Local storage

Accounts, mailboxes, message summaries, bodies, and attachments live in a single
SQLite database in Application Support (`Mailr/mailr.sqlite3`). Cached mail is
available offline and across launches.

The optional host server uses a second database (`Mailr/host-mail.sqlite3`) on
the host machine. Install it with `make host-install`, or run it with
`swift run MailrServer`. It downloads mail from IMAP on the host and keeps the
origin untouched; clients connect to it over HTTP. Cached mail stays readable
when the host is offline, but new mail requires the host to be reachable.

## Demo mode

A seeded offline mailbox ships with the app, containing attachments, HTML mail,
drafts, and sent mail. It lets you try the whole interface before configuring an
account. Demo changes are stored in the same SQLite database, so flags,
deletions, and sent messages survive relaunches.

:::tip
The demo mailbox is seeded once. Deleting all of its mailboxes does not reset it
to the original state.
:::
