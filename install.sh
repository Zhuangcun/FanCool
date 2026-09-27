#!/bin/bash
# Builds and installs FanCool: a root helper (launchd daemon) + a menu bar app.
# Run from Terminal:  ./install.sh      (it will ask for your password once)
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.fancool.helper"
AGENT_LABEL="com.fancool.menubar"
HELPER_DIR="/Library/Application Support/FanCool"
HELPER="$HELPER_DIR/fancoold"
DAEMON_PLIST="/Library/LaunchDaemons/$LABEL.plist"
APP_DIR="$HOME/Applications/FanCool.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos12.0"

if [[ "$(id -u)" == "0" ]]; then
  echo "Run this as your normal user (not with sudo); it asks for sudo when needed."; exit 1
fi
if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install Apple's Command Line Tools first:"
  echo "    xcode-select --install"
  exit 1
fi

echo "==> Building ($TARGET)"
rm -rf build && mkdir -p build
swiftc -O -swift-version 5 -target "$TARGET" -o build/fancoold \
  Sources/Common/Config.swift Sources/Daemon/*.swift
swiftc -O -swift-version 5 -target "$TARGET" -parse-as-library -o build/FanCool \
  Sources/Common/Config.swift Sources/App/FanCoolApp.swift

mkdir -p build/FanCool.app/Contents/MacOS
cp build/FanCool build/FanCool.app/Contents/MacOS/FanCool
cat > build/FanCool.app/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FanCool</string>
  <key>CFBundleIdentifier</key><string>$AGENT_LABEL</string>
  <key>CFBundleExecutable</key><string>FanCool</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - build/fancoold >/dev/null
codesign --force --sign - build/FanCool.app >/dev/null

echo "==> Quick hardware check"
./build/fancoold --probe || true

echo "==> Installing helper (needs your password)"
sudo launchctl bootout system/"$LABEL" 2>/dev/null || true
sudo mkdir -p "$HELPER_DIR"
sudo install -o root -g wheel -m 755 build/fancoold "$HELPER"
sudo tee "$DAEMON_PLIST" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$HELPER</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Library/Logs/FanCool.log</string>
  <key>StandardErrorPath</key><string>/Library/Logs/FanCool.log</string>
</dict></plist>
EOF
sudo chown root:wheel "$DAEMON_PLIST"
sudo chmod 644 "$DAEMON_PLIST"
sudo launchctl bootstrap system "$DAEMON_PLIST"

echo "==> Installing menu bar app"
mkdir -p /Users/Shared/FanCool
[[ -f /Users/Shared/FanCool/settings.json ]] || echo '{"mode":"auto","startTemp":75}' > /Users/Shared/FanCool/settings.json
launchctl bootout gui/"$(id -u)"/"$AGENT_LABEL" 2>/dev/null || true
pkill -x FanCool 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$APP_DIR"
cp -R build/FanCool.app "$APP_DIR"
cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key><array><string>$APP_DIR/Contents/MacOS/FanCool</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
launchctl bootstrap gui/"$(id -u)" "$AGENT_PLIST"

echo
echo "Done. Look for the fan icon in your menu bar."
echo "  Log:        /Library/Logs/FanCool.log"
echo "  Test fans:  sudo \"$HELPER\" --test"
echo "  Uninstall:  ./uninstall.sh"
