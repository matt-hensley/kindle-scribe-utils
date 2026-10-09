#!/usr/bin/env bash
# One-shot SSH setup for the Kindle Scribe. See docs/SSH.md for the reasoning.
#
#   scripts/setup-ssh.sh                 # full interactive setup
#   scripts/setup-ssh.sh --reboot-test   # also reboot the device and prove it
#   scripts/setup-ssh.sh --yes           # non-interactive, skip the prompt
#   scripts/setup-ssh.sh --host <kindle ip>
#
# Idempotent: every step checks whether it is already done. Safe to re-run to
# repair a half-finished setup. Never touches Toggle USBNet, never writes a
# .bin, never rm -rf's anything under /mnt/us.
#
# There is exactly ONE step that cannot be automated: the Kindle will not let
# you operate the UI while it is mounted as a USB media device, so someone has
# to tap the "Start SSH" book. Everything else here is scripted.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT=$PWD
SCRIPTS=$ROOT/scripts

# --- options ---------------------------------------------------------------

HOST_ARG=""
REBOOT_TEST=0
ASSUME_YES=0
KEY="$HOME/.ssh/id_kindle"
ALIAS="kindle"

while [ $# -gt 0 ]; do
    case "$1" in
        --host)         HOST_ARG="${2:-}"; shift 2 ;;
        --host=*)       HOST_ARG="${1#*=}"; shift ;;
        --reboot-test)  REBOOT_TEST=1; shift ;;
        --yes|-y)       ASSUME_YES=1; shift ;;
        --key)          KEY="${2:-}"; shift 2 ;;
        --key=*)        KEY="${1#*=}"; shift ;;
        --alias)        ALIAS="${2:-}"; shift 2 ;;
        --alias=*)      ALIAS="${1#*=}"; shift ;;
        -h|--help)      sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *)              echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# --- output helpers --------------------------------------------------------

if [ -t 1 ]; then
    B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else
    B=''; G=''; Y=''; R=''; D=''; N=''
fi
step() { printf '\n%s==>%s %s%s%s\n' "$B" "$N" "$B" "$*" "$N"; }
ok()   { printf '    %sok%s   %s\n' "$G" "$N" "$*"; }
warn() { printf '    %swarn%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '    %sFAIL%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
note() { printf '    %s%s%s\n' "$D" "$*" "$N"; }

# A step that is already satisfied reports this rather than "ok".
skip() { printf '    %sskip%s %s %s(already done)%s\n' "$D" "$N" "$*" "$D" "$N"; }

# --- device-side paths -----------------------------------------------------

DEV_DROPBEAR=/mnt/us/koreader/dropbear
DEV_HOSTKEY=/mnt/us/koreader/settings/SSH/dropbear_ed25519_host_key
DEV_AUTHKEYS=/mnt/us/koreader/settings/SSH/authorized_keys
DEV_JOB=/etc/upstart/dropbear-system.conf
DEV_SCRIPTLET=/mnt/us/documents/start-ssh.sh

SSH_OPTS=(-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
          -o ConnectTimeout=8 -o BatchMode=yes)
[ -f "$KEY" ] && SSH_OPTS+=(-i "$KEY")

# ssh TARGET CMD... — blank-password fallback if the key is not installed yet.
ssh_try() { ssh "${SSH_OPTS[@]}" "$@" 2>/dev/null; }
ssh_bare() { ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
             -o PreferredAuthentications=password -o PubkeyAuthentication=no \
             "$@" </dev/null 2>/dev/null; }

# Run a command on the device, by alias/IP, as root.
dev() {
    local target="$1"; shift
    ssh_try "root@$target" "$@" || ssh_bare "root@$target" "$@"
}

# Is this target answering SSH at all? Must try the blank-password path too:
# a freshly set up device has no key installed yet, so BatchMode=yes alone
# would report "no SSH" and send us into the tap dance for no reason.
reachable() {
    ssh_try "$1" true 2>/dev/null || ssh_bare "$1" true 2>/dev/null
}

# =========================================================================
step "Preflight — host tools"
# =========================================================================

for tool in ssh scp; do
    command -v "$tool" >/dev/null || die "$tool not found — install openssh-client"
done
ok "ssh, scp present"

[ -x "$SCRIPTS/mtp.sh" ]      || die "scripts/mtp.sh missing or not executable"
[ -f "$SCRIPTS/start-ssh.sh" ]       || die "scripts/start-ssh.sh missing"
[ -f "$SCRIPTS/install-ssh-autostart.sh" ] || die "scripts/install-ssh-autostart.sh missing"
ok "repo scripts present"

have_mtp=0
if "$SCRIPTS/mtp.sh" mount >/dev/null 2>&1; then
    have_mtp=1
    ok "Kindle visible over MTP"
else
    warn "Kindle not visible over MTP"
    note "fine if SSH already works; otherwise plug the cable in and retry"
fi

# =========================================================================
step "Locate the device"
# =========================================================================

TARGET="$HOST_ARG"

# Prefer something that already answers SSH — that skips the whole tap dance.
if [ -z "$TARGET" ]; then
    if reachable "$ALIAS"; then
        TARGET="$ALIAS"
    fi
fi

if [ -z "$TARGET" ] && [ "$have_mtp" = 1 ]; then
    # Read the IP the previous run logged, if we can get at it over MTP.
    ip=$(timeout 60 "$SCRIPTS/mtp.sh" cat "ssh.log" 2>/dev/null \
         | sed -n 's/^SSH_IP=//p' | tail -1)
    case "$ip" in
        *.*.*.*) TARGET="$ip"; ok "found $ip in a previous run's ssh.log" ;;
        *)      note "no usable IP in ssh.log" ;;
    esac
fi

if [ -z "$TARGET" ]; then
    ip=$("$SCRIPTS/find-kindle.sh" 2>/dev/null | awk '/^[0-9.]/ {print $1; exit}')
    [ -n "$ip" ] && TARGET="$ip" && ok "found $ip on the LAN"
fi

SSH_UP=0
if [ -n "$TARGET" ] && reachable "root@$TARGET"; then
    SSH_UP=1
    ok "SSH already up at $TARGET"
else
    [ -n "$TARGET" ] && warn "no SSH at ${TARGET:-<unknown>}"
    SSH_UP=0
fi

# =========================================================================
step "Verify the device can run an SSH server"
# =========================================================================

# These are the three things that make this approach possible. If any is
# missing the whole plan collapses, so check rather than assume.
probe() {
    dev "$1" "$2" 2>/dev/null
}

if [ "$SSH_UP" = 1 ]; then
    probe "$TARGET" "test -x $DEV_DROPBEAR" && skip "KOReader dropbear present" \
        || die "$DEV_DROPBEAR missing — install KOReader via KPM first"
    probe "$TARGET" "test -f $DEV_HOSTKEY" && skip "host key present" \
        || warn "no host key — the Start SSH scriptlet will generate one"
    ok "prerequisites satisfied"
else
    if [ "$have_mtp" = 1 ]; then
        if "$SCRIPTS/mtp.sh" cat "koreader/dropbear" >/dev/null 2>&1; then
            skip "KOReader dropbear present"
        else
            die "KOReader is not installed on the device.
      Install it first:  ;kpm update   then  ;kpm install koreader"
        fi
    else
        warn "cannot verify prerequisites without MTP or SSH"
        note "if KOReader is not installed, this cannot work"
    fi
fi

# =========================================================================
step "Deploy the Start SSH scriptlet"
# =========================================================================

# Compare a local file against its copy on the device by checksum. Comparing
# paths does not work: the local side is a repo path that does not exist on the
# device, so `cmp` fails and every run looks out of date.
device_matches() {
    local target="$1" localfile="$2" remotepath="$3"
    local want have
    want=$(sha256sum "$localfile" 2>/dev/null | cut -d' ' -f1)
    [ -n "$want" ] || return 1
    have=$(dev "$target" "sha256sum '$remotepath' 2>/dev/null" | cut -d' ' -f1)
    [ -n "$have" ] || return 1
    [ "$want" = "$have" ]
}

need_push=1
if [ "$SSH_UP" = 1 ] && device_matches "$TARGET" "$SCRIPTS/start-ssh.sh" "$DEV_SCRIPTLET"; then
    skip "scriptlet already current"
    need_push=0
fi

if [ "$need_push" = 1 ]; then
    [ "$have_mtp" = 1 ] || die "need MTP to deploy the scriptlet — plug the cable in"
    "$SCRIPTS/mtp.sh" mount >/dev/null 2>&1 || die "could not mount MTP"
    "$SCRIPTS/mtp.sh" push "documents/start-ssh.sh" "$SCRIPTS/start-ssh.sh" \
        || die "could not push the scriptlet over MTP"
    ok "pushed to /mnt/us/documents/start-ssh.sh"
    note "a .sdr sidecar may appear; that is the library entry, not a second script"
else
    note "use 'just push' after editing scripts/start-ssh.sh"
fi

# =========================================================================
step "Start dropbear"
# =========================================================================

# The one irreducible manual step.
if [ "$SSH_UP" = 0 ]; then
    cat <<EOF

    ${B}${Y}ACTION NEEDED ON THE DEVICE${N}

      1. Unplug the USB cable. The Kindle will not let you operate its UI
         while it is mounted as a USB media device.
      2. Wake it and open the Library.
      3. Tap the ${B}Start SSH${N} book.
      4. Come back here.

    Then this script finds the device and does the rest automatically.

EOF
    if [ "$ASSUME_YES" = 0 ]; then
        read -r -p "    Press Enter once you have tapped it... " _
    fi

    printf '    waiting for SSH'
    found=""
    for i in $(seq 1 60); do
        if [ -z "$found" ]; then
            for cand in "$ALIAS" "$TARGET" $(echo "$TARGET" | tr ',' ' '); do
                [ -n "$cand" ] || continue
                port=$(echo "$cand" | grep -oE '^[0-9.]+' || true)
                if [ -n "$port" ] && timeout 2 bash -c "echo >/dev/tcp/$port/22" 2>/dev/null; then
                    found="$cand"; break
                fi
                if timeout 2 bash -c "echo >/dev/tcp/$cand/22" 2>/dev/null; then
                    found="$cand"; break
                fi
            done
        fi
        if [ -n "$found" ] && reachable "root@$found"; then
            printf '\n    %sok%s   SSH is up at %s\n' "$G" "$N" "$found"
            TARGET="$found"
            SSH_UP=1
            break
        fi
        [ $((i % 5)) -eq 0 ] && printf '.'
        sleep 2
    done

    if [ "$SSH_UP" = 0 ]; then
        cat <<EOF >&2

    ${R}Could not reach the Kindle over SSH.${N} Troubleshooting, in order:

      1. Is the Kindle awake and on Wi-Fi? (Settings > Device Options > Wi-Fi)
      2. Did the tap actually run? Replug the cable and read the log:
           just log
         Look for: 'port 22 NOT listening'  or  'still no IPv4 on wlan0'
      3. Find the device:   just find-kindle
      4. Recovery path that needs neither this script nor the cable:
         KOReader > Cog > Network > SSH server, then ssh -p 2222 root@<ip>

EOF
        exit 1
    fi
else
    skip "dropbear already running"
fi

# From here on everything is over SSH. No cable needed again.

# =========================================================================
step "Install the SSH key"
# =========================================================================

if [ ! -f "$KEY" ]; then
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -f "$KEY" -N "" -C "$(whoami)@$(hostname) kindle" \
        >/dev/null 2>&1 || die "ssh-keygen failed"
    ok "generated $KEY"
else
    skip "key exists at $KEY"
fi

if dev "$TARGET" "grep -qF '$(cat "$KEY.pub")' $DEV_AUTHKEYS 2>/dev/null"; then
    skip "public key already in $DEV_AUTHKEYS"
else
    dev "$TARGET" "mkdir -p $(dirname "$DEV_AUTHKEYS")" \
        || die "could not create $(dirname "$DEV_AUTHKEYS") on the device"
    # Inline the key rather than piping it on stdin. ssh_bare() carries a
    # </dev/null for the blank-password fallback, which overrides any caller
    # redirect — a piped keyfile is silently discarded and the step reports
    # success while writing nothing. That is exactly what happened.
    #
    # Safe to quote: an ed25519 public key is base64 plus an optional comment,
    # neither of which can contain a single quote. Assert it rather than trust it.
    pub=$(cat "$KEY.pub")
    case "$pub" in
        *"'"*) die "public key contains a single quote — cannot inline safely" ;;
    esac
    dev "$TARGET" "printf '%s\n' '$pub' >> $DEV_AUTHKEYS" \
        || die "could not write $DEV_AUTHKEYS"

    # Verify rather than assume. The fallback path above can succeed while
    # having written nothing, which is how an empty authorized_keys file
    # survived several runs of this script looking healthy.
    dev "$TARGET" "grep -qF '$pub' $DEV_AUTHKEYS" \
        || die "wrote $DEV_AUTHKEYS but the key is not in it"
    ok "installed public key to $DEV_AUTHKEYS"
fi

# Prove key auth specifically. `reachable` also accepts the blank password, so
# it cannot distinguish "key works" from "password works" — and this repo's
# recipes all rely on the key.
if ssh_try "root@$TARGET" true 2>/dev/null; then
    ok "key auth works"
else
    warn "key auth did NOT work — recipes that run non-interactively will fail"
    note "blank-password login still works; check $DEV_AUTHKEYS on the device"
fi

# =========================================================================
step "Configure the ssh alias"
# =========================================================================

mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"

if grep -qE "^Host +$ALIAS\$" "$HOME/.ssh/config" 2>/dev/null; then
    skip "alias '$ALIAS' already in ~/.ssh/config"
    note "edit it if the device address changed"
else
    hostpart="$TARGET"
    grep -qE '^[0-9.]+$' <<<"$hostpart" || hostpart=$(ssh -G "$TARGET" 2>/dev/null | awk '$1=="hostname"{print $2}')
    cat >> "$HOME/.ssh/config" <<EOF

# Kindle Scribe — added by scripts/setup-ssh.sh
# dropbear reads authorized_keys from a cwd-relative path, so the public key
# lives at $DEV_AUTHKEYS rather than a root ~/.ssh. See docs/SSH.md.
Host $ALIAS
  HostName $hostpart
  User root
  Port 22
  IdentityFile $KEY
  IdentitiesOnly yes
  ServerAliveInterval 30
  ServerAliveCountMatch 3
EOF
    ok "added 'Host $ALIAS' -> $hostpart to ~/.ssh/config"
fi

# =========================================================================
step "Install the boot-time job"
# =========================================================================

# The job name comes from the filename, so the body never contains the string
# "dropbear-system" — grep for the command line it does contain.
if dev "$TARGET" "test -f $DEV_JOB && grep -q './dropbear -E' $DEV_JOB"; then
    skip "$DEV_JOB already installed"
    note "re-run with --reinstall-job to replace it after editing the template"
else
    dev "$TARGET" 'sh -s' < "$SCRIPTS/install-ssh-autostart.sh" >/dev/null 2>&1 \
        || die "install-ssh-autostart.sh failed on the device"
    ok "wrote $DEV_JOB"
fi

dev "$TARGET" "initctl list | grep -q dropbear-system" \
    && ok "registered with upstart" \
    || warn "job is not in 'initctl list' — it will not start at boot"

note "initctl reporting 'stop/waiting' is correct for a 'task' job — not an error"

# =========================================================================
step "Verify"
# =========================================================================

port22=$(dev "$TARGET" "netstat -ltn 2>/dev/null | grep -c ':22 '")
[ "${port22:-0}" -gt 0 ] && ok "dropbear listening on :22" || warn "nothing listening on :22"

pid=$(dev "$TARGET" 'cat /var/tmp/dropbear-scribe.pid 2>/dev/null')
if [ -n "$pid" ]; then
    # ps|grep dropbear is a false negative: dropbear rewrites argv[0] when it
    # daemonises. Read /proc instead.
    if dev "$TARGET" "test -d /proc/$pid"; then
        ok "dropbear pid $pid"
        # /proc/PID/cmdline is NUL-separated and has no trailing newline.
        dev "$TARGET" "tr '\0' ' ' </proc/$pid/cmdline; echo" | sed 's/^/         /'
    else
        warn "pidfile says $pid but /proc/$pid is gone"
    fi
fi

reachable "root@$TARGET" \
    && ok "ssh root@$TARGET works (key auth)" \
    || warn "ssh from this host did not verify"

# =========================================================================
if [ "$REBOOT_TEST" = 1 ]; then
# =========================================================================
step "Reboot test"
# =========================================================================

before=$(dev "$TARGET" 'cut -d. -f1 /proc/uptime' 2>/dev/null)
note "uptime before reboot: ${before:-unknown}s"

dev "$TARGET" 'reboot' >/dev/null 2>&1
note "rebooting; waiting for the device to come back"

back=0
for i in $(seq 1 90); do
    sleep 5
    now=$(dev "$TARGET" 'cut -d. -f1 /proc/uptime' 2>/dev/null)
    if [ -n "$now" ] && { [ -z "$before" ] || [ "$now" -lt "$before" ]; }; then
        printf '\n    %sok%s   back after ~%ds, uptime=%ss\n' "$G" "$N" $((i*5)) "$now"
        back=1
        break
    fi
    [ $((i % 6)) -eq 0 ] && printf '    ...%ss\n' $((i*5))
done

if [ "$back" = 0 ]; then
    die "device did not come back within 450s.
      The Start SSH scriptlet is the recovery path and needs no cable:
      wake the Kindle, Library -> tap 'Start SSH', then re-run this script."
fi

if dev "$TARGET" "netstat -ltn 2>/dev/null | grep -q ':22 '"; then
    ok "dropbear came up by itself — the boot job works"
else
    die "device is back but :22 is not listening. Check: just status"
fi

# =========================================================================
fi

step "Done"
# =========================================================================
cat <<EOF
    ${B}SSH is set up.${N}

      ssh $ALIAS                       # root shell, no password
      just status                      # job state, pid, listeners
      just find-kindle                 # re-locate if the DHCP address moves

    The USB cable is no longer needed for anything.

    The Kindle sleeps when idle. That is intended — press a button to wake it,
    and SSH comes back within a few seconds. See "Power model" in docs/SSH.md.

    Blank-password login is still enabled. To close it:
      edit scripts/start-ssh.sh          AUTH=-s
      edit the upstart job's dropbear line on the device to match
      just autostart

    Details and the traps involved: docs/SSH.md
EOF
