# Roku Bridge setup

A full replacement for the stock Roku driver. It talks to the Roku over the
network (port 8060); nothing is installed on the Roku.

## 1. Roku

1. **Settings > System > Advanced system settings > Control by mobile apps >
   Network access**: set to **Enabled** (or Permissive). Since early 2025 the
   default is Limited, which blocks network control.
2. Find the IP under Settings > Network > About and give it a DHCP reservation.

## 2. Composer Pro

1. **Driver > Add or Update Driver or Agent**, pick `roku_bridge.c4z`.
2. Add *Roku Bridge* (under Roku) to the room. Remove the stock Roku driver
   from that room, or move it to an unused one.
3. **Connections**: bind **Video Out** and **Audio Out** to the TV or AVR input
   the Roku is plugged into.
4. **Properties**: *Roku Address* = the IP. For search, *Search API Key* (free,
   from the Authentication guide at `docs.movieofthenight.com`; the Shield
   Bridge key works here too) and *Search Country*.
5. **Actions > Test Connection**. The Lua tab should show the Roku's name,
   model and OS, then `control is working`.
6. **Actions > Test Search**. Each result line ends with the channel and
   content id that tapping it would launch.
7. Refresh Navigators.

## 3. What to expect

- **Search**: results show which installed channel carries a title. One
  channel plays at once; several open a chooser. A title on a channel that is
  not installed can open that channel's install page on the Roku.
- **Recent**: what you launched from Search. The driver cannot see what was
  started with the Roku's own remote, since Roku exposes no watch history.
- **Deep links are best effort.** Every channel names its titles differently,
  and Roku gives no error for an id it does not accept: the channel just opens
  to its home screen. Each launch prints a line such as
  `Roku Bridge: launch Hulu (channel 2285) contentId=... mediaType=series`.
  If a channel lands on its home screen, that line is what is needed to fix
  the rule for it.
- **Play and Pause**: Roku has a single toggle key, so the driver reads the
  player state first and only toggles when that changes something.
- **No power commands** by default. *Power Commands* offers "go Home when the
  room turns off" or real power control for Roku TVs.

Tests: `lua5.1 control4/test/test_roku.lua`. Package:
`python3 control4/tools/build_c4z.py --driver roku_bridge`.
