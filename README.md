# kindle-scribe-utils

Utilities for a jailbroken **Amazon Kindle Scribe 2022** (FW 5.19.6, Véra).

Right now this is one thing: **root SSH over Wi-Fi**, set up and maintained
without needing the USB cable after the first time.

## Quick start

```sh
just setup            # idempotent; needs the cable once, then one tap
just status           # boot jobs, dropbear pid, listeners on 22
just health           # wifi / power / port — why is it unreachable?
just find-kindle      # sweep the LAN for it if its address moved
ssh kindle            # root shell
```

`just` or `mise run <task>`. Run `mise install` first if the tools are missing.

## What it sets up

KOReader — installed on the device by KPM — already ships a dropbear server and
a host key. This repo starts that dropbear as root on `wlan0:22` and installs
an upstart job so it comes back at every boot.

It is **not** USBNetLite. That needs `/mnt/us/mrpackages` and KUAL, neither of
which exist on firmware ≥ 5.19.4. See [docs/SSH.md](docs/SSH.md) for the full
reasoning and the traps.

## Power model

**The Kindle sleeps, and that is intended.** It is not a device that stays
reachable on a shelf — you wake it with a button press, then SSH is there.

```
awake        wifi up     ssh reachable
asleep       wifi down   ssh unreachable  <- expected
just woken   associating ssh back in seconds
reboot       wifi up     ssh up in ~40s
```

Nothing here pins the device awake. If you ever see `prevent_screen_saver:1`
in `just health`, something has gone wrong — that setting keeps SSH
perfectly reachable and the battery quietly flat.

## Layout

```
justfile                 recipes
mise.toml                pinned just + shellcheck
docs/SSH.md              how it works, and every trap hit getting there
scripts/
  setup-ssh.sh           one-shot idempotent setup; the entry point
  start-ssh.sh           Start SSH scriptlet — taps as a book, runs as root
  install-ssh-autostart.sh   writes the two upstart jobs
  find-kindle.sh         ARP sweep for the device by MAC
  mtp.sh                 MTP wrapper (bootstrap only, see below)
```

## Tasks

| Task | What it does |
| --- | --- |
| `just setup` | Full setup. Safe to re-run; each step checks its own state. |
| `just setup --reboot-test` | Also power-cycles the device to prove autostart. |
| `just push` | Push the scriptlet over MTP. Only for a fresh device, or after editing it. |
| `just find-kindle` | Sweep the LAN for anything answering on 22/2222. |
| `just autostart` | Install or reinstall the upstart jobs. |
| `just status` | Job state, dropbear pid + cmdline, listeners on 22. |
| `just health` | Uptime, wifi, power, port. Start here when it is unreachable. |
| `just start` / `just stop` | Start or stop the dropbear boot job. |
| `just watchdog-start` / `watchdog-stop` | Same, for the opt-in watchdog. |
| `just watchdog-log` | One line per watchdog tick. |

Override the target with `HOST=<kindle ip> just status`.

## Two upstart jobs

**`dropbear-system`** — starts dropbear on port 22 at boot. `task`, so
`initctl list` showing `stop/waiting` is correct, not a failure.

**`dropbear-watchdog`** — checks every 60s that something is listening on 22
and restarts dropbear if not. **Opt-in: it is written but never started**, and
carries `manual` so upstart will not start it either.

It is off because it caused two incidents and prevented none — a 100% CPU spin
from a bad heredoc escape, and a `lipc-get-prop` call that reset the Kindle's
idle timer so the device never slept. Meanwhile dropbear has survived 4 reboots
and a suspend without a nudge.

```sh
just watchdog-start     # only if you have seen dropbear exit on its own
just health             # then confirm it is not what keeps the Kindle awake
```

Full reasoning in [docs/SSH.md](docs/SSH.md).

## When it is unreachable

1. **Is it awake?** Press a button. This is the usual answer — a sleeping
   Kindle has no wifi and nothing can reach it.
2. `just find-kindle` — recover the address.
3. `just health` — but that needs SSH, so only after step 1.
4. Tap **Start SSH** in the Kindle's Library. Runs as root, needs neither the
   cable nor an existing SSH connection.
5. Last resort: KOReader → Cog → Network → SSH server, then
   `ssh -p 2222 root@<ip>` (password `mario`).

## Security

Blank-password root login is enabled, which is fine on a home LAN and is what
makes recovery work when everything else has failed. An ed25519 key is
installed for convenience and is what the recipes use.

To close the password door: set `AUTH=-s` in `scripts/start-ssh.sh` and the
matching `dropbear` line in the upstart job, then `just autostart`.

## A note on `mtp.sh`

MTP is needed for exactly one thing here: pushing the scriptlet to the device
before SSH exists. After that it is dead weight.

`mtp.sh` requires `SCRIBE_SERIAL` — there is no default, because the serial is
a unique device identifier and this repo is public.

```sh
export SCRIBE_SERIAL=G0XXXXXXXXXX     # lsusb | grep -i 1949
```

`find-kindle.sh` has no such requirement: it discovers by port, not by MAC.

## Sources

- [KOReader SSH wiki](https://github.com/koreader/koreader/wiki/SSH)
- [SSH.koplugin/main.lua](https://github.com/koreader/koreader/blob/master/plugins/SSH.koplugin/main.lua) — the `-n` patch and cwd-relative authorized_keys
- [afeige.com — A standalone SSH on the Kindle](https://afeige.com/en/log/kindle-standalone-ssh) — the upstart job shape
- [lancekrogers/kindle-userspace](https://github.com/lancekrogers/kindle-userspace) — Scribe 5.19.5 after Véra; uses USBNetLite, which is why it does not apply
- [MIP Wiki — USBNet(Lite)](https://mip-wiki.pages.dev/database/usbnet/) — the path that does not apply
