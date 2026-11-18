# Shield Bridge for Control4

Continue watching from Control4. The Shield's system-wide **Continue Watching**
list (Netflix, Prime Video, Disney+, Max, Hulu and any other app that publishes
to Android TV's Watch Next row) appears in Navigator with poster art, and one tap
powers up the room, wakes the Shield and resumes the show where it left off.

```
 Control4 Navigator            Control4 controller               NVIDIA Shield
 ┌──────────────────┐          ┌──────────────────────┐          ┌────────────────────────┐
 │ Watch            │          │ shield_bridge.c4z    │  HTTP    │ Shield Bridge app       │
 │  Shield Bridge   │ ──────▶ │ (Media Service Proxy │ ───────▶│  /api/continue          │
 │   Continue       │   MSP    │  driver, Lua)        │  JSON    │  /api/launch            │
 │   Watching       │ ◀────── │                      │ ◀───────│  reads Watch Next table │
 │   [poster] ...   │          │ selects room source, │          │  starts the show's own  │
 └──────────────────┘          │ WOL, forwards remote │          │  resume intent          │
                               └──────────────────────┘          └────────────────────────┘
```

## Pieces

| path | what |
| --- | --- |
| `shield-bridge/` | Android TV app (Kotlin). Foreground service with a small LAN HTTP API. Reads the Watch Next table, serves cached poster art, launches intents. |
| `control4/shield_bridge/` | DriverWorks driver (`driver.xml`, `driver.lua`, icons). Media Service Proxy UI with *Continue Watching* and *Apps* tabs, room favorites, programming commands. |
| `control4/test/` | Lua 5.1 tests that run the driver against a fake C4 runtime. |
| `control4/tools/` | `build_c4z.py` packs and validates the driver; `gen_icons.py` regenerates icons. |
| `docs/SETUP.md` | Install steps for the Shield and Composer. |
| `docs/API.md` | The bridge's HTTP API. |

## Why this works

Android TV keeps a system-wide `watch_next_program` table. Apps write rows with
title, episode, poster, playback position and an intent that resumes playback.
Google requires apps publishing there to resume "from the last playback
position" and "start playback immediately". An app holding the user-grantable
`READ_TV_LISTINGS` permission can read every row flagged searchable, which is the
default. Plain ADB cannot, because the shell user lacks that permission. So the
bridge is a tiny app on the Shield, and the Control4 driver talks to it.

## Building

- Driver: `python3 control4/tools/build_c4z.py` (validates XML and icon paths,
  writes `dist/shield_bridge.c4z`). Tests: `lua5.1 control4/test/test_driver.lua`.
- App: open `shield-bridge/` in Android Studio, or `cd shield-bridge && ./gradlew assembleDebug`
  with the Android SDK present. CI builds both on every push and uploads them as
  workflow artifacts.

## Status

First cut, built against the public DriverWorks samples and the Android
TvProvider source but not yet exercised on hardware. The first milestone is the
spike in `docs/SETUP.md`: install the app, grant the two permissions, confirm the
Test button lists your Netflix row, then confirm `POST /api/launch` resumes it.
Known soft spots to verify on a real system are listed in the driver's
documentation page (Composer shows it on the driver's Documentation tab).

## License

MIT, see `LICENSE`. The driver's XML follows the structure of Snap One's public
DriverWorks samples; no Snap One library code is included.
