---
sidebar_position: 2
title: Getting started
description: Build and run Mailr on iOS, iPadOS, or macOS.
---

# Getting started

## Requirements

- **Xcode 16 or newer** (Swift 6)
- **iOS 17+** or **macOS 14+**
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the
  Xcode project from `project.yml`

The checked-in project was built with Xcode 27 / Swift 6.4.

## iOS and iPadOS

```bash
# Regenerate the Xcode project if you changed project.yml (optional)
make ios-project

# Build and launch in the iPhone simulator
make ios-run
```

Or open `Mailr.xcodeproj` in Xcode, choose the **Mailr** scheme, and press Run.

To install on a connected iPhone or iPad:

```bash
make device-install
```

The defaults target the connected iPhone and the configured Apple Development
team. Override them with `DEVICE=<UDID>` and `TEAM=<team ID>` if you switch
devices or accounts. Automatic signing creates the provisioning profile and
keychain access group; you can also just press Run in Xcode after selecting your
team.

:::note
The project is generated with XcodeGen. Edit `project.yml` rather than the
`.xcodeproj` when changing build settings or adding new source folders.
:::

## macOS

```bash
make run        # builds build/Mailr.app and opens it
make app        # builds the .app bundle only
```

The macOS app is built with Swift Package Manager and assembled into a proper
`.app` by `Scripts/build-app.sh`. It shares `MailCore` and essentially all
SwiftUI views with iOS.

## Host server (optional)

```bash
make host-install
```

The host server downloads mail from IMAP on the Mac, keeps the origin mailbox
untouched, and lets iPhone/iPad clients sync through it. It runs as a LoginAgent
and listens on `0.0.0.0:8788`. Point clients at the Mac with:

```dotenv
MAILR_HOST_SERVER=http://<Mac-LAN-IP>:8788
```

Add each account's password in **Mailr → Settings → host account → Password** on
the Mac, or in the host `.env` file.

## Simulator shortcuts

Debug builds understand a `MAILR_UI_PREVIEW` environment variable so screenshots
and simulator runs can jump directly to a screen:

```bash
SIMCTL_CHILD_MAILR_UI_PREVIEW=message \
  xcrun simctl launch --terminate-running-process booted app.mailr.Mailr
```

Modes: `inbox`, `drawer`, `message`, `attachment`, `compose`, `settings`,
`account`. The hook is compiled out of release builds.

## Next steps

- [Connect a real account](/docs/connecting-accounts)
- [Run the tests and work on the code](/docs/development)
