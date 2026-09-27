# FanCool

A very small fan booster for Apple Silicon MacBook Pro / Mac mini / Mac Studio.

macOS keeps fans slow and quiet until the chip is quite hot. FanCool watches the
hottest chip sensor every 2 seconds and, once it passes your threshold (75 °C by
default), ramps the fans up. When the chip cools 6 °C below the threshold, it hands
the fans straight back to macOS.

It only ever adds cooling: while boosting, fan speed never drops below what macOS
was already running, and at 95 °C it goes to full speed.

## Install

1. If you don't have Apple's Command Line Tools: `xcode-select --install`
2. In Terminal, from this folder: `chmod +x install.sh uninstall.sh && ./install.sh`
3. Enter your password when asked (the helper needs root to talk to the fans).

A fan icon with the chip temperature appears in the menu bar (↑ means boosting).

## Menu

- **Auto boost when hot**: the normal mode.
- **Max fans**: all fans at maximum until you switch back.
- **Off (macOS default)**: FanCool never touches the fans.
- **Start boosting at**: 60–85 °C.

## Useful commands

    "/Library/Application Support/FanCool/fancoold" --probe       # fans + every sensor
    sudo "/Library/Application Support/FanCool/fancoold" --test   # max fans for 8 s
    tail -f /Library/Logs/FanCool.log                              # boost on/off history

## How it works

- `fancoold` (root, launchd daemon, a few MB of RAM): reads temperatures from the
  IOHID sensors, controls fans through the SMC (`Ftst` unlock, `F#Md` mode,
  `F#Tg` target). Returns fans to automatic whenever it stops.
- `FanCool.app` (menu bar, no Dock icon): only reads `status.json` and writes
  `settings.json`; it never touches hardware. Quitting it doesn't stop cooling.

## Uninstall

    ./uninstall.sh
