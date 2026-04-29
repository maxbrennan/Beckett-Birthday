# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A macOS desktop Electron + Elm quiz game built as a birthday gift. It detects AirPods Max 2 via a native C binary, runs a 10-question music quiz, and punishes wrong answers with an increasingly brutal IQ test (spacebar-press reaction game).

## Commands

```bash
npm run build:c    # Compile native C binary (list_audio_devices)
npm run build:elm  # Compile Elm → elm.js
npm run build      # Both of the above
npm start          # Build + launch Electron app
```

No tests or linter configured.

## Architecture

**Elm (`Main.elm`)** owns all game logic and state. The app is a state machine with 8 screen types driven by `update` and a pending-event queue that fires messages at `model.now >= fireAt`. Browser `AnimationFrame` ticks at 60fps to drive this clock.

**`renderer.js`** bridges Elm ports to Electron APIs: plays audio/video files, runs the native binary every 100ms to detect AirPods, manages the flash overlay DOM element.

**`electron.js`** is minimal — creates a 900×600 window with `nodeIntegration: true`, `contextIsolation: false`, and autoplay enabled.

**`list_audio_devices.c`** uses CoreAudio + Foundation to enumerate output devices and identify AirPods Max 2 by manufacturer/transport type. Compiled to a binary and invoked by `renderer.js` via `child_process`.

## Key Design Details

**Debug flag** (`Main.elm` lines 37–39): `debug = True` in source right now. This shortens ding intervals, reduces required correct presses, and bypasses the AirPods requirement. Flip to `False` before deployment.

**Pending event queue**: Timed transitions (e.g., show flash → hide flash → resume game) are scheduled as `{ fireAt : Int, msg : Msg }` entries evaluated on each `Tick`. Chained animations use recursive `update` calls.

**IQ test mechanics**:
- Dings fire every 2–15 seconds (debug: 5s fixed)
- 10–100 correct presses required (debug: 10)
- Wrong answer doubles `totalDings`
- A fake flash trap fires at 85–95% through the ding sequence (debug: 65–75%) to catch spacebar-on-visual responses
- A 50% random ding phase starts after the fake flash to prevent pattern detection

**Ports (Elm ↔ JS)**:
- `receiveDevices` — JSON array of detected audio devices
- `playMusic` / `stopMusic` / `playVideo` — media playback
- `playDing` / `showFlash` — IQ test stimulus feedback
- `receiveTrackInfo` / `trackEnded` — media lifecycle callbacks
- `logToFile` — appends to `debug.log` with before/after state snapshots

**Assets** (`Assets/`): mp3 music tracks, mp4 videos, png images — loaded by `renderer.js` using `path.join(__dirname, 'Assets', ...)`.
