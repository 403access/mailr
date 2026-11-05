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

## TLS

Mailr deliberately uses **implicit TLS** (IMAP 993 / SMTP 465). STARTTLS-only
endpoints are not supported yet, so providers that require SMTP submission on
port 587 (for example Outlook/Microsoft 365) can receive mail but cannot send
through Mailr.

:::warning
The “None (insecure)” option exists only for local development servers. Mailr
warns when it is selected.
:::

## Credentials

Passwords are stored in the **macOS/iOS Keychain**, keyed by account UUID.
Account metadata is a JSON file in Application Support with `0600` permissions
on macOS. Credentials are only sent after the TLS connection is established,
unless you explicitly select the insecure plaintext option.
