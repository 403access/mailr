---
sidebar_position: 8
title: Limitations
description: Known gaps and possible next steps for Mailr.
---

# Limitations

- No OAuth sign-in (app passwords only).
- No STARTTLS upgrade; direct TLS only.
- No background push or scheduled sync. Mail refreshes on launch, when the app
  becomes active, on pull-to-refresh, and manually.
- The local cache stores the newest 100 messages per mailbox; older mail is
  fetched from the server when it returns to the window.
- Search is local. There is no server-side search yet.
- Compose does not autosave drafts, and there is no conversation/thread view or
  undo-delete.
- Attachments are downloaded on demand from the full message body; there is no
  BODYSTRUCTURE-based lazy attachment fetching.
- The demo mailbox is seeded once into SQLite and is not reset by deleting its
  mailboxes. Remove the app's data to get a fresh demo.
- The host archive is optional, unauthenticated, and loopback-first. It is meant
  for a trusted personal machine, not as a shared mail server.
