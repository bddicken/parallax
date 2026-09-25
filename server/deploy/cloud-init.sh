#!/bin/bash
# Installs parallax-server on a fresh Ubuntu 24.04 droplet.
#
# Parallax (client/Sources/ParallaxRemote/ServerDeploy.swift) fills in the
# placeholder values below and sends the result as the droplet's user_data, which
# cloud-init runs once, as root, on first boot. Its output goes to
# /var/log/cloud-init-output.log.
#
#   Caddy (caddy.service)              https://<ip>.sslip.io → 127.0.0.1:8080
#   parallax-server (parallax.service) control API on 127.0.0.1:8080
#     └─ MediaMTX (its child process)  SRT ingest on :8890/udp
#
# The droplet's firewall (created by the app) opens 80/tcp and 443/tcp for
# Caddy and 8890/udp for SRT.
set -euo pipefail

# Filled in by Parallax. The app only substitutes values made of characters
# that are safe inside single quotes and in a systemd environment file.
PARALLAX_REPO='__PARALLAX_REPO__'
PARALLAX_VERSION='__PARALLAX_VERSION__'
# A reserved IP, or empty to use the droplet's own address.
PUBLIC_IP='__PUBLIC_IP__'
PARALLAX_TOKEN='__PARALLAX_TOKEN__'
PARALLAX_INGEST_KEY='__PARALLAX_INGEST_KEY__'
PARALLAX_SRT_PASSPHRASE='__PARALLAX_SRT_PASSPHRASE__'
TWITCH_CLIENT_ID='__TWITCH_CLIENT_ID__'
TWITCH_CLIENT_SECRET='__TWITCH_CLIENT_SECRET__'
YOUTUBE_CLIENT_ID='__YOUTUBE_CLIENT_ID__'
YOUTUBE_CLIENT_SECRET='__YOUTUBE_CLIENT_SECRET__'
X_RTMP_URL='__X_RTMP_URL__'
X_STREAM_KEY='__X_STREAM_KEY__'
X_USERNAME='__X_USERNAME__'

# Must know every setting in the config that ingest.rs writes (e.g. `moq`).
MEDIAMTX_VERSION=1.21.1

if [[ "$PARALLAX_VERSION" == __* ]]; then
  echo "Fill in this script's placeholders first (Parallax does this when it deploys)." >&2
  exit 1
fi

# Retries flaky steps: the network can take a moment on first boot, and
# Ubuntu's own apt timers may hold the package lock.
retry() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    "$@" && return
    echo "Attempt $attempt failed: $*" >&2
    sleep 15
  done
  return 1
}

arch="$(dpkg --print-architecture)"
case "$arch" in
  amd64 | arm64) ;;
  *) echo "There are no parallax-server builds for $arch." >&2; exit 1 ;;
esac

if [[ -z "$PUBLIC_IP" ]]; then
  PUBLIC_IP="$(retry curl -fsS http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)"
fi
if [[ ! "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Expected a public IPv4 address, got \"$PUBLIC_IP\"." >&2
  exit 1
fi
# sslip.io resolves this name to the IP, so Caddy can get a certificate for it.
HOST="${PUBLIC_IP//./-}.sslip.io"

echo "Installing packages"
export DEBIAN_FRONTEND=noninteractive
retry apt-get -o DPkg::Lock::Timeout=300 update
retry apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends ca-certificates ffmpeg caddy

echo "Installing parallax-server $PARALLAX_VERSION and MediaMTX $MEDIAMTX_VERSION"
id parallax >/dev/null 2>&1 || useradd --system --home-dir /var/lib/parallax --shell /usr/sbin/nologin parallax
install -d -m 750 -o parallax -g parallax /var/lib/parallax
# Owned by the service, so its self-update can replace the binary.
install -d -m 755 -o parallax -g parallax /opt/parallax/bin

work="$(mktemp -d)"
cd "$work"
# Downloads keep their release names, which the checksum files list.
release="https://github.com/$PARALLAX_REPO/releases/download/server-v$PARALLAX_VERSION"
retry curl -fsSLO "$release/parallax-server-linux-$arch"
retry curl -fsSLO "$release/SHA256SUMS"
sha256sum --check --ignore-missing SHA256SUMS
install -m 755 -o parallax -g parallax "parallax-server-linux-$arch" /opt/parallax/bin/parallax-server

mediamtx="mediamtx_v${MEDIAMTX_VERSION}_linux_$arch.tar.gz"
release="https://github.com/bluenviron/mediamtx/releases/download/v$MEDIAMTX_VERSION"
retry curl -fsSLO "$release/$mediamtx"
retry curl -fsSLO "$release/checksums.sha256"
sha256sum --check --ignore-missing checksums.sha256
tar -xzf "$mediamtx" mediamtx
install -m 755 -o parallax -g parallax mediamtx /opt/parallax/bin/mediamtx
cd /
rm -rf "$work"

# Settings: see server/README.md › Configuration. Readable by the service only.
install -d -m 750 -o root -g parallax /etc/parallax
install -m 640 -o root -g parallax /dev/stdin /etc/parallax/parallax.env <<ENV
PARALLAX_ADDR=127.0.0.1:8080
PARALLAX_DATA_DIR=/var/lib/parallax
PARALLAX_PUBLIC_HOST=$PUBLIC_IP
PARALLAX_MEDIAMTX=/opt/parallax/bin/mediamtx
PARALLAX_RELEASE_REPO=$PARALLAX_REPO
PARALLAX_TOKEN=$PARALLAX_TOKEN
PARALLAX_INGEST_KEY=$PARALLAX_INGEST_KEY
PARALLAX_SRT_PASSPHRASE=$PARALLAX_SRT_PASSPHRASE
TWITCH_CLIENT_ID=$TWITCH_CLIENT_ID
TWITCH_CLIENT_SECRET=$TWITCH_CLIENT_SECRET
YOUTUBE_CLIENT_ID=$YOUTUBE_CLIENT_ID
YOUTUBE_CLIENT_SECRET=$YOUTUBE_CLIENT_SECRET
X_RTMP_URL=$X_RTMP_URL
X_STREAM_KEY=$X_STREAM_KEY
X_USERNAME=$X_USERNAME
ENV

install -m 644 /dev/stdin /etc/systemd/system/parallax.service <<'UNIT'
[Unit]
Description=parallax-server (Parallax relay)
Wants=network-online.target
After=network-online.target

[Service]
User=parallax
Group=parallax
EnvironmentFile=/etc/parallax/parallax.env
WorkingDirectory=/var/lib/parallax
ExecStart=/opt/parallax/bin/parallax-server
# Also brings it back after a self-update, which exits on purpose.
Restart=always
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/parallax /opt/parallax/bin

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now parallax.service

# HTTPS in front of the control API. Caddy gets and renews the certificate.
install -m 644 /dev/stdin /etc/caddy/Caddyfile <<CADDY
$HOST {
	reverse_proxy 127.0.0.1:8080
}
CADDY
systemctl enable caddy.service
systemctl restart caddy.service

echo "parallax-server $PARALLAX_VERSION is starting at https://$HOST"
