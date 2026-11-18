# Tap Sleep — sleep your e-reader without the power button

A [KOReader](https://github.com/koreader/koreader) plugin for people whose power button is broken, worn out or just hard to press.

Tap Sleep puts your e-reader into a **"fake sleep"**: it shows one of your sleep-screen images, turns off the front light (and Wi-Fi), and ignores every touch. **Tap the screen twice quickly to wake** and you're back on the same page.

Real sleep switches the touchscreen off, so no software can wake it with a tap. Tap Sleep keeps the device just awake enough to feel your taps, and it falls back to real sleep when the battery gets low.

## Demo

<p align="center">
  <img src="docs/demo.gif" alt="Tap Sleep demo on a Kindle Paperwhite 3: long-press the corner to sleep, tap twice to wake" width="300">
</p>

Long-press the corner to sleep and a screensaver appears with the light off. Tap twice and you're back on your page. [Watch the full-quality video (MP4)](docs/demo.mp4).

## Features

- Sleep with any KOReader gesture (for example, a long-press on a corner) or from the menu
- Wake with 2 quick taps, or 3 if you want to avoid waking it by accident in a bag
- Shows a random image from your KOReader sleep-screen folder
- Front light off while asleep and restored exactly as it was on wake
- Wi-Fi off while asleep (optional) and reconnected quietly on wake
- Keeps the device from really sleeping on its own, so Keep alive isn't needed
- If the power button or a magnetic cover is used while asleep, waking takes you straight back to your book
- Battery guard: falls back to real sleep at a chosen battery level (default 10%; off while charging)
- Optional "real sleep after 1 / 2 / 4 / 8 hours"
- Extra taps after waking are ignored, so they don't turn the page
- If KOReader crashes or restarts while asleep, the light and settings are restored on the next start

## Requirements

- A **touchscreen** e-reader running **KOReader** (recent versions; developed on v2026.07.1)
- Tested on: **Kindle Paperwhite 3 (7th gen)**
- Should work on other Kindles, Kobo and Cervantes devices (untested so far; reports welcome)

## Installation

1. Download `tapsleep.koplugin-vX.Y.Z.zip` from the [Releases](../../releases) page and unzip it. You should get a folder named **`tapsleep.koplugin`**.
2. Connect your e-reader to a computer (on Kindle, exit KOReader first so the drive appears).
3. Copy the `tapsleep.koplugin` folder into KOReader's `plugins` folder:
   - **Kindle:** `koreader/plugins/`
   - **Kobo:** `.adds/koreader/plugins/`
4. Eject the device safely and start KOReader.
5. Check it's on: **gear → Device → Tap Sleep** should appear. If not, enable it in **wrench → More tools → Plugin management**.

## Set up a gesture to sleep

1. **Gear → Taps and gestures → Gesture manager.**
2. Pick a gesture you don't use. Recommended: **Long-press on corner → Bottom right.**
3. Choose **General → Tap Sleep (screen off)**.
4. Do the same in both the **file browser** and **inside a book** if you want it everywhere. They have separate gesture lists.

## Usage

| Action | How |
|---|---|
| Sleep | Your gesture, or **gear → Device → Tap Sleep → Sleep now** |
| Wake | Tap the screen **2 times quickly** (or 3, if you chose that) |
| Real sleep | Power button as usual. Pressing it again returns you to your book |

### Settings (gear → Device → Tap Sleep)

- **Taps to wake:** 2 or 3
- **Turn off Wi-Fi while asleep:** on by default
- **Real sleep when battery ≤ X%:** off / 5 / 10 (default) / 20
- **Real sleep after:** never (default) / 1 / 2 / 4 / 8 hours

## Battery

Fake sleep uses **more battery than real sleep**, because the processor has to stay awake to notice your taps. It uses **less than leaving the screen on**, because the light and Wi-Fi are off and e-ink uses no power to keep showing an image. How much it drains depends on the device. Check your battery % overnight. Use the battery guard and the "Real sleep after" option for long breaks.

## Troubleshooting

- **Taps don't wake it:** tap twice quickly and firmly in the middle of the screen, within about 0.7 seconds. The first 1.5 seconds after falling asleep are ignored on purpose.
- **Stuck:** the power button still works. If all else fails, hold the power button for up to 40 seconds to restart.
- **A pop-up appeared on top while asleep:** your first taps close the pop-up; then tap again to wake.
- **Bug reports:** open an issue and attach KOReader's `crash.log` (lines starting with `TapSleep:` show what the plugin did).

## Uninstall

Delete the `tapsleep.koplugin` folder from KOReader's `plugins` folder.

## License

[GNU AGPL-3.0](LICENSE), the same as KOReader.
