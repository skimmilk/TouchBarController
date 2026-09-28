# Touch Bar Controller

Some Touch Bars intermittently flash after a Mac wakes or its lid opens. On the Mac this project was built for, turning the backlight off and then on again stops the flashing. We could not find another app that actually powers off the Touch Bar backlight, so Touch Bar Controller automates that reset after every wake: it turns the backlight off for two seconds, then restores the selected mode.

The background app can also leave the bar off, show the normal macOS controls, or show F1–F12 buttons. A companion `touchbarctl` command provides direct `on`, `off`, and `status` controls.

This project uses undocumented macOS APIs. It has been tested on an Apple Silicon MacBookPro17,1 running macOS 27.0. Other models and macOS versions may behave differently.

## Build and install

You need a Mac with a physical Touch Bar and the Xcode Command Line Tools (`xcode-select --install`). From the project directory:

```sh
make
make install
```

`make` builds `build/touchbarctl` and `build/TouchBarController.app`. `make install` stops the running app, replaces it in `~/Applications`, clears this app's old Accessibility and keyboard event-posting approvals, installs a per-user LaunchAgent, and starts it. The app runs without a Dock icon and starts again at login. No `sudo` or SIP change is needed. On a fresh install, the selected mode is the normal macOS Touch Bar.

The app bundle includes its own copy of `touchbarctl`, so it works from any install path. The CLI in `build/` is available for manual use:

```sh
./build/touchbarctl status   # prints on or off
./build/touchbarctl off
./build/touchbarctl on
```

These commands control the hardware backlight directly. They do not change the background app's saved mode. If that mode is off, the app may turn the backlight off again within five seconds; use the Command shortcut below to change the persistent mode. `status` reports the Touch Bar backlight driver's power state, not the entire display controller's state.

## Background controls

- Double-tap **Command** within 0.3 seconds to switch the Touch Bar off or restore the last visible mode.
- Double-tap **Option** within 0.3 seconds to switch between the normal Touch Bar and F1–F12.

The selected mode survives app restarts. After sleep or lid open, the app turns the backlight off immediately, waits two seconds, and restores that mode. If the mode was off before sleep, it stays off. While off, the app checks every five seconds and turns the backlight off again if macOS re-enables it.

## Permissions

The shortcuts and F1–F12 key presses need access in **System Settings > Privacy & Security > Device Control and Data Access** on macOS 27. On older macOS versions, look under **Accessibility**. A tap on an F key requests keyboard event-posting access if it is missing. macOS can track that separately from Accessibility, so grant both prompts if they appear. The CLI's backlight command may also request device-control access.

The app and CLI are signed ad hoc when built. Rebuilding can invalidate an existing permission entry, so `make install` resets this app's Accessibility and keyboard event-posting approvals before restarting it. You still need to grant the new build access in System Settings. If a reset reports an error, remove the old Touch Bar Controller entry there manually and restart the app with `launchctl kickstart -k gui/$(id -u)/local.touchbar.controller`.

## Stop or remove

To stop automatic control for this login session:

```sh
launchctl bootout gui/$(id -u)/local.touchbar.controller
```

To start it again:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.touchbar.controller.plist
```

To uninstall, stop the agent, then remove `~/Library/LaunchAgents/com.local.touchbar.controller.plist` and `~/Applications/TouchBarController.app`. If the backlight is off, run `./build/touchbarctl on` first.

## How it works

The CLI calls the private `DFRBrightnessClient` API for the `TouchBarUserDevice` HID service. The background app runs that same CLI from inside its bundle, presents a blank or F1–F12 system-modal Touch Bar when needed, and posts F-key events. Turning the backlight off changes `AppleARMBacklight` under `backlight-dfr` to `CurrentPowerState = 0`; it does not fully power down the Touch Bar display or controller. This behavior is unsupported by Apple and could change with a macOS update.

Released under the [MIT License](LICENSE).
