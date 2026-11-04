#!/usr/bin/env bash
# Installs the OpenUsage server traffic probe on a Debian/Ubuntu server (run as root).
#
# vnStat counts the interface's traffic per day; a systemd timer exports the last 62 days every five
# minutes to /var/lib/openusage-probe/traffic.json in the schema the app's Server provider reads. The
# file is published by your existing TLS web server behind a bearer token: see nginx-location.conf.
#
# Usage: install.sh [interface]   (defaults to the interface of the default route)
set -euo pipefail

IFACE="${1:-$(ip -o route show default | awk '{print $5; exit}')}"
STATE_DIR=/var/lib/openusage-probe
TOKEN_FILE=/etc/openusage-probe/token

apt-get install -y vnstat jq >/dev/null

# vnStat keeps only 30 days of daily rows by default; a monthly period needs up to 31 plus slack.
sed -i -E 's/^;?DailyDays .*/DailyDays 62/' /etc/vnstat.conf
systemctl enable --now vnstat >/dev/null
systemctl restart vnstat
vnstat --add -i "$IFACE" >/dev/null 2>&1 || true

install -d -m 0755 "$STATE_DIR"
install -d -m 0700 /etc/openusage-probe
if [ ! -s "$TOKEN_FILE" ]; then
  head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$TOKEN_FILE"
  chmod 0600 "$TOKEN_FILE"
fi

cat >/usr/local/bin/openusage-probe-export <<EXPORT
#!/usr/bin/env bash
set -euo pipefail
z="\$(date +%z)"
offset=\$(( 10#\${z:1:2} * 3600 + 10#\${z:3:2} * 60 ))
[ "\${z:0:1}" = "-" ] && offset=\$(( -offset ))
tmp="\$(mktemp $STATE_DIR/.traffic.XXXXXX)"
vnstat --json d -i "$IFACE" | jq --arg updated "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson offset "\$offset" '
  .interfaces[0] as \$i | {
    schema: "openusage.server-traffic/1",
    interface: \$i.name,
    updatedAt: \$updated,
    utcOffsetSeconds: \$offset,
    days: [\$i.traffic.day[] | {
      date: "\(.date.year)-\(.date.month | tostring | if length < 2 then "0" + . else . end)-\(.date.day | tostring | if length < 2 then "0" + . else . end)",
      rx: .rx, tx: .tx
    }]
  }' >"\$tmp"
chmod 0644 "\$tmp"
mv "\$tmp" "$STATE_DIR/traffic.json"
EXPORT
chmod 0755 /usr/local/bin/openusage-probe-export

cat >/etc/systemd/system/openusage-probe.service <<'UNIT'
[Unit]
Description=Export vnStat traffic for OpenUsage
After=vnstat.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/openusage-probe-export
UNIT

cat >/etc/systemd/system/openusage-probe.timer <<'UNIT'
[Unit]
Description=Export vnStat traffic for OpenUsage every five minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now openusage-probe.timer >/dev/null
sleep 2
/usr/local/bin/openusage-probe-export

echo "interface: $IFACE"
echo "export:    $STATE_DIR/traffic.json"
echo "token:     $TOKEN_FILE (copy it into OpenUsage; never paste it in chat)"
