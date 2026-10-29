# GlanceFocus

A small macOS menu bar app for people with more than one display. It uses the camera to see
which screen you're facing and puts keyboard focus there, so what you type lands on the screen
you're looking at.

## How it works

- **It reads your head, not your eyes.** A laptop webcam can't reliably tell where your eyes
  point across two monitors, but it can easily see which way your head is turned. Apple's
  on-device Vision framework gives the head's left/right (yaw) and up/down (pitch) angle for
  each frame.
- **Calibration.** A dot appears on each display in turn. You look at it, and GlanceFocus
  remembers the average head angle for that display. After that, it focuses whichever display
  your head is closest to pointing at. If the camera can't see your face at all when you turn to
  one display (for example a monitor far to the side), it learns that too: losing your face means
  "that display".
- **Switching.** Once you've looked at a display for the switch delay (0.4 s by default), the
  frontmost window on it is brought forward and gets keyboard focus. The edge of that screen
  glows briefly so you can see the switch happened. The pointer moves there too, back to where
  you last left it on that screen. You can turn both off.
- **Pause from anywhere** with **⌃⌥⌘G** (Control-Option-Command-G). Press it again to resume.
- **It stays out of your way.** If you're still typing as you turn your head, the switch is
  skipped, so you can glance at the other screen without losing your place. If you click
  something after turning, it leaves focus where you clicked. It also waits until you let go of
  the mouse if you're dragging something.

## Build and install (on the Mac)

You need macOS 13 Ventura or later and Apple's command line tools. If you don't have Xcode, run
this once to install them:

```bash
xcode-select --install
```

Copy this folder to the Mac, open Terminal in it, and run:

```bash
bash build.sh install
```

That builds `build/GlanceFocus.app`, signs it for your Mac, and copies it to `/Applications`.
If your account can't write there, as on many work Macs, it goes to `~/Applications` instead. The
last line of the output says which. Then open it, using that folder:

```bash
open /Applications/GlanceFocus.app
```

```bash
open ~/Applications/GlanceFocus.app
```

An eye icon appears in the menu bar.

### First launch

1. **Camera:** click Allow when macOS asks.
2. **Calibration** starts on its own. Look at the dot on each screen, turning your head the way
   you normally would. It takes about 3 seconds per screen. Press Esc to cancel.
3. **Accessibility:** macOS asks you to allow GlanceFocus under System Settings › Privacy &
   Security › Accessibility. This permission is what lets it bring a window forward and give it
   keyboard focus. Without it, only the pointer moves.

## Menu

| Item | What it does |
| --- | --- |
| Status line | What it's doing now, e.g. "Looking at DELL U2720Q" |
| Follow My Gaze (⌃⌥⌘G) | Turns switching on or off. When off, the camera is off. The shortcut works from any app. |
| Calibrate… | Run calibration again. Do this after rearranging your desk or monitors. |
| Switch Delay | How long you need to look at a screen before it takes focus |
| Camera | Shown only if you have more than one camera, e.g. a webcam on your monitor |
| Move Pointer With Focus | Moves the pointer to the screen that just got focus |
| Flash Screen on Switch | Briefly lights up the edge of the screen that just got focus |
| Launch at Login | Starts GlanceFocus when you log in |
| Show Head Angles | For testing: shows your live head angles next to the menu bar icon, plus the angles calibration saved for each screen (see below) |

### Reading the head angles

With Show Head Angles on, the menu bar shows something like `12°, -3° → 2`:

- **12°** is how far your head is turned left or right.
- **-3°** is how far it's tilted up or down.
- **→ 2** is the screen it thinks you're facing. Screens are numbered as in the menu and in calibration.
- **no face** means the camera can't see your face in that frame.

The menu lists the angles saved for each screen during calibration. If the live numbers while
you look at a screen are far from that screen's saved numbers, calibrate again.

## Privacy

- **Video never leaves memory.** Each frame goes to Apple's on-device face detector, two
  angles are read from it, and the frame is dropped. Nothing is recorded, saved, or uploaded.
- **No network.** The app has no networking code at all.
- **The only things stored** are your menu choices and the calibration: two numbers per display
  (the average head angle). They live in `~/Library/Preferences/local.glancefocus.plist`.
- **Keyboard:** the app asks macOS how many seconds it has been since the last key press, so it
  doesn't switch while you're typing. It never sees which keys you press and doesn't install a
  key logger or event tap. The ⌃⌥⌘G shortcut uses the standard hot key system, which tells the
  app only when that exact combination is pressed.
- **The camera turns off** when you pause it, when only one display is connected, when the screen
  is locked or asleep, and after 5 minutes without keyboard or mouse activity. It turns back on
  when you return. The green camera light is on whenever it's running. macOS always shows it, and
  it can't be hidden.

## Light on resources

- No dependencies, under 1,000 lines of Swift.
- About 8 frames a second at 640×480. Face detection uses Apple's built-in, hardware-accelerated
  Vision framework.
- Menu bar only: no window, no Dock icon, nothing running in the background besides the camera loop.

## Troubleshooting

- **It focuses the wrong screen.** Turn on Show Head Angles and compare the live numbers with the
  saved ones in the menu. Calibrate again and turn your head, not just your eyes, toward each dot.
  Good lighting on your face helps. If your screens are close together, try a longer Switch Delay.
- **The lid is closed (clamshell mode).** The built-in camera is off then. Plug in a webcam and
  choose it under Camera. Choosing a camera starts a new calibration.
- **Focus stopped working after rebuilding.** Each build gets a new signature, so macOS forgets
  the Accessibility permission. Reset it and allow it again:

  ```bash
  tccutil reset Accessibility local.glancefocus
  ```

- **Reading on one screen while typing on another.** If you keep typing while you turn, focus
  stays put. If you stop typing first and then look over, the other screen takes focus. For long
  sessions of copying text from one screen into the other, pause GlanceFocus from the menu.
- **The first key or two still goes to the old screen.** Focus moves after the switch delay, so
  keys you press before then go where focus was. Pick Quick under Switch Delay to shorten it.

## Uninstall

Quit it from the menu, then delete it from whichever folder it was installed in:

```bash
rm -rf /Applications/GlanceFocus.app ~/Applications/GlanceFocus.app
```

```bash
defaults delete local.glancefocus
```

## Project layout

| File | Role |
| --- | --- |
| `Sources/GlanceFocus/HeadTracker.swift` | Camera capture and Vision head pose |
| `Sources/GlanceFocus/Calibration.swift` | Per-display head poses and the math to compare them |
| `Sources/GlanceFocus/CalibrationController.swift` | The full-screen calibration dots |
| `Sources/GlanceFocus/FocusEngine.swift` | Smoothing, switch delay, and the typing/clicking rules |
| `Sources/GlanceFocus/FocusSwitcher.swift` | Brings a window forward and moves the pointer (Accessibility API) |
| `Sources/GlanceFocus/FocusFlash.swift` | The glow around a screen when it gets focus |
| `Sources/GlanceFocus/Hotkey.swift` | The ⌃⌥⌘G pause shortcut |
| `Sources/GlanceFocus/AppDelegate.swift` | Menu bar UI and when the camera runs |
| `build.sh` | Builds and signs `GlanceFocus.app` |
