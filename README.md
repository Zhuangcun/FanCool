# FanCool

A very small fan booster for Apple Silicon MacBook Pro / Mac mini / Mac Studio.

macOS keeps fans slow and quiet until the chip is quite hot. FanCool watches the
hottest chip sensor every 2 seconds and, once it passes your threshold (75 °C by
default), ramps the fans up. When the chip cools 6 °C below the threshold, it hands
the fans straight back to macOS.

It only ever adds cooling: while boosting, fan speed never drops below what macOS
was already running, and at 95 °C it goes to full speed.

## Install

**1. Unzip.** Double-click `FanCool.zip` in Finder. You get a `FanCool` folder next
to it (usually `~/Downloads/FanCool`).

**2. Open Terminal** (press ⌘ Space, type `Terminal`, press Return).

**3. Make sure Apple's Command Line Tools are installed** (they include the Swift
compiler). Paste this and press Return:

    xcode-select -p

If it prints a path such as `/Library/Developer/CommandLineTools`, you're set. If it
prints an error, run `xcode-select --install`, click **Install** in the window that
pops up, wait for it to finish (a few minutes), then continue.

**4. Go into the FanCool folder.** If it's in Downloads:

    cd ~/Downloads/FanCool

If you moved it somewhere else, type `cd ` (with a space after it), drag the
`FanCool` folder from Finder onto the Terminal window, and press Return. Terminal fills
in the path for you. To check you're in the right place, run `ls`. You should see
`install.sh`, `uninstall.sh`, `README.md` and `Sources`.

**5. Run the installer:**

    bash install.sh

It builds the app (about 30 seconds), prints a quick hardware check, and then asks for
your Mac login password once. The background helper needs administrator rights to
control the fans. As you type the password, nothing shows on screen. That's normal.
Type it and press Return.

When it prints `Done.`, you should see a fan icon and the chip temperature in the menu
bar (↑ means it's boosting). You can close Terminal. FanCool starts by itself each
time you log in.

> Why `bash install.sh` and not `./install.sh`? `./install.sh` only works if the file
> is marked as executable, and unzipping sometimes removes that mark. You'd then see
> "permission denied" and need `chmod +x install.sh` first. `bash install.sh` works
> either way.

**6. (Optional) Test the fans:**

    sudo "/Library/Application Support/FanCool/fancoold" --test

Your fans should get loud for 8 seconds, then settle back down.

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

In Terminal, go into the FanCool folder as in step 4, then run:

    bash uninstall.sh
