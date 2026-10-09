#!/bin/sh
#
# homelab-panel-update
# ====================
#
# Updates the panel to a newer release (or an older one, if you want to go back), and restarts
# it. The installer puts this script in the panel's container as
# /usr/local/bin/homelab-panel-update. Run it as root inside the container, or from the Proxmox
# node that hosts it:
#
#   pct exec <ctid> -- homelab-panel-update            the newest release
#   pct exec <ctid> -- homelab-panel-update v0.2.0     a particular release
#
# What it does:
#
#   1. Downloads the panel, its service file, this script and the license notices from one
#      release, and checks each file against its published checksum. If any file doesn't
#      match, it stops without changing anything.
#   2. If everything is already the same as what is installed, it says so and stops.
#   3. Otherwise it puts the new files in place, keeping the current program as
#      homelab-panel.old, and restarts the panel.
#   4. It waits up to 20 seconds for the panel to answer. If it doesn't, it puts the previous
#      program back and restarts that, so a bad release can't leave you without a panel.
#
# Your settings, password, job history and SSH key are never touched.

# Stop at the first command that fails (-e), and treat a misspelled variable as an error (-u).
set -eu

REPO=jjackb14/homelab-panel-releases
ASSET=homelab-panel-x86_64-unknown-linux-gnu
# Where the panel's files are. (The project's tests point these at a scratch folder.)
DIR=${DIR:-/opt/homelab-panel}
UNIT_DIR=${UNIT_DIR:-/etc/systemd/system}
HELPER=${HELPER:-/usr/local/bin/homelab-panel-update}
ENV_FILE=${ENV_FILE:-/etc/homelab-panel/.env}
BIN=$DIR/homelab-panel
UNIT=$UNIT_DIR/homelab-panel.service
PORT=$(sed -n 's/^PANEL_PORT=//p' "$ENV_FILE" 2>/dev/null || true)
PORT=${PORT:-8420}

if [ "$(id -u)" != 0 ]; then
  echo "run as root" >&2
  exit 1
fi

# Which release to download: the one named on the command line, or else the newest.
if [ $# -gt 0 ]; then
  BASE="https://github.com/$REPO/releases/download/$1"
else
  BASE="https://github.com/$REPO/releases/latest/download"
fi

# Downloads go into a temporary folder next to the program. Swapping the new program in is then a
# simple rename on the same disk, which happens all at once: the panel is never left with a
# half-written program file.
TMP=$(mktemp -d "$DIR/.update.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

echo "==> downloading from $BASE"
# Every file is downloaded and checked before anything is changed.
for f in "$ASSET" homelab-panel.service update.sh THIRD-PARTY-NOTICES; do
  curl -fsSL --proto '=https' -o "$TMP/$f" "$BASE/$f"
  curl -fsSL --proto '=https' -o "$TMP/$f.sha256" "$BASE/$f.sha256"
  if ! (cd "$TMP" && sha256sum -c --quiet "$f.sha256" >/dev/null 2>&1); then
    echo "$f does not match its checksum; nothing was changed" >&2
    exit 1
  fi
done

# Whether two files are identical (and the second one exists).
same() { [ -f "$2" ] && cmp -s "$1" "$2"; }
if same "$TMP/$ASSET" "$BIN" && same "$TMP/homelab-panel.service" "$UNIT" \
  && same "$TMP/update.sh" "$HELPER" && same "$TMP/THIRD-PARTY-NOTICES" "$DIR/THIRD-PARTY-NOTICES"; then
  echo "already up to date"
  exit 0
fi

# First the files that don't affect the running panel: this script and the license notices.
# Then the service file, if it changed; systemd has to re-read it ("daemon-reload").
install -m 0755 "$TMP/update.sh" "$HELPER"
install -m 0644 "$TMP/THIRD-PARTY-NOTICES" "$DIR/THIRD-PARTY-NOTICES"
if ! same "$TMP/homelab-panel.service" "$UNIT"; then
  install -m 0644 "$TMP/homelab-panel.service" "$UNIT"
  systemctl daemon-reload
fi

chmod 0755 "$TMP/$ASSET"
# Keep the current program as homelab-panel.old, so it can be put back without a download.
[ ! -f "$BIN" ] || cp -p "$BIN" "$BIN.old"
mv "$TMP/$ASSET" "$BIN"

echo "==> restarting"
# Even if the restart itself reports an error, the health check below decides what happens
# next, so a failed start is rolled back like any other.
systemctl restart homelab-panel || true

# The new version counts as working once it answers on /api/health, within 20 seconds, without
# the service stopping. A version that doesn't like your current settings stops straight away,
# so this catches that too. Going back restores the previous program only; the service file and
# this script from a newer release work with the program from the release before it.
i=0
until curl -fsS -o /dev/null "http://127.0.0.1:$PORT/api/health"; do
  i=$((i + 1))
  if [ "$i" -ge 20 ] || ! systemctl is-active --quiet homelab-panel; then
    echo "the new binary did not come up; rolling back" >&2
    journalctl -u homelab-panel -n 20 --no-pager >&2 || true
    if [ -f "$BIN.old" ]; then
      mv "$BIN.old" "$BIN"
      systemctl restart homelab-panel || true
    fi
    exit 1
  fi
  sleep 1
done
echo "==> updated; the previous binary is $BIN.old"
