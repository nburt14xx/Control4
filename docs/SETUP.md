# Setup

Two things to install: the **Shield Bridge** app on the NVIDIA Shield, and the
**Shield Bridge** driver in Composer Pro.

## 1. Build or download

- Every push builds both pieces in GitHub Actions. Open the latest run under
  *Actions* and download the `shield-bridge-apk` and `shield_bridge-c4z` artifacts.
- Or build locally:
  - driver: `python3 control4/tools/build_c4z.py` writes `dist/shield_bridge.c4z`
  - app: open `shield-bridge/` in Android Studio and run *Build > Build APK*, or
    `cd shield-bridge && ./gradlew assembleDebug` with the Android SDK installed.

## 2. Shield

1. On the Shield, enable **Settings > Device Preferences > About > Build** (tap
   seven times) then **Developer options > Network debugging**. From a PC:

   ```
   adb connect <shield-ip>:5555
   adb install -r app-debug.apk
   ```

   Any sideloading method works; adb is just the quickest.

2. Open **Shield Bridge** from the apps row. The service starts automatically.
3. Press **Grant 'TV listings' permission** and accept the dialog.
4. Press **Allow 'Display over other apps'** and switch it on for Shield Bridge.
5. If either screen does not appear on your firmware, grant from the PC instead:

   ```
   adb shell pm grant dev.shieldbridge android.permission.READ_TV_LISTINGS
   adb shell appops set dev.shieldbridge SYSTEM_ALERT_WINDOW allow
   ```

6. Press **Test: read Continue Watching**. It lists what has been watched on the
   box. If it is empty, play something in Netflix for a minute, back out, and
   try again.
7. Note the address on screen, e.g. `http://192.168.1.50:8765`, and give the
   Shield a DHCP reservation so it does not change.

Check from a browser on the LAN: `http://192.168.1.50:8765/api/status` should
show both permissions `true`.

## 3. Composer Pro

1. **Driver > Add or Update Driver or Agent**, pick `shield_bridge.c4z`.
2. Add *Shield Bridge* (under NVIDIA) to the room that has the Shield.
3. **Connections**. Shield Bridge is the Shield source for the room. The real
   Shield driver is only used behind the scenes for remote keys:
   - Move the Shield's own driver to a room nobody uses (a "Equipment" room),
     and disconnect its HDMI and audio outputs from the TV or AVR.
   - Bind Shield Bridge **Video Out** and **Audio Out** to the TV or AVR input
     the Shield is physically plugged into.
   - The main room now lists only Shield Bridge under Watch.
4. **Properties**:
   - *Bridge Address*: `192.168.1.50` (port 8765 assumed) or `host:port`.
   - *Shield Control Device ID*: the device ID of the Shield's own driver
     (hover over it in the project tree to see it). Arrow, OK, back and
     transport buttons pressed on Shield Bridge are relayed to it.
   - *Shield MAC Address*: only if you want Wake-on-LAN (*Wake on Select* = On).
   - *API Key*: only if you turned it on in the app.
5. **Actions > Test Connection**, then read the Lua output tab. It prints the
   app version and the two permission states.
6. Refresh Navigators.

## Optional: search with posters inside Control4

The streaming apps expose no search, so results come from the Streaming
Availability API (Movie of the Night), a database of what streams where in 66
countries. It has a free plan that needs no payment details.

1. Get a key: follow the Authentication guide at
   `docs.movieofthenight.com` (or subscribe on RapidAPI and set
   *Search API Service* to RapidAPI).
2. In Composer, Shield Bridge properties: paste it into **Search API Key**, and
   set **Search Country** to your two-letter code (`us` by default).
3. **Actions > Test Search**, then read the Lua tab. Expect a line such as
   `Shield Bridge search OK: 5 results for "Severance" in US` followed by each
   title and the installed apps that carry it.
4. Refresh Navigators. Tap the magnifier in Shield Bridge, or use the Search
   tab's **Show results here** button.

Behaviour worth knowing:

- Only what streams in your country is shown, and each result names the
  installed Shield app that plays it. *Search Includes* adds add-ons or
  rent/buy; the default is subscription and free only.
- Tapping a title already in Continue Watching resumes it exactly. Otherwise
  the title opens in its app: movies usually start playing, series open on the
  show's page so you pick the episode.
- If an app refuses the link, the driver opens the app instead.
- Results are cached for ten minutes per search to stretch the free quota.

## 4. Daily use

- Watch > Shield Bridge > **Continue Watching**. Tap a show. The room switches
  to the Shield and the show resumes where it stopped.
- Long-press (or use the item's action menu) > **Add to Room Favorites** to
  pin a show to the room's home screen for one-tap resume.
- **Apps** tab opens any installed TV app.
- The physical remote's arrows, OK, back and transport buttons work as usual:
  Shield Bridge relays them to the Shield Control Device.
- The **Remote** tab is an on-screen remote, and the Now Playing bar has
  rewind, play, pause and fast forward.
- **Shield Bridge Remote** is a second device in the room's Watch list: the
  standard Control4 remote screen with D-pad, transport, menu and number keys.
  Its keys are relayed to the Shield Control Device too. It needs no wiring:
  it feeds Shield Bridge internally. **It is the room's Shield source**: select
  it to turn the room on. Opening Shield Bridge only browses and does not change
  the room's source; starting a show puts the room on Shield Bridge Remote.
  *After Launch* picks the screen shown afterwards (Now Playing, the remote, or
  stay on the list). Control4 does not draw
  artwork on this screen type, so the poster stays on Shield Bridge's own Now
  Playing.

### One physical button

Program a keypad button or SR-260 custom button:

1. *Shield Bridge > Resume Latest* with *Room* set to the room.

That is enough: the command selects the source in the room, wakes the Shield,
and resumes the most recently watched item.

## 5. Troubleshooting

| symptom | check |
| --- | --- |
| *Bridge Status* is Offline | address, the app is open or its service running, controller can reach port 8765 |
| list empty | TV listings permission; something must have been watched since granting |
| tap does nothing on the TV | 'Display over other apps' not granted |
| show opens on its detail page | that app ignores Google's resume guideline; press Play once |
| images missing on touch screens | touch screen must reach the Shield's IP directly (same VLAN or routed) |
| Netflix asks "Who's watching?" | Netflix profile gate on cold start; pick once, later launches go straight in |

Turn on *Debug Mode* in the driver to see every HTTP call in the Lua output.
