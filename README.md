# Touch Bar Controller

Some Touch Bars intermittently flash after a Mac wakes or its lid opens. On the Mac this project was built for, turning the backlight off and then on again stops the flashing. We could not find another app that actually powers off the Touch Bar backlight, so Touch Bar Controller automates that reset after every wake: it requests the backlight off as soon as I/O Kit reports that wake has begun, then restores the selected mode two seconds after the last wake signal.

The background app can also leave the bar off, show the normal macOS controls, or show F1–F12 buttons. A companion `touchbarctl` command provides direct `on`, `off`, and `status` controls.

This project uses undocumented macOS APIs. It has been tested on an Apple Silicon MacBookPro17,1 running macOS 27.0. Other models and macOS versions may behave differently.

## Notes

This was undertaken as an experiment in vibe-coding. Everything was written with GPT-6 Sol, with no human oversight except to verify that it functions. Works On My Machine™

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

These commands control the hardware backlight directly. They do not change the background app's saved mode, which the app restores after wake or a mode change. Use the Command shortcut below to change the persistent mode. `status` reports the Touch Bar backlight driver's power state, not the entire display controller's state.

## Background controls

- Double-tap **Command** within 0.3 seconds to switch the Touch Bar off or restore the last visible mode.
- Double-tap **Option** within 0.3 seconds to switch between the normal Touch Bar and F1–F12.
- Hold **Fn** while the Touch Bar is off to show the last visible mode temporarily. Releasing Fn turns it off again.

The selected mode survives app restarts. After sleep or lid open, the app requests the backlight off when system power-on begins, retries every 10 ms for about 500 ms while the hardware comes online, and repeats the request after power-on and at the workspace wake notification. It restores the selected mode two seconds after the last signal. If the mode was off before sleep, it stays off.

For each wake, the app logs `wake_off_delay_ms=<number>` when the first backlight-off call succeeds, measured from the first wake signal with a monotonic clock. If no call succeeds before the selected mode is restored, it logs `wake_off_delay_ms=unavailable`. The number measures the API call's successful completion, not a physical display measurement. To average the recorded successful calls from the past seven days:

```sh
log show --last 7d --style compact --predicate 'process == "TouchBarController" AND eventMessage CONTAINS "wake_off_delay_ms="' | sed -nE 's/.*wake_off_delay_ms=([0-9.]+).*/\1/p' | awk '{ sum += $1; count++ } END { if (count) printf "%.3f ms across %d wakes\n", sum / count, count; else print "No successful wake samples" }'
```

## Permissions

The shortcuts and F1–F12 key presses need access in **System Settings > Privacy & Security > Device Control and Data Access** on macOS 27. On older macOS versions, look under **Accessibility**. A tap on an F key requests keyboard event-posting access if it is missing. macOS can track that separately from Accessibility, so grant both prompts if they appear. The CLI's backlight command may also request device-control access.

The app and CLI are signed ad hoc when built. Rebuilding can invalidate an existing permission entry, so `make install` resets this app's Accessibility and keyboard event-posting approvals before restarting it. You still need to grant the new build access in System Settings. If a reset reports an error, remove the old Touch Bar Controller entry there manually and restart the app with `launchctl kickstart -k gui/$(id -u)/local.touchbar.controller`.

## Remove

To remove the installation and local build output:

```sh
make uninstall
```

This stops the agent, attempts to restore the backlight, removes the app and LaunchAgent, clears its saved mode, attempts to reset its permission entries, and deletes project-specific cache and saved-state files. 

## How it works

The CLI and background app call the private `DFRBrightnessClient` API for the `TouchBarUserDevice` HID service. The background app keeps its brightness client ready in-process, presents a blank or F1–F12 system-modal Touch Bar when needed, and posts F-key events. Turning the backlight off changes `AppleARMBacklight` under `backlight-dfr` to `CurrentPowerState = 0`; it does not fully power down the Touch Bar display or controller. This behavior is unsupported by Apple and could change with a macOS update.

Released under the [MIT License](LICENSE).
