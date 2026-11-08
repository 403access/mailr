#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="release"
swift build -c "$CONFIG" --product MailrServer
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MailrServer"

SUPPORT="$HOME/Library/Application Support/Mailr"
DEST="$SUPPORT/MailrServer"
mkdir -p "$SUPPORT"
install -m 700 "$BIN" "$DEST"

if [ -f .env ]; then
    install -m 600 .env "$SUPPORT/.env"
fi

PORT="${MAILR_HOST_PORT:-}"
if [ -z "$PORT" ] && [ -f .env ]; then
    PORT="$(sed -nE 's#^MAILR_HOST_SERVER=.*:([0-9]+).*#\1#p' .env | head -1)"
fi
PORT="${PORT:-8787}"

AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/app.mailr.host-archive.plist"
LOGS="$HOME/Library/Logs/Mailr"
mkdir -p "$AGENTS" "$LOGS"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>app.mailr.host-archive</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST</string>
        <string>--host</string>
        <string>0.0.0.0</string>
        <string>--port</string>
        <string>$PORT</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOGS/host-archive.log</string>
    <key>StandardErrorPath</key>
    <string>$LOGS/host-archive.log</string>
</dict>
</plist>
PLIST

DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$DOMAIN/app.mailr.host-archive"

echo "Installed Mailr host server at $DEST"
echo "Listening on 0.0.0.0:$PORT (LaunchAgent app.mailr.host-archive)"
