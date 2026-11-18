# Changelog

## 2.0.0
- The device is kept out of real suspend while Tap Sleep is active, so Keep alive is no longer needed.
- If a real suspend happens anyway (power button, magnetic cover, battery guard), the fake sleep screen is dismissed and the light and Wi-Fi are restored after waking, so you return straight to your book.
- Tap counting is built in, so it no longer depends on KOReader's double-tap detection. You can choose 2 or 3 taps.
- New battery guard (real sleep at 5, 10 or 20%), plus an optional maximum fake-sleep duration.
- Extra taps right after waking are ignored, and so are touches during the first 1.5 seconds of sleep.
- After a crash or restart, the front light and auto-sleep setting are put back.
- Unreadable sleep-screen images are skipped.

## 1.0.0
- First version: fake sleep with a screensaver image, front light and Wi-Fi off, double-tap to wake.
