---
slug: /
sidebar_position: 1
title: Overview
description: Mailr is a native, privacy-first IMAP and SMTP mail client for iPhone, iPad, and Mac.
---

# Mailr

A native, privacy-first mail client for **iPhone and iPad**, with a macOS build
from the same SwiftUI codebase. Mailr talks directly to IMAP and SMTP servers —
there is no proxy, no account server, and no telemetry. It ships with a local
demo mailbox so you can try the whole interface before configuring an account,
and it keeps a local SQLite cache of your mail for offline reading.

<img src={require("../static/img/screens/ios-inbox.png").default} alt="Mailr inbox on iPhone" width="300" />

## Why Mailr

- **Direct connections.** Mailr speaks IMAP and SMTP itself. Your credentials go
  to your provider, never through a third party.
- **No telemetry.** No analytics, crash reporting, or remote logging.
- **Native everywhere.** One SwiftUI codebase runs on iPhone, iPad, and Mac.
- **Offline cache.** Accounts, mailboxes, summaries, bodies, and attachments are
  stored in a local SQLite database.
- **No third-party dependencies.** Only Apple frameworks and the system SQLite
  library: SwiftUI, WebKit, Network, Security, Foundation, and SQLite3.
- **Try it instantly.** A seeded demo mailbox means you can explore the app
  without an account, and your changes survive relaunches.

## Screenshots

| iPhone | iPad |
| :---: | :---: |
| <img src={require("../static/img/screens/ios-message.png").default} alt="Message reader on iPhone" width="260" /> | <img src={require("../static/img/screens/ipad-message.png").default} alt="Message reader on iPad" width="420" /> |

| Compose | Accounts | Dark mode |
| :---: | :---: | :---: |
| <img src={require("../static/img/screens/ios-compose.png").default} alt="Compose on iPhone" width="220" /> | <img src={require("../static/img/screens/ios-settings.png").default} alt="Accounts on iPhone" width="220" /> | <img src={require("../static/img/screens/ios-dark-message.png").default} alt="Dark mode on iPhone" width="220" /> |

## Where to go next

- [Getting started](/docs/getting-started) — build and run on iOS or macOS.
- [Connecting an account](/docs/connecting-accounts) — provider settings and
  app-specific passwords.
- [Architecture](/docs/architecture) — how the codebase is organised.
- [Security and privacy](/docs/security) — the threat model and protections.
