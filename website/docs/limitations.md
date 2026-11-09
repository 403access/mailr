---
sidebar_position: 8
title: Limitations
description: Known gaps and possible next steps for Mailr.
---

# Limitations

- No OAuth sign-in (app passwords only).
- No STARTTLS upgrade; direct TLS only.
- Thunderbird password import requires an unlocked profile and cannot reuse
  OAuth2 tokens; those accounts need an app password. POP3 cannot be used as a
  live account, and STARTTLS-only custom servers are skipped. Tags, address
  books, calendars, and message filters are not imported.
- No background push or scheduled sync. Mail refreshes on launch, when the app
  becomes active, on pull-to-refresh, and manually.
- The local cache stores the newest 100 messages per mailbox; older mail is
  fetched from the server when it returns to the window.
- Search is local. There is no server-side search yet.
- Tagging requires host mode. The default `qwen2.5:1.5b` model is small and fast
  but less accurate than a larger model. Keyword fallback is intentionally
  simple, and there is no per-user training or feedback loop yet.
- Compose does not autosave drafts, and there is no conversation/thread view or
  undo-delete.
- Attachments are downloaded on demand from the full message body; there is no
  BODYSTRUCTURE-based lazy attachment fetching.
- The demo mailbox is seeded once into SQLite and is not reset by deleting its
  mailboxes. Remove the app's data to get a fresh demo.
- The host server is unauthenticated plain HTTP on the local network. It is meant
  for a trusted personal machine, not as a shared or internet-facing mail server.
- Clients need the host server for new IMAP mail, actions, and sending. Cached
  mail stays readable offline, but refreshing requires the host to be reachable.
