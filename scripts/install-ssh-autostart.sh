#!/bin/sh
# Install the dropbear upstart job. Run on the Kindle as root:
#
#   ssh root@<ip> 'sh -s' < scripts/install-ssh-autostart.sh
#
# or via `just autostart`. Requires SSH to already be up — see
# scripts/start-ssh.sh for how to get there without SSH.
#
# Why upstart: Amazon's Kindles use upstart, not systemd. A job in
# /etc/upstart/ is picked up at every boot.
#
# The rootfs is mounted read-only. `mntroot rw` remounts it writable, but only
# for the life of that mount — after a reboot the rootfs returns to read-only
# while the file we wrote stays. So this needs running once, not once per boot.

set -eu

JOB=/etc/upstart/dropbear-system.conf
WATCHDOG=/etc/upstart/dropbear-watchdog.conf
KOR=/mnt/us/koreader
HOSTKEY=$KOR/settings/SSH/dropbear_ed25519_host_key
PIDFILE=/var/tmp/dropbear-scribe.pid
PORT=22

# How often the watchdog checks. Long on purpose: the Kindle sleeps between
# checks, and a tighter loop only wakes the CPU to find nothing wrong.
TICK=60

echo "=== install dropbear autostart ==="

command -v initctl >/dev/null || { echo "FAIL: no initctl — not an upstart system"; exit 1; }
command -v mntroot >/dev/null || { echo "FAIL: no mntroot"; exit 1; }

if [ ! -f "$KOR/dropbear" ]; then
    echo "FAIL: $KOR/dropbear missing — run the Start SSH scriptlet first"
    exit 1
fi

echo "--- remounting rootfs read-write"
mntroot rw

echo "--- writing $JOB"
cat > "$JOB" <<EOF
start on started filesystems_userstore
stop on stopping filesystems_userstore

task

script
    export HOME=/tmp/root
    mkdir -p /tmp/root 2>/dev/null

    # INPUT defaults to DROP on the Kindle. Re-open each boot, because the
    # iptables table is rebuilt from scratch on startup.
    iptables -C INPUT -i wlan0 -p tcp --dport $PORT \\
        -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null || \\
    iptables -I INPUT -i wlan0 -p tcp --dport $PORT \\
        -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT

    # Without this an SSH session gets a shell with no pty and dies.
    mount | grep -q devpts || {
        mkdir -p /dev/pts 2>/dev/null
        mount -t devpts devpts /dev/pts 2>/dev/null
    }

    cd $KOR || exit 1

    # -r reuses the host key KOReader already generated. Without it dropbear
    # generates a new one on first start and the fingerprint changes on every
    # reinstall. -n allows blank-password login; root's /etc/shadow entry is
    # "!", so this flag is the only way in.
    #
    # 'task' above means upstart does not track this process: the job shows as
    # stop/waiting while dropbear keeps listening. That is expected, not a bug.
    ./dropbear -E -r $HOSTKEY -p $PORT -P $PIDFILE -n
end script
EOF

# ---------------------------------------------------------------------------
# Watchdog — OPT-IN, OFF BY DEFAULT
#
# The job file is written so it is ready if you want it, but it is NOT started.
# Do not start it just in case. It has caused two incidents and prevented none:
#
#   * An escaped \$TICK shipped "sleep $TICK" into the job with TICK unset;
#     busybox sleep exits immediately and the loop spun at 100% CPU.
#   * Its lipc-get-prop call once a minute reset the Kindle's idle timer, so
#     the device never reached sleep. With the job stopped, the countdown ran
#     to zero untouched: Active -> Screen Saver -> Ready to suspend -> asleep.
#
# Against that, dropbear has survived 4 reboots and a suspend cycle without
# ever needing a nudge. Restarting a listener that has never died is insurance
# whose premium is the device never sleeping.
#
# If you do want it — say you have seen dropbear exit on its own — start it with
#   just watchdog-start
# and check it is not the thing keeping the Kindle awake:
#   just health          # want prevent_screen_saver:0 and a counting-down timer
# ---------------------------------------------------------------------------

echo "--- writing $WATCHDOG"
cat > "$WATCHDOG" <<EOF
# Opt-in. 'manual' means upstart will never start this on its own, so it
# cannot keep the device awake unless someone explicitly asks for it.
manual

start on started filesystems_userstore
stop on stopping filesystems_userstore
respawn

script
    LOG=/var/tmp/ssh-watchdog.log
    : > \$LOG
    echo "\$(date) watchdog start" >> \$LOG

    while true; do
        # Every tick is logged. This job died silently at boot once already
        # and there was no way to tell why; a rolling log on tmpfs costs
        # nothing and turns that class of bug into a one-line answer.
        #
        # DO NOT call lipc-get-prop in here.
        #
        # Measured: querying a LIPC publisher resets the Kindle's idle timer.
        # With this loop calling it once a minute, the device never reached
        # sleep — the screensaver would appear and then bounce straight back to
        # Active, and the Kindle could only be put to sleep by hand. Stop this
        # job and the countdown ran to zero untouched: Active -> Ready to
        # suspend -> asleep.
        #
        # So the only things this loop may do are read /proc via netstat, write
        # to its own log, and exec dropbear. If you need the wifi state, ask for
        # it on demand with 'just health' — querying it only matters when you
        # are already awake and connected.
        echo "\$(date) tick" >> \$LOG

        # Restart dropbear if the listener vanished. Deliberately NOT
        # killall dropbear: that would also take out KOReader's own server on
        # 2222, which is the recovery path when this goes wrong.
        #
        # When the Kindle is asleep none of this runs — the loop is suspended
        # along with everything else. On wake it resumes and, if dropbear did
        # not survive the suspend, this puts it back.
        if ! netstat -ltn 2>/dev/null | grep -q ":$PORT "; then
            echo "\$(date) port $PORT gone — restarting dropbear" >> \$LOG
            export HOME=/tmp/root
            mkdir -p /tmp/root 2>/dev/null
            cd $KOR || cd /
            ./dropbear -E -r $HOSTKEY -p $PORT -P $PIDFILE -n >/dev/null 2>&1
        fi

        # $TICK is expanded when this heredoc is written, so the job ends up
        # with a literal "sleep 60". Escaping it as \$TICK writes "sleep $TICK"
        # into the job, where TICK is unset: busybox sleep then exits with rc=1
        # immediately and the loop spins at 100% CPU. That bug shipped once.
        # shellcheck disable=SC2034
        sleep $TICK
    done
end script
EOF

echo "--- installed"
cat "$JOB"

echo "--- registered?"
# The job name comes from the filename, so the body never contains
# "dropbear-system" — match on 'dropbear' and report per job.
for j in dropbear-system dropbear-watchdog; do
    if initctl list | grep -q "$j"; then
        echo "  $j: $(initctl list | grep "$j")"
    else
        # Only registered at boot: init reads /etc/upstart when it starts, so
        # a file written after boot does not appear until the next reboot.
        echo "  $j: not registered yet — will be picked up at the next reboot"
    fi
done

echo "--- validating the script bodies without binding the port"
# dropbear is already listening on 22, so starting a second instance now would
# only fail on bind. Check the parts that can fail silently instead.
( export HOME=/tmp/root
  mkdir -p "$HOME" 2>/dev/null
  cd "$KOR" || exit 1
  ./dropbear -h 2>&1 | head -1
  if iptables -C INPUT -i wlan0 -p tcp --dport "$PORT" \
        -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null; then
      echo "  firewall rule for $PORT already present"
  else
      echo "  firewall rule for $PORT absent — the job adds it at boot"
  fi
  mount | grep -q devpts && echo "  devpts mounted" || echo "  WARN: devpts not mounted"
  # Verify the tools the watchdog depends on, rather than discovering at
  # runtime that one of them is missing.
  for t in wpa_cli netstat lipc-set-prop lipc-get-prop; do
      command -v "$t" >/dev/null 2>&1 \
          && echo "  $t: ok" \
          || echo "  $t: MISSING — watchdog recovery will be weaker"
  done
  echo "  cmState now: $(lipc-get-prop com.lab126.wifid cmState 2>&1)"
)

echo
echo "=== installed ==="
echo "  $JOB   dropbear on wlan0:$PORT at boot — active, starts at next boot"
echo "  $WATCHDOG  written but NOT started (opt-in)"
echo
echo "Verify after a reboot:  just status"
echo
echo "The Kindle is meant to sleep. Check nothing is holding it awake:"
echo "  just health          # prevent_screen_saver must be 0, timer counting down"
echo
echo "If you do want the watchdog:  just watchdog-start"
echo "If SSH stops coming back, recover with no cable and no SSH:"
echo "  wake the Kindle, Library -> tap 'Start SSH', then re-run:"
echo "  scripts/setup-ssh.sh"
