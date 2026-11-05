---
sidebar_position: 6
title: Security and privacy
description: How Mailr protects credentials, message rendering, and your data.
---

# Security and privacy

## Credentials and local storage

- Passwords live in the **macOS/iOS Keychain**, keyed by account UUID.
- Account metadata, cached mailboxes, message summaries, bodies, and attachments
  are stored in a **SQLite database** in Application Support
  (`Mailr/mailr.sqlite3`). The file is created with `0600` permissions and the
  containing directory with `0700` on macOS. Existing `accounts.json` files are
  imported once and renamed.
- The database is not separately encrypted by Mailr; it relies on the app
  sandbox and the operating system's device encryption.
- Credentials are only sent after the TLS connection is established, unless the
  user explicitly selects the insecure plaintext option.

## Transport

- TLS is handled by **Network.framework** with the system trust store and a
  30-second connect timeout.
- Mailr uses implicit TLS (IMAP 993 / SMTP 465). STARTTLS-only endpoints are not
  supported yet.
- The “None (insecure)” option is intended for local development servers and
  triggers a warning when selected.

## Rendering

The HTML reader:

- disables JavaScript,
- uses a non-persistent web data store,
- injects a restrictive Content Security Policy,
- blocks remote images by default to prevent tracking pixels,
- opens link clicks in your browser instead of inside the app.

## Data collection

There is **no analytics, crash reporting, or remote logging**. Mailr talks to
your IMAP and SMTP servers and nowhere else.

## What Mailr does not protect against

- A compromised mail provider or server.
- Malicious content you explicitly load, such as remote images you choose to
  fetch.
- A compromised device or operating system.
- Plaintext connections if you deliberately enable the insecure option.
