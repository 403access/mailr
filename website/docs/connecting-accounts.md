---
sidebar_position: 3
title: Connecting an account
description: Provider settings, app-specific passwords, and TLS behaviour.
---

# Connecting an account

1. Open the ellipsis menu on iPhone (or Settings on Mac).
2. Tap **Add**, choose a provider preset, and enter your email address.
3. Enter an **app-specific password** when the provider requires one, then tap
   **Test** and **Save**.

## Provider presets

| Provider | IMAP | SMTP | Notes |
| --- | --- | --- | --- |
| iCloud | `imap.mail.me.com:993` | `smtp.mail.me.com:465` | App-specific password from appleid.apple.com |
| Gmail | `imap.gmail.com:993` | `smtp.gmail.com:465` | Google app password; 2-Step Verification required |
| Yahoo | `imap.mail.yahoo.com:993` | `smtp.mail.yahoo.com:465` | App password |
| Fastmail | `imap.fastmail.com:993` | `smtp.fastmail.com:465` | App password |
| Zoho | `imap.zoho.com:993` | `smtp.zoho.com:465` | App-specific password when 2FA is enabled |
| Custom | Your server | Your server | Direct TLS on the chosen ports |

## Host server mode

When a host server is configured, the Mac owns the IMAP connections and the
iPhone/iPad app syncs through it. Accounts come from the host instead of being
added on each device.

```bash
make host-install    # build, install, and start the LoginAgent
```

Set `MAILR_HOST_SERVER=http://<mac-lan-address>:8788` in `.env` on the client.
The host server needs each account's password in one of two places:

1. `MAILR_ACCOUNT_<NAME>_PASSWORD` in the host `.env`, or
2. `Application Support/Mailr/host-credentials.json`, written by
   `mailr-import credentials` or by **Mailr → Settings → host account →
   Password** on the Mac. This file is created with `0600` permissions.

The background sync downloads mail into the host database but never deletes or
expunges messages on the origin server. The newest 100 messages per mailbox are
kept current, and older bodies are fetched on demand. Host mode has no
authentication and uses plain HTTP, so keep it on a trusted local network.

## TLS

Mailr deliberately uses **implicit TLS** (IMAP 993 / SMTP 465). STARTTLS-only
endpoints are not supported yet, so providers that require SMTP submission on
port 587 (for example Outlook/Microsoft 365) can receive mail but cannot send
through Mailr.

:::warning
The “None (insecure)” option exists only for local development servers. Mailr
warns when it is selected.
:::

## Migrating from Thunderbird

Mailr ships a command-line importer that reads a local Thunderbird profile:

```bash
swift run mailr-import list          # profiles, accounts, and local mail folders
swift run mailr-import import        # import the default profile
swift run mailr-import import --import-passwords
swift run mailr-import credentials   # import saved passwords only
```

It imports IMAP account settings and copies local mbox/Maildir folders into a
**Local Mail** account stored in Mailr's SQLite database. Saved passwords are
decrypted through Thunderbird's NSS libraries and written to
`Application Support/Mailr/host-credentials.json` with `0600` permissions. A
Thunderbird primary password must be unlocked or disabled first; OAuth2 entries
(for example Gmail) cannot be reused and need an app password. Accounts that
already exist with the same email address are skipped unless `--overwrite` is
passed. POP3 accounts are imported as local mail only, and STARTTLS-only custom
servers are skipped because Mailr uses implicit TLS.

Run `swift run mailr-import --help` for all options, and quit and reopen Mailr
after importing.

## Credentials

Passwords are stored in the **macOS/iOS Keychain**, keyed by account UUID.
Account metadata is a JSON file in Application Support with `0600` permissions
on macOS. Credentials are only sent after the TLS connection is established,
unless you explicitly select the insecure plaintext option.
