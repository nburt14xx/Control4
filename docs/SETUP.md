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
3. **Connections**. The driver sits in the video path between the Shield and
   the display, so both show up under Watch and either powers the same path:
   - Unbind the Shield driver's HDMI output from the TV or AVR input.
   - Bind the Shield driver's HDMI output to Shield Bridge **Video In (from Shield)**.
   - Bind Shield Bridge **Video Out** to the TV or AVR input the Shield used.
   - Repeat with the audio connections if the Shield's audio was bound separately.
4. **Properties**:
   - *Bridge Address*: `192.168.1.50` (port 8765 assumed) or `host:port`.
   - *Shield MAC Address*: from Settings > Device Preferences > About > Status.
   - *API Key*: only if you turned it on in the app.
5. **Actions > Test Connection**, then read the Lua output tab. It prints the
   app version and the two permission states.
6. Refresh Navigators.

## 4. Daily use

- Watch > Shield Bridge > **Continue Watching**. Tap a show. The room switches
  to the Shield and the show resumes where it stopped.
- Long-press (or use the item's action menu) > **Add to Room Favorites** to
  pin a show to the room's home screen for one-tap resume.
- **Apps** tab opens any installed TV app.
- While Shield Bridge is the selected source, the remote's transport and
  navigation buttons are forwarded to the driver on Video In, so nothing is lost.

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
