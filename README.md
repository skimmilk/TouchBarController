# Touch Bar Controller

Some Touch Bars intermittently flash after a Mac wakes or its lid opens. Touch Bar Controller requests the backlight off with no fade as soon as I/O Kit reports that wake has begun, keeps requesting off during recovery, then restores the selected mode two seconds after the last wake signal. When wake recovery finishes with off selected, it checks the hardware backlight driver once: if off requests leave the hardware powered, it attempts one brief on/off transition. That transition stopped a live post-wake flashing occurrence on the tested Mac. A faulted panel can still require a full Mac sleep/wake to recover; this app does not yet implement a panel power cycle.

The background app can also leave the bar off, show the normal macOS controls, or show macOS's full-width F1–F12 row. A companion `touchbarctl` command provides direct `on`, `off`, `status`, and read-only `diagnose` controls.

This project uses undocumented macOS APIs. It has been tested on an Apple Silicon MacBookPro17,1 running macOS 27.0. Other models and macOS versions may behave differently.

## Notes

This was undertaken as an experiment in vibe-coding. Everything was written with GPT-6 Sol, with no human oversight except to verify that it functions. Works On My Machine™

## Build and install

You need a Mac with a physical Touch Bar and the Xcode Command Line Tools (`xcode-select --install`). From the project directory:

```sh
make
make install
```

`make` builds `build/touchbarctl` and `build/TouchBarController.app`. `make install` stops the running app, replaces it in `~/Applications`, installs a per-user LaunchAgent, and starts it. The app runs without a Dock icon and starts again at login. No `sudo` or SIP change is needed. On a fresh install, the selected mode is the normal macOS Touch Bar.

The app bundle includes its own copy of `touchbarctl`, so it works from any install path. The CLI in `build/` is available for manual use:

```sh
./build/touchbarctl status   # prints on or off
./build/touchbarctl off
./build/touchbarctl on
./build/touchbarctl diagnose # backlight and Touch Bar framebuffer driver states
```

These commands control the hardware backlight directly. They do not change the background app's saved mode, which the app restores after wake or a mode change. A pending wake recovery can override a manual command; after recovery finishes, the app does not poll or repeatedly enforce its selected state. Use the Command shortcut below to change the persistent mode. `status` reports the Touch Bar backlight driver's power state, not the entire display controller's state.

`diagnose` reports `backlight=on|off|unavailable`, the raw `backlight_power_state`, and its `backlight_source`: `IOPowerManagement.CurrentPowerState` on `AppleARMBacklight` under `backlight-dfr`. This is independent of `DFRDisplayState`; zero means the hardware driver reports off, and a positive value means on. It also reports `backlight_nits` from that driver's `CurrentNits` property, or `unavailable` if the value cannot be read. The framebuffer properties that follow describe the separate display controller.

The `brightness.*` fields include the driver's `IODisplayParameters` values and ranges (brightness, raw brightness, millinits, uncalibrated millinits, and microamps when available), the saved normalized brightness used for restoration, the separate DFR display state and cached dimming step, and CoreBrightness's normalized brightness, nits, automatic-brightness setting, factors, luminance limits, capabilities, ambient-light information, and display brightness status. Missing properties are marked `unavailable`. Values can disagree across these sources; `CurrentNits` and CoreBrightness can retain a requested/minimum level while the powered-off driver's `BrightnessMilliNits.value` reports zero. These are software readings, not physical luminance measurements. Diagnostics only reads these properties on demand, without setting brightness, writing preferences, or adding background polling.

## Background controls

- Double-tap **Command** within 0.3 seconds to switch the Touch Bar off or restore the last visible mode.
- Double-tap **Option** within 0.3 seconds to switch between the normal Touch Bar and macOS's full-width F1–F12 row.
- Hold **Fn** while the Touch Bar is off to show the last visible controls temporarily, without switching to macOS's alternate Fn row. Release Fn to turn the bar off again. This preview leaves the saved mode off. When the bar is already on, Fn performs its normal macOS action.

While off, the app temporarily makes each native Fn presentation match its normal presentation, including per-app modes. Selecting a visible mode with double-Command or double-Option restores your original Fn settings. The saved settings also survive restarts and are restored on uninstall; independent changes in System Settings are preserved.

Function mode temporarily sets macOS's global Touch Bar presentation to Function Keys, so the native row appears in other apps too. The app restores your previous presentation setting when you leave function mode; `make uninstall` also restores it. The selected app mode survives restarts. After sleep or lid open, the app requests the backlight off when system power-on begins, retries every 10 ms for about 500 ms while the hardware comes online, then every 50 ms until recovery ends. Power-on and workspace wake notifications renew the off request. It restores the selected mode two seconds after the last signal. If the mode was off before sleep, the saved mode stays off. Fn presses during recovery cannot light the bar until recovery ends. A preview still held at that point appears in the last visible mode; releasing Fn turns it off. A preview released during recovery does not reappear afterward.

Shortcuts can change the saved mode during recovery, but cannot turn the backlight on until that interval ends. When recovery ends with off selected, the app sends a final off request and checks the hardware backlight driver once, 500 ms later. If the driver still reports powered on, the app requests on, allows 700 ms for that transition, then requests off again and verifies the driver once after another 250 ms. It keeps the blank bar and saved off mode throughout this repair. Unknown driver state does not trigger a cycle or another check. After these finite steps, there are no recurring hardware checks or backlight writes. Ordinary off mode and Fn release send a single off request without checking the driver. Turning on, holding Fn, sleep, or another wake cancels stale queued recovery work. macOS can still power the panel before the app receives or processes a wake notification, and the repair briefly enables the backlight, so this does not guarantee a completely dark wake.

For each wake, the app logs `wake_off_delay_ms=<number>` when the first backlight-off call succeeds, measured from the first wake signal with a monotonic clock. If no call succeeds before the selected mode is restored, it logs `wake_off_delay_ms=unavailable`. The number measures the API call's successful completion, not a physical display measurement. To average the recorded successful calls from the past seven days:

```sh
log show --last 7d --style compact --predicate 'process == "TouchBarController" AND eventMessage CONTAINS "wake_off_delay_ms="' | sed -nE 's/.*wake_off_delay_ms=([0-9.]+).*/\1/p' | awk '{ sum += $1; count++ } END { if (count) printf "%.3f ms across %d wakes\n", sum / count, count; else print "No successful wake samples" }'
```

## Permissions

On the Mac used for testing, the app's shortcuts, backlight controls, and function-key mode work without granting **Device Control and Data Access**. Suppressing other native actions during an Fn preview uses an optional active keyboard event filter. The app tries to install it without requesting access at startup. To enable it, enable Touch Bar Controller in **System Settings → Privacy & Security → Device Control and Data Access** on macOS 27, or **Accessibility** on older versions. After permission is granted, the app retries the filter on Fn release; restarting the app also activates it. The native Touch Bar Fn row is controlled separately because macOS changes it before either a session or HID event filter can consume the key. Without the filter, Fn still previews the unmodified Touch Bar controls and turns the bar off on release, but other configured Fn actions, such as dictation, may also run. If shortcuts fail on another macOS setup, check its keyboard-monitoring permissions in System Settings. macOS handles F1–F12 key presses in function mode.

The app and CLI are signed ad hoc when built. A new build has a different code signature, so macOS may stop trusting a previous permission grant even when its toggle still appears on. If the Fn filter remains unavailable, remove Touch Bar Controller from Device Control and Data Access (Accessibility on older macOS), add the installed `~/Applications/TouchBarController.app` again, and enable it. If macOS still reports the app as untrusted, run `tccutil reset Accessibility local.touchbar.controller`, restart the installed app, and enable its permission again. This reset only clears this app's Accessibility grant. Installation does not explicitly reset privacy approvals.

## Remove

To remove the installation and local build output:

```sh
make uninstall
```

This stops the agent, restores the previous macOS Touch Bar presentation, Fn settings, and backlight, removes the app and LaunchAgent, clears its saved mode, attempts to reset its permission entries, and deletes project-specific cache and saved-state files.

## How it works

The CLI and background app call the private `DFRBrightnessClient` API for the `TouchBarUserDevice` HID service. Shutdown uses `turnOffWithPeriod:` with a zero-second period. Disassembly of the framework on macOS 27.0.1 showed that the previous `turnOff` entry point requests a 0.5-second fade. Turning on retains the original `turnOn` call and its 0.5-second fade.

Testing revealed that off/on can leave the panel at minimum brightness even with the original on call. Before the first off request, the app saves the Touch Bar's `DisplayBrightness` level through `BrightnessSystemClient`. It restores that level using a transient CoreBrightness write 700 ms after on, without committing a new user brightness preference. Off, sleep, and newer mode decisions cancel pending restoration. The snapshot also survives app restarts and separate CLI invocations. In a manual test this restored approximately 105–106 nits instead of the 12-nit minimum observed after off/on, and normal brightness was confirmed visually. Ambient adjustment and rounding can change the exact value.

The app uses the private `DFRPresentationModeSetFNBehavior` API to apply the temporary Fn presentation while off. On restoration it preserves the exact original `PresentationModeFnModes` preference dictionary, including an originally unset value. This native presentation control works independently of the optional keyboard event filter.

The background app keeps its brightness client ready in-process, presents a blank system-modal Touch Bar when off, and selects macOS's native Function Keys presentation for function mode. Turning the backlight off changes `AppleARMBacklight` under `backlight-dfr` to `CurrentPowerState = 0`; it does not fully power down the Touch Bar display or controller. This behavior is unsupported by Apple and could change with a macOS update.

The app drains startup temporaries before entering the AppKit event loop and uses an autorelease pool for each asynchronous backlight task. It does not explicitly link the Carbon runtime; its keyboard constants only require Carbon headers. These cleanups did not materially reduce the measured idle physical footprint, which remained approximately 12 MB on the tested Mac. An allocator-reclamation experiment released no pages and was not retained. This build adds no recurring memory-management work.

### Panel recovery investigation

On the tested Apple Silicon machine, the Touch Bar framebuffer is `AppleMobileADBE0`, identified by its `dfr = true` property. The kernel's `AppleSummitLCD` driver has a separate panel power sequence involving PMU supply control, reset and power GPIOs, and delays. Merely requesting an API display power state does not establish that this sequence ran.

A Touch Bar-only test using `IOMobileFramebufferRequestPowerChange` with off/on states returned success but did not restore a panel that was flashing without displaying controls. A zero-period backlight off/on test also failed in that faulted state; full Mac sleep/wake restored it. Neither operation is exposed as a recovery command. `diagnose` only reads driver properties and cannot detect whether pixels are actually working.

A separate post-wake failure was captured with off selected: `DFRDisplayState = 1` and successful off requests disagreed with `AppleARMBacklight`, which reported `CurrentPowerState = 1` and 12 nits. A fresh-client off request also left that hardware state unchanged. Pausing the app's off retries, requesting on for 700 ms, then requesting off changed the hardware driver to state 0; the user confirmed that flashing stopped. The app now checks for this hardware mismatch once at the end of wake recovery and automates that transition. Unknown driver state does not trigger a cycle. This is a backlight recovery, not a full panel reset, and cannot establish that every flashing failure has the same cause.

The framebuffer API candidate was informed by [clamless's display helper](https://github.com/TCXM/clamless/blob/main/src/helper/clamless-display.c). The [Linux Summit panel driver](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/panel/panel-summit.c) also uses brightness zero in its suspend path; it does not provide a macOS panel-reset API. A reliable independent panel reset, or kernel-level suppression before wake, remains unresolved.

### Validation

Run `make test` for tests that replace hardware, UI effects, and brightness preference storage. They exercise wake retries, deferred shortcut changes, repeated wake signals, one-shot hardware verification, successful-but-ineffective off requests requiring a bounded on/off cycle, cancellation of recovery by on or sleep, unknown driver state, temporary Fn previews in both visible modes, release-to-off behavior, consumption of the wake press and release, normal Fn behavior when the bar is on, native Fn setting snapshots and exact restoration (including unset preferences, restarts, and independent settings changes), Fn previews held or released during wake recovery, restoration, stale queued requests, brightness snapshots across retries/restarts, and rapid off/on changes. They also assert that healthy wake, repaired wake, unknown driver state, and ordinary off mode leave no polling or repeated hardware writes while idle. They do not establish physical panel recovery or the absence of flashing; those require observations across actual sleep/wake cycles.

Released under the [MIT License](LICENSE).
