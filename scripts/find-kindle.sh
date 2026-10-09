#!/usr/bin/env bash
# Find the Kindle on the local network and print its IPv4 address.
#
# Bootstrap problem this solves: the Start SSH scriptlet reports its IP in
# /mnt/us/ssh.log, but reading that back needs MTP — and the Kindle will not
# let you operate the UI (i.e. tap the Start SSH book) while it is mounted as
# a USB media device. So during bootstrap there is no way to read the log and
# no way to tap the book at the same time.
#
# Answer instead: sweep the LAN for it. Once SSH is up none of this is needed
# again — scp/ssh replace MTP entirely.
#
# Discovery is by open port, not by MAC: 22 is our dropbear, 2222 is KOReader's
# own SSH server. That needs no per-device configuration and works whatever
# address scheme or randomisation the device is using. Kindles randomise their
# MAC per SSID anyway, so a hardcoded one would go stale the moment you roam.
#
# Usage:
#   scripts/find-kindle.sh
#   SCRIBE_IP_SUBNET=192.168.1.0/24 scripts/find-kindle.sh   # sweep another range
#   SCRIBE_KINDLE_MAC=aa:bb:cc:dd:ee:ff scripts/find-kindle.sh  # also match MAC
#   SCRIBE_SSH_PORT=2222 scripts/find-kindle.sh               # scan one port only

set -uo pipefail

MAC="${SCRIBE_KINDLE_MAC:-}"
PORTS="${SCRIBE_SSH_PORT:-22 2222}"

iface=$(ip -o route get 1.1.1.1 2>/dev/null | grep -oE 'dev [^ ]+' | cut -d' ' -f2 | head -1)
[ -n "$iface" ] || { echo "no default route — is this host on the network?" >&2; exit 1; }

SUBNET="${SCRIBE_IP_SUBNET:-$(ip -o -4 addr show dev "$iface" scope global \
    | head -1 | grep -oE 'inet [0-9.]+/[0-9]+' | cut -d' ' -f2)}"
[ -n "$SUBNET" ] || { echo "could not determine subnet for $iface" >&2; exit 1; }

if [ -n "$MAC" ]; then
    echo "scanning $SUBNET on $iface for MAC $MAC ..." >&2
else
    echo "scanning $SUBNET on $iface for ports $PORTS ..." >&2
fi

# Populate the neighbour table first. This finds hosts even when they do not
# answer ICMP, which a sleeping Kindle generally does not.
for i in $(seq 1 254); do
    ping -c1 -W1 -i0 "${SUBNET%.*}.$i" >/dev/null 2>&1 &
done
wait 2>/dev/null

candidates=$(ip neigh | grep -vE 'INCOMPLETE|FAILED' | awk '{print $1}')

if [ -n "$MAC" ]; then
    candidates=$(ip neigh | grep -vE 'INCOMPLETE|FAILED' | grep -i "$MAC" | awk '{print $1}')
    [ -n "$candidates" ] || {
        echo "no host with MAC $MAC on $SUBNET" >&2
        echo "the Kindle is most likely asleep, or on a different SSID/subnet" >&2
        exit 1
    }
fi

found=0
for ip in $candidates; do
    open=""
    for p in $PORTS; do
        if timeout 2 bash -c "echo >/dev/tcp/$ip/$p" 2>/dev/null; then
            open="$open $p"
            found=1
        fi
    done
    [ -n "$open" ] || continue
    mac=$(ip neigh show "$ip" | grep -oE 'lladdr [0-9a-f:]+' | cut -d' ' -f2)
    printf '%s  %-17s  ssh:%s\n' "$ip" "${mac:-?}" "${open# }"
done

if [ "$found" = 0 ]; then
    cat >&2 <<'EOF'
no Kindle found (nothing answering on: PORTS).

In order of likelihood:
  1. It is asleep. Press a button — that is the normal state for this device.
  2. It is on a different SSID or subnet. Set SCRIBE_IP_SUBNET.
  3. SSH is not running. Tap "Start SSH" in the Kindle's library, or enable
     KOReader > Cog > Network > SSH server (port 2222).
EOF
    exit 1
fi

echo >&2
echo "add a Host block for it to ~/.ssh/config, then: ssh root@<ip>" >&2
