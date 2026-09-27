#!/bin/bash
# Removes FanCool completely. Stopping the helper hands the fans back to macOS.
set -u
LABEL="com.fancool.helper"
AGENT_LABEL="com.fancool.menubar"

launchctl bootout gui/"$(id -u)"/"$AGENT_LABEL" 2>/dev/null
pkill -x FanCool 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
rm -rf "$HOME/Applications/FanCool.app"

sudo launchctl bootout system/"$LABEL" 2>/dev/null
sudo rm -f "/Library/LaunchDaemons/$LABEL.plist"
sudo rm -rf "/Library/Application Support/FanCool"
sudo rm -f /Library/Logs/FanCool.log
rm -rf /Users/Shared/FanCool

echo "FanCool removed. Fans are back under macOS control."
