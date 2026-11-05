---
sidebar_position: 7
title: Development
description: Tests, scripts, debug hooks, and building this documentation site.
---

# Development

## Tests

```bash
swift test
```

The suite covers:

- RFC 2047 encoded words and address lists
- Header unfolding, RFC 2231 filenames, quoted-printable
- Multipart extraction, HTML/plain selection, inline content, snippets
- IMAP list/status/fetch-literal parsing and modified UTF-7
- MIME message building, header-injection defense, CRLF correctness
- Account, mailbox, message, body, and attachment persistence in SQLite
- Legacy `accounts.json` migration into SQLite
- Demo mailbox reads, flags, send, move-to-Trash, and relaunch persistence

All 32 tests pass on macOS. The iOS app itself is verified by building and
launching in the simulator.

## Debug UI previews

Debug builds understand a `MAILR_UI_PREVIEW` environment variable:

```bash
SIMCTL_CHILD_MAILR_UI_PREVIEW=message \
  xcrun simctl launch --terminate-running-process booted app.mailr.Mailr
```

Modes: `inbox`, `drawer`, `message`, `attachment`, `compose`, `settings`,
`account`. The hook is compiled out of release builds.

## Project generation

The iOS project is generated with XcodeGen from `project.yml`:

```bash
make ios-project
```

Edit `project.yml` rather than the `.xcodeproj` when changing build settings or
adding source folders. The macOS build uses Swift Package Manager and
`Scripts/build-app.sh`.

## Documentation site

This site is a Docusaurus app in `website/`.

```bash
cd website
npm install
npm run start      # local dev server at http://localhost:3000/mailr/
npm run build      # production build in website/build
npm run serve      # preview the production build
```

From the repository root:

```bash
make docs          # start the local docs server
make docs-build    # production build
```

### Deployment

The site deploys to GitHub Pages automatically. Pushing to `main` with changes
under `website/` (or editing the workflow) triggers
`.github/workflows/deploy-docs.yml`, which builds the site and publishes it with
GitHub Pages.

The repository must have **Settings → Pages → Build and deployment → Source** set
to **GitHub Actions**. The published URL is:

```text
https://403access.github.io/mailr/
```

If the repository is renamed or moved, update `url`, `baseUrl`,
`organizationName`, and `projectName` in `website/docusaurus.config.ts`.
