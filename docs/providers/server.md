# Server

Tracks one of your own servers' monthly traffic against its plan's allowance: **Traffic** (% of the
month's quota used, or left, per the meter style) and **Data Used** (GB of the quota).

## How it works

The server counts its own traffic; the app never logs in to it.

1. On the server (Debian/Ubuntu, as root): `script/server-probe/install.sh [interface]`. It installs
   vnStat, keeps 62 days of daily rows, and every five minutes exports them to
   `/var/lib/openusage-probe/traffic.json`. It also creates a random token in
   `/etc/openusage-probe/token`.
2. Publish that file behind the token, either:
   - from an existing nginx: add `script/server-probe/nginx-location.conf` to an `ssl` server block,
     with `TOKEN` replaced; or
   - on its own port: `script/server-probe/serve-https.sh <port> <letsencrypt-cert-name>` runs a small
     Python HTTPS server with that certificate (certbot's deploy hook restarts it on renewal).
3. In the app: Customize → Server. Enter the probe URL, the token, the plan's monthly quota and the day
   it resets. These are saved to `~/.config/openusage/server.json`.

Each server is its own card, named after the server. Add more with **Add Another Server**; the new card
appears after quitting and reopening OpenUsage. The first server is card `server`, later ones
`server@<hash>`.

## Counting

- **Counts** picks what the plan bills: Outbound (sent), Inbound, In + Out, or Larger (the bigger of
  the two period totals). Match the host panel; Hostycare, for one, bills outbound only.
- **Used before probe** adds what the panel had already counted this period when the probe was
  installed. It applies only to the period it was entered in.
- The period runs from the reset day 00:00 to the next one, on the server's clock (the export carries
  its UTC offset). A reset day past a month's end (e.g. 31 in February) falls on the last day.
- 1 GB = 1024³ bytes, as vnStat and most VPS panels count.
- vnStat only counts from its install; without **Used before probe** the first period undercounts.

## Endpoint

`GET <probe URL>` with `Authorization: Bearer <token>`, returning:

```json
{
  "schema": "openusage.server-traffic/1",
  "interface": "eth0",
  "updatedAt": "2026-11-04T08:30:00Z",
  "utcOffsetSeconds": 32400,
  "days": [{ "date": "2026-11-04", "rx": 1073741824, "tx": 536870912 }]
}
```

## Errors

- **No server set up**: no `~/.config/openusage/server.json` yet.
- **Probe token rejected**: HTTP 401/403; recopy `/etc/openusage-probe/token`.
- **Probe data is N min old** (warning): the export is over 30 minutes old; check
  `systemctl status openusage-probe.timer vnstat` on the server.
