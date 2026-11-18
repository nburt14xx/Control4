# Shield Bridge HTTP API

The app listens on every interface of the Shield, port `8765` by default. All
responses are JSON except the two image endpoints. If an API key is enabled in
the app, every request must carry it as an `X-Api-Key` header or `?key=` query
parameter; otherwise the server answers `401`.

Try it from any browser on the LAN: `http://<shield-ip>:8765/api/status`.

## GET /api/status

```json
{
  "ok": true,
  "app": "shield-bridge",
  "version": "0.1.0",
  "device": "NVIDIA SHIELD Android TV",
  "android": 30,
  "port": 8765,
  "addresses": ["192.168.1.50"],
  "apiKeyRequired": false,
  "permissions": { "readTvListings": true, "displayOverOtherApps": true },
  "watchNextCount": 14,
  "watchNextError": "",
  "uptimeMs": 123456
}
```

Both permissions must be `true` for the integration to work: the first to read
the list, the second to start another app from the background.

## GET /api/continue

Query parameters:

| name | meaning |
| --- | --- |
| `limit` | max rows, default 50 |
| `types` | comma list of `CONTINUE,NEXT,NEW,WATCHLIST`; default all |
| `package` | only rows from this app package |
| `all=1` | include rows the user hid (`browsable=false`) |

Rows are ordered newest engagement first.

```json
{
  "ok": true,
  "generatedAt": 1763500000000,
  "total": 14,
  "items": [
    {
      "id": 101,
      "package": "com.netflix.ninja",
      "app": "Netflix",
      "title": "Severance",
      "episodeTitle": "Hide and Seek",
      "season": "2",
      "episode": "4",
      "type": "TV_EPISODE",
      "watchNextType": "CONTINUE",
      "positionMs": 1200000,
      "durationMs": 3300000,
      "progress": 36,
      "lastEngagementMs": 1763499000000,
      "art": "http://192.168.1.50:8765/api/art/101",
      "artSource": "https://.../poster.jpg",
      "artWidth": 200,
      "artHeight": 300,
      "intentUri": "intent://www.netflix.com/title/81233755#Intent;scheme=https;...;end",
      "contentId": "81233755",
      "description": "",
      "browsable": true
    }
  ]
}
```

`watchNextType` meanings, from Android's Watch Next contract:

- `CONTINUE`: stopped part-way; launching resumes at the saved position.
- `NEXT`: the next episode after one that was finished.
- `NEW`: a new episode of a followed series.
- `WATCHLIST`: added to a watchlist, not started.

## GET /api/art/{id}

The row's poster, fetched once by the Shield and cached on its disk. Use this
rather than `artSource` so touch screens never talk to a CDN.

## GET /api/apps

```json
{ "ok": true, "apps": [ { "package": "com.netflix.ninja", "label": "Netflix", "icon": "http://192.168.1.50:8765/api/icon/com.netflix.ninja" } ] }
```

## GET /api/icon/{package}

PNG of the app's TV banner (or icon).

## POST /api/launch

Body (JSON) or query string with exactly one of:

| field | effect |
| --- | --- |
| `id` | launch the Watch Next row's own intent, which resumes playback |
| `intentUri` | launch an `intent://...` string or plain URL |
| `url` | open a deep link such as `https://www.netflix.com/title/80057281?source=30` |
| `package` | open an app's TV launcher activity |

```
curl -X POST http://192.168.1.50:8765/api/launch -H 'Content-Type: application/json' -d '{"id":101}'
curl 'http://192.168.1.50:8765/api/launch?url=https://www.youtube.com/watch?v=dQw4w9WgXcQ'
```

Response `{"ok":true,"message":"launched","launched":"..."}` or `400` with an
`error`. The message carries a warning when 'Display over other apps' is not
granted, because Android then silently drops background launches.

## POST /api/wake

Best-effort display wake: acquires a short wake lock and shows a transparent
activity that asks for the screen to turn on. Pair it with Wake-on-LAN from the
Control4 side for a Shield in deep standby.
