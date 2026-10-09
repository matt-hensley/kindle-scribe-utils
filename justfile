# Kindle Scribe utilities — root SSH over Wi-Fi
#
# Run `just` or `mise run <task>`. Recipes need `just`; see mise.toml.

set dotenv-load := false

home := env("HOME", "/root")

root := justfile_directory()
scripts := root / "scripts"

# The `kindle` alias from ~/.ssh/config. Override per-invocation:
#   HOST=<kindle ip> just status
host := env("HOST", "kindle")

# Key auth against the device. dropbear reads authorized_keys from
# /mnt/us/koreader/settings/SSH/authorized_keys — see docs/SSH.md.
key := env("KEY", home / ".ssh/id_kindle")
ssh_flags := "-i " + key + " -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"

_default:
    @just --list

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

# Full one-shot setup. Idempotent; needs the cable once, then one tap.
setup *args:
    #!/usr/bin/env bash
    set -uo pipefail
    scripts/setup-ssh.sh {{args}}

# Setup, then reboot the device to prove the boot job works.
setup-reboot-test:
    scripts/setup-ssh.sh --reboot-test

# Push the Start SSH scriptlet over MTP, then tap it on the Kindle.
push:
    #!/usr/bin/env bash
    set -euo pipefail
    scripts/mtp.sh mount >/dev/null
    scripts/mtp.sh push "documents/start-ssh.sh" scripts/start-ssh.sh
    echo
    echo "On the Kindle: Library -> tap 'Start SSH'."

# Locate the Kindle on the LAN by MAC, or recover if its address moved.
find-kindle:
    #!/usr/bin/env bash
    set -uo pipefail
    scripts/find-kindle.sh

# ---------------------------------------------------------------------------
# Boot-time jobs
# ---------------------------------------------------------------------------

require-host:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{host}}" ]; then
      echo "Set HOST=<kindle ip> (default is the 'kindle' ssh alias)" >&2
      exit 1
    fi
    ssh {{ssh_flags}} root@{{host}} true 2>/dev/null || {
      echo "Cannot reach root@{{host}} over SSH." >&2
      echo "  just find-kindle     # locate it on the LAN" >&2
      echo "  just push            # re-deploy the scriptlet, then tap 'Start SSH'" >&2
      echo "  just status          # is dropbear up?" >&2
      echo >&2
      echo "If the Kindle is asleep, press a button — it sleeps when idle." >&2
      exit 1
    }

# Install (or reinstall) the upstart jobs.
autostart: require-host
    ssh {{ssh_flags}} root@{{host}} 'sh -s' < scripts/install-ssh-autostart.sh

# Start the dropbear job now, without waiting for a reboot.
start: require-host
    ssh {{ssh_flags}} root@{{host}} 'initctl start dropbear-system || initctl restart dropbear-system'

# Stop the dropbear job.
stop: require-host
    ssh {{ssh_flags}} root@{{host}} 'initctl stop dropbear-system'

# Start the watchdog (restart dropbear if it dies).
watchdog-start: require-host
    ssh {{ssh_flags}} root@{{host}} 'initctl start dropbear-watchdog || initctl restart dropbear-watchdog'

# Stop the watchdog. Boot autostart is independent and keeps working.
watchdog-stop: require-host
    ssh {{ssh_flags}} root@{{host}} 'initctl stop dropbear-watchdog'

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

# Job state, dropbear pid + cmdline, and listeners on 22.
status: require-host
    ssh {{ssh_flags}} root@{{host}} 'initctl list | grep dropbear; echo "--- pid ---"; P=$(cat /var/tmp/dropbear-scribe.pid 2>/dev/null); if [ -n "$P" ] && [ -d /proc/$P ]; then echo "pid $P"; tr "\0" " " < /proc/$P/cmdline; echo; else echo "no pidfile entry"; fi; echo "--- port 22 ---"; netstat -ltn | grep ":22 " || echo "NOT listening"'

# Wifi, power and port state — why a device may be unreachable.
health: require-host
    ssh {{ssh_flags}} root@{{host}} 'echo "--- uptime ---"; uptime; echo "--- wifi ---"; echo "cmState: $(lipc-get-prop com.lab126.wifid cmState)"; ifconfig wlan0 | grep -E "inet|HWaddr" | sed "s/^/  /"; echo "--- power ---"; powerd_test -s 2>&1 | grep -E "Powerd state|Remaining|prevent_screen|Battery"; echo "--- port 22 ---"; netstat -ltn | grep ":22 " || echo "NOT listening"'

# The watchdog log — one line per tick, plus any restarts it performed.
watchdog-log: require-host
    ssh {{ssh_flags}} root@{{host}} 'cat /var/tmp/ssh-watchdog.log 2>/dev/null || echo "(no log — job not running)"'

# The Start SSH scriptlet's log, over MTP (needs the cable connected).
log:
    #!/usr/bin/env bash
    set -uo pipefail
    scripts/mtp.sh cat "ssh.log"
