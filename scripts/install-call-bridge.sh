#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/mac-call-helper"
SUPPORT="$HOME/Library/Application Support/call-bridge"
PLUGIN_DST="$HOME/Library/Application Support/opendeck/plugins/com.craigbell.callbridge.sdPlugin"
LAUNCH="$HOME/Library/LaunchAgents/at.craig.call-bridge.plist"
ICON_SRC="$HOME/Library/Application Support/opendeck/Backup/plugins/com.microsoft.teams.sdPlugin/icons"
ICON_FALLBACK="$HOME/Library/Application Support/opendeck/images/99-355499441494-293S/Teams/teams-icons"

echo "==> build call-bridge"
swift build -c release --package-path "$HELPER"
BIN="$(swift build -c release --package-path "$HELPER" --show-bin-path)/call-bridge"
mkdir -p "$SUPPORT"
cp "$BIN" "$SUPPORT/call-bridge"
chmod 755 "$SUPPORT/call-bridge"
codesign --force --sign - --identifier at.craig.call-bridge "$SUPPORT/call-bridge"
# Separate copy for OpenDeck so LaunchAgent can spawn while the plugin is running.
cp "$BIN" "$PLUGIN_DST/call-bridge"
chmod 755 "$PLUGIN_DST/call-bridge"
codesign --force --sign - --identifier com.craigbell.callbridge "$PLUGIN_DST/call-bridge"

echo "==> install OpenDeck plugin"
mkdir -p "$PLUGIN_DST"
cp "$ROOT/com.craigbell.callbridge.sdPlugin/manifest.json" "$PLUGIN_DST/manifest.json"
if [[ -d "$ICON_SRC" ]]; then
  rsync -a "$ICON_SRC/" "$PLUGIN_DST/icons/"
elif [[ -d "$ICON_FALLBACK" ]]; then
  rsync -a "$ICON_FALLBACK/" "$PLUGIN_DST/icons/"
else
  echo "warning: no Teams icons found to copy" >&2
fi
# plugin store icon
if [[ -f "$PLUGIN_DST/icons/logos/MSTeamsLogoPluginStoreIcon@2x.png" ]]; then
  cp "$PLUGIN_DST/icons/logos/MSTeamsLogoPluginStoreIcon@2x.png" "$PLUGIN_DST/icons/plugin.png"
  cp "$PLUGIN_DST/icons/logos/MSTeamsLogoPluginStoreIcon@2x.png" "$PLUGIN_DST/icons/plugin@2x.png"
fi
echo "==> Zoom / volume icons"
swift "$ROOT/scripts/render_opendeck_icons.swift"

echo "==> LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$LAUNCH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>at.craig.call-bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SUPPORT/call-bridge</string>
    <string>daemon</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/call-bridge.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/call-bridge.err.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/at.craig.call-bridge" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCH"
launchctl enable "gui/$(id -u)/at.craig.call-bridge"
launchctl kickstart -k "gui/$(id -u)/at.craig.call-bridge"

echo "==> OpenDeck profiles (quit first so Default.json is not overwritten)"
osascript -e 'tell application "OpenDeck" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
  if ! pgrep -x OpenDeck >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
python3 "$ROOT/scripts/rewire_opendeck_profiles.py"
open -a OpenDeck >/dev/null 2>&1 || true

echo
echo "Installed. Grant Accessibility (and Input Monitoring if prompted) to:"
echo "  $SUPPORT/call-bridge"
echo "Then restart OpenDeck so it loads the Call Bridge plugin."
echo "Doctor: $SUPPORT/call-bridge doctor"
