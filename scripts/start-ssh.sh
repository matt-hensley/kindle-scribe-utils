#!/bin/sh
# Name: Start SSH
# Author: scribe
# DontUseFBInk

# Start a root SSH server on wlan0:22 using KOReader's dropbear.
#
# Why not USBNetLite: this firmware (5.19.6, Véra) has no /mnt/us/mrpackages
# and no /mnt/us/extensions, so MRPI/KUAL cannot install anything, and the
# documented fallback — a .bin at the storage root plus a forced OTA — triggers
# OTA on a device that has no KUAL to run the installer. See docs/SSH.md.
#
# KOReader already ships a dropbear server binary and a host key. It is a
# server-only build (not dropbearmulti) and is patched by KOReader with:
#   -n   allow blank-password login
#   authorized_keys read from settings/SSH/authorized_keys relative to cwd
# Both matter: root's password in /etc/shadow is "!", i.e. locked, so without
# -n no password at all gets in.
#
# Runs as root (scriptlet), over Wi-Fi only. Never touches Toggle USBNet —
# that traps the UI on a gadget page you can only leave by powering off.
#
# Everything is logged to /mnt/us/ssh.log so it can be read back over MTP
# without needing the SSH connection this script is trying to establish.

set -u

LOG=/mnt/us/ssh.log
KOR=/mnt/us/koreader
BIN=$KOR/dropbear
HOSTKEY=$KOR/settings/SSH/dropbear_ed25519_host_key
PIDFILE=/var/tmp/dropbear-scribe.pid
PORT=22

# Password auth is deliberately enabled. Swap -n for -s (key-only) and drop a
# pubkey in $KOR/settings/SSH/authorized_keys to lock it down; see docs/SSH.md.
AUTH=-n

exec 3>&1
exec >"$LOG" 2>&1
echo "=== start-ssh $(date 2>/dev/null || echo no-date) ==="

# --- power state ---------------------------------------------------------
#
# Deliberately NOT touching preventScreenSaver. An earlier version set it here
# and in the boot watchdog, which pinned the device awake so it never slept
# again — the opposite of what you want if the Kindle is meant to conserve power
# and be woken by hand. Leave the power state alone.

echo "--- power ---"
uptime 2>&1
cat /proc/uptime 2>&1

# --- recon ---------------------------------------------------------------

echo "--- tools ---"
for c in dropbear iptables ifconfig ip netstat devpts mount killall wpa_cli lipc-get-prop; do
    printf '  %-16s %s\n' "$c" "$(command -v "$c" 2>/dev/null || echo '-')"
done

echo "--- binaries ---"
ls -la "$BIN" 2>&1
ls -la "$HOSTKEY" 2>&1

# --- network -------------------------------------------------------------

wlan_ip() {
    ifconfig wlan0 2>/dev/null \
        | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p;s/.*inet \([0-9.]*\).*/\1/p' | head -1
}

echo "--- wifi state (before) ---"
echo "  cmState: $(lipc-get-prop com.lab126.wifid cmState 2>&1)"
ifconfig wlan0 2>&1 | sed 's/^/  /'
IP=$(wlan_ip)
echo "WLAN_IP=${IP:-none}"

# Bring the radio back if it has dropped. The Kindle will happily sit in
# PENDING/NA after a USB (re)connection and never recover on its own.
if [ -z "$IP" ]; then
    echo "--- no IPv4 on wlan0, cycling the radio ---"
    lipc-set-prop com.lab126.cmd wirelessEnable 0 2>&1 | sed 's/^/  off: /'
    sleep 3
    lipc-set-prop com.lab126.cmd wirelessEnable 1 2>&1 | sed 's/^/  on:  /'
    sleep 5
    wpa_cli -i wlan0 reconnect 2>&1 | sed 's/^/  wpa: /'

    # Association is not instant; poll rather than guess a fixed sleep.
    n=0
    while [ "$n" -lt 20 ]; do
        n=$((n + 1))
        IP=$(wlan_ip)
        [ -n "$IP" ] && break
        echo "  waiting for wlan0 ... cmState=$(lipc-get-prop com.lab126.wifid cmState 2>&1)"
        sleep 2
    done
    echo "WLAN_IP=${IP:-none}"
fi

echo "--- wifi state (after) ---"
echo "  cmState: $(lipc-get-prop com.lab126.wifid cmState 2>&1)"
ifconfig wlan0 2>&1 | sed 's/^/  /'
echo "--- route ---"
ip route 2>&1 | sed 's/^/  /'

echo "--- firewall (INPUT policy) ---"
iptables -S INPUT 2>&1 | head -20

echo "--- pty support ---"
ls -la /dev/ptmx 2>&1 | head -3
mount | grep -w devpts 2>&1 | sed 's/^/  /' || echo "  devpts NOT mounted"

# --- preflight -----------------------------------------------------------

rc=0

if [ ! -f "$BIN" ]; then
    echo "FAIL: $BIN missing — is KOReader installed?"
    rc=1
fi

if [ -z "$IP" ]; then
    echo "FAIL: still no IPv4 on wlan0."
    echo "      Check Settings > Device Options > Wi-Fi on the device."
    rc=1
fi

# --- stop any previous instance of OURS only ------------------------------
#
# Deliberately NOT `killall dropbear`: that would also kill KOReader's own
# dropbear on 2222, which is the recovery path when this script misfires.

if [ -f "$PIDFILE" ]; then
    oldpid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        echo "stopping previous scribe dropbear pid=$oldpid"
        kill "$oldpid" 2>/dev/null
        sleep 1
    fi
fi

# Is 22 already taken? If so, assume we are up and report rather than fail.
if netstat -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "port $PORT already listening before launch:"
    netstat -ltn 2>/dev/null | grep ":$PORT " | sed 's/^/  /'
fi

[ "$rc" -eq 0 ] || { echo "=== preflight failed, not starting ==="; exit "$rc"; }

# --- firewall ------------------------------------------------------------
#
# The Kindle's INPUT chain defaults to DROP and only 2222 is opened, so the
# port has to be punched by hand. Guarded so repeated taps do not stack rules.
# Restricted to wlan0 so a USB-network session is not exposed by accident.

open_port() {
    iptables -C INPUT -i wlan0 -p tcp --dport "$PORT" \
        -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null && {
        echo "  rule already present: $PORT"
        return 0
    }
    iptables -I INPUT -i wlan0 -p tcp --dport "$PORT" \
        -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT \
        && echo "  opened INPUT $PORT on wlan0" \
        || { echo "  WARN: could not open INPUT $PORT"; return 1; }
}
open_port || rc=1

# An SSH server must hand out ptys. Kindles normally mount devpts already;
# mount it if not, because without it every interactive session dies at once.
if ! mount | grep -q devpts; then
    mkdir -p /dev/pts 2>/dev/null
    mount -t devpts devpts /dev/pts 2>&1 | sed 's/^/  /' \
        || { echo "  WARN: could not mount devpts"; rc=1; }
else
    echo "  devpts already mounted"
fi

# root's home. /tmp is tmpfs and is wiped every boot; /mnt/us is FUSE and is
# shared with the host over MTP, so neither is a good place for state that has
# to survive. This only needs to exist for the life of the process.
export HOME=/tmp/root
mkdir -p "$HOME" 2>/dev/null

[ "$rc" -eq 0 ] || { echo "=== preflight failed, not starting ==="; exit "$rc"; }

# --- start ---------------------------------------------------------------
#
# cwd matters: this dropbear is patched to resolve authorized_keys relative to
# the working directory. -E logs to stderr, which is captured here; once it
# daemonises the log stops growing, which is fine — we only need the start.

cd "$KOR" || { echo "FAIL: cannot cd $KOR"; exit 1; }

HK=""
if [ -f "$HOSTKEY" ]; then
    HK="-r $HOSTKEY"
    echo "using existing host key $HOSTKEY"
else
    # -R generates a key into settings/SSH/ relative to cwd.
    HK="-R"
    echo "no host key found — generating one"
fi

echo "--- launching ---"
echo "cmd: ./dropbear -E $HK -p $PORT -P $PIDFILE $AUTH"
# shellcheck disable=SC2086
./dropbear -E $HK -p "$PORT" -P "$PIDFILE" $AUTH
sleep 2

# Check the listener, not the process table. dropbear daemonizes and rewrites
# its argv[0], so `ps | grep dropbear` reports nothing even when it is serving.
# An earlier version of this script trusted `ps` and reported a false failure.
echo "--- result ---"
if netstat -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "  LISTENING on $PORT"
    netstat -ltn 2>&1 | grep ":$PORT " | sed 's/^/  /'
else
    echo "  port $PORT NOT listening"
    echo "  last dropbear output was:"
    tail -20 "$LOG" | sed 's/^/    /'
fi

echo
echo "SSH_IP=${IP:-none}"
echo "If the port is listening, from the host:  ssh root@${IP:-<ip>}"
echo "Blank password — just press Enter at the prompt."
echo
echo "NOTE: keep this USB cable plugged in. Unplugging drops the MTP mount,"
echo "and the device sleeps on its own, which takes wlan0 with it."
echo "=== done ==="
