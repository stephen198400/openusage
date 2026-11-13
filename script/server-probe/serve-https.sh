#!/usr/bin/env bash
# Publishes the probe export on its own HTTPS port, for servers with no web server to put
# nginx-location.conf in. Run as root after install.sh.
#
# A small Python server answers GET /openusage/traffic.json for requests carrying the probe token and
# 404s everything else. It reuses an existing Let's Encrypt certificate for a name that resolves to this
# server; certbot's deploy hook restarts it so a renewed certificate is picked up.
#
# Usage: serve-https.sh <port> <letsencrypt-cert-name>
set -euo pipefail

PORT="${1:?port}"
CERT_NAME="${2:?letsencrypt certificate name}"
CERT_DIR="/etc/letsencrypt/live/$CERT_NAME"
[ -s "$CERT_DIR/fullchain.pem" ] || { echo "no certificate at $CERT_DIR" >&2; exit 1; }
[ -s /etc/openusage-probe/token ] || { echo "run install.sh first" >&2; exit 1; }

install -d -m 0755 /usr/local/lib/openusage-probe
cat >/usr/local/lib/openusage-probe/serve.py <<'PY'
import hmac, http.server, ssl, sys

port, cert_dir = int(sys.argv[1]), sys.argv[2]
token = open("/etc/openusage-probe/token").read().strip()
expected = ("Bearer " + token).encode()
export = "/var/lib/openusage-probe/traffic.json"

class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "openusage-probe"
    sys_version = ""
    # A client that stalls mid-handshake or mid-request is dropped instead of holding its thread.
    timeout = 15

    def do_GET(self):
        if self.path != "/openusage/traffic.json":
            return self.reply(404, b"")
        given = self.headers.get("Authorization", "").encode()
        if not hmac.compare_digest(given, expected):
            return self.reply(401, b"")
        try:
            body = open(export, "rb").read()
        except OSError:
            return self.reply(503, b"")
        self.reply(200, body, "application/json")

    def reply(self, status, body, content_type="text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = ssl.TLSVersion.TLSv1_2
context.load_cert_chain(f"{cert_dir}/fullchain.pem", f"{cert_dir}/privkey.pem")
class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    # Wrapping the listening socket would run every TLS handshake inside accept() on the main
    # thread, with no timeout: one client that never finishes its handshake stalls the server for
    # everyone. Accept plain sockets and let each connection's own thread do its handshake.
    def get_request(self):
        sock, addr = self.socket.accept()
        sock.settimeout(Handler.timeout)
        return context.wrap_socket(sock, server_side=True, do_handshake_on_connect=False), addr

server = Server(("0.0.0.0", port), Handler)
server.serve_forever()
PY

cat >/etc/systemd/system/openusage-probe-https.service <<UNIT
[Unit]
Description=MyUsage traffic probe over HTTPS
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/lib/openusage-probe/serve.py $PORT $CERT_DIR
Restart=on-failure
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT

install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/openusage-probe-https.sh <<'HOOK'
#!/bin/sh
systemctl try-restart openusage-probe-https.service
HOOK
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/openusage-probe-https.sh

systemctl daemon-reload
systemctl enable --now openusage-probe-https.service >/dev/null
systemctl restart openusage-probe-https.service
sleep 1
systemctl is-active openusage-probe-https.service
echo "url: https://$CERT_NAME:$PORT/openusage/traffic.json"
