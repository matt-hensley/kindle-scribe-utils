# SSH on the Scribe

Root SSH over Wi-Fi, without USBNetLite, KUAL, MRPI, or an OTA.

Target device: **Scribe 2022**, firmware **5.19.6**, kernel `4.9.77-lab126`,
armv7l, jailbroken with Véra (jb.sh 1.3.7).

All of the findings below were measured on one device; the specifics are called
out where they matter. Device identifiers are deliberately not recorded here.

## Why not USBNetLite

The obvious answer — and the one
[MIP's guide](https://mip-wiki.pages.dev/database/usbnet/) gives — is
USBNetLite, dropped as a `.bin` into `/mnt/us/mrpackages` and installed from
KUAL's *Helper → Install MR Packages* (or `;log mrpi`).

**None of that exists on this device.**

| Prerequisite for that path | State here |
| --- | --- |
| `/mnt/us/mrpackages` | absent |
| `/mnt/us/extensions` (KUAL) | absent |
| `start-ssh`, `dropbearmulti` in `$PATH` | absent |

KUAL and MRPI are dead on firmware ≥ 5.19.4; Véra replaces them with KPM, and
KPM's repository carries only `koreader` and `kpm` — no SSH package. The guide's
"Alternate Instructions" — put the `.bin` at the **storage root** and force an
OTA — would both fail (there is no KUAL to run the installer once the OTA
lands) and risk the jailbreak. See the gotcha in
[HANDOFF.md](HANDOFF.md#gotchas): `.bin` files on the storage root trigger
official OTA.

## What is already on the device

KOReader is installed via KPM, and it ships a dropbear:

| Path | Size | What it is |
| --- | --- | --- |
| `/mnt/us/koreader/dropbear` | 191,576 B | dropbear **server**, armhf |
| `/mnt/us/koreader/settings/SSH/dropbear_ed25519_host_key` | — | host key, already generated |
| `/mnt/us/koreader/plugins/SSH.koplugin` | — | KOReader's own SSH toggle |

This is a server-only build, **not** `dropbearmulti` — it is invoked directly as
`./dropbear -E -R -p PORT`, with no subcommand argument. KOReader patches it
with two things that matter here:

- **`-n`** — allow blank-password login.
- **authorized_keys** resolved from `settings/SSH/authorized_keys` *relative to
  the working directory*, so the process must `cd` into `/mnt/us/koreader`.

Measured on this device: **dropbear v2026.92**, pid recorded in
`/var/tmp/dropbear-scribe.pid`.

## Three Kindle-specific traps

**1. iptables INPUT.** On this device the policy is `-P INPUT ACCEPT` and only 3
rules existed, so this one was not actually load-bearing — but the rule is still
added, scoped `-i wlan0`, because other builds ship INPUT defaulting to DROP.

**2. Root's password is locked.** `/etc/shadow` has `!` for root, so a normal
password login is impossible. You need `-n` (blank password) or `-s`
(key-only).

**3. Wi-Fi drops when the device goes idle, and does not always come back.**
The Kindle sleeps aggressively to save power. Once asleep, wlan0 is gone and
SSH is unreachable — this is correct and expected, not a fault.

- Symptom on the host is `ssh: connect to host ... No route to host` plus
  `ip neigh` showing `FAILED` — which looks like a routing problem and is not.
- `uptime` proves the device never rebooted.
- `lipc-get-prop com.lab126.wifid cmState` reports `PENDING` or `NA`. See
  [MobileRead #351836](https://www.mobileread.com/forums/showthread.php?t=351836):
  *"the wifi stops being connected, and never reconnects. As soon as I touch the
  screen, it reconnects."*
- Sometimes it never recovers unattended. Wake the device: press a button.
  dropbear is still bound to port 22, so SSH returns seconds later.

**4. Two "obvious" power commands are traps.** Both measured on this device by
bisecting a loop one command at a time, not guessed:

| Command | Result |
| --- | --- |
| `lipc-set-prop com.lab126.powerd preventScreenSleep 1` | job survived 11 iterations, then `stop/waiting` |
| `wpa_cli -i wlan0 reconnect` | log shows it firing, then the process is gone |

`preventScreenSleep` turns out not to exist on this firmware at all —
`lipc-set-prop` returns `lipcErrNoSuchProperty` (0x8). Setting it failed, and
the failure took the job down with it. So neither the property nor the
`wpa_cli` recovery belongs in a watchdog.

**Never set `preventScreenSaver` to keep SSH alive.** It works — and it pins
the device awake forever, so the Kindle never sleeps again. An earlier version
of the watchdog set it every 30 s and the Scribe stopped sleeping entirely.
If you want it to sleep, leave the power state alone.

## The MTP / UI deadlock

You cannot bootstrap over the cable. The Kindle will not let you operate the UI
while it is mounted as a USB media device, so:

- the scriptlet writes its IP to `/mnt/us/ssh.log`, but reading that needs MTP;
- tapping the `Start SSH` book needs the UI, which MTP blocks.

Break it by finding the device on the LAN instead:

```sh
just find-kindle          # sweep the subnet, print anything answering 22/2222
```

Discovery is by **open port**, not MAC: 22 is our dropbear, 2222 is KOReader's
own. That needs no per-device configuration, and it matters because Kindles
randomise their MAC per SSID — a hardcoded one goes stale as soon as you roam
networks. Set `SCRIBE_KINDLE_MAC` to also match on MAC if you want to pin it.

**None of this is needed after the first successful boot.** Once SSH is up,
`just deploy` and `just recon` use scp/ssh and the cable stays unplugged.

## Setup

### 1. Start it now

```sh
just ssh-push          # or: mise run ssh:push
```

Pushes `scripts/start-ssh.sh` to `/mnt/us/documents/`. **Then tap the
`Start SSH` book in the Kindle's library.** The scriptlet runs as root, which
is the whole launcher mechanism — there is no daemon to install.

It does three jobs:

- **Recovers Wi-Fi** if it has dropped, then polls for the address.
- **Launch** dropbear on `wlan0:22` after opening the firewall.

It does not touch power state — see [Power model](#power-model).

Everything lands in `/mnt/us/ssh.log`, readable over MTP whether or not SSH came
up — which matters, because that log is the *only* diagnostic available when a
USB-connected run misfires.

> **Check the listener, not the process table.** dropbear daemonises and
> rewrites `argv[0]`, so `ps | grep dropbear` reports nothing even when it is
> serving normally. An early version of this script trusted `ps` and printed
> `NOT RUNNING` while port 22 was actually `LISTEN` — which sent the whole
> investigation down the wrong path. Use `netstat -ltn | grep ':22 '`, or read
> `/proc/$(cat /var/tmp/dropbear-scribe.pid)/cmdline`.

### 2. Connect

```sh
ssh kindle              # alias in ~/.ssh/config
```

A key was installed for this device:

| Host | Path |
| --- | --- |
| private | `~/.ssh/id_kindle` (ed25519) |
| public | `/mnt/us/koreader/settings/SSH/authorized_keys` |

That is KOReader's cwd-relative path, **not** a root `~/.ssh/`. Blank-password
login still works too — both are accepted — but key auth is what the build
recipes use, since scp/ssh run without a tty.

### 3. Start it at boot

```sh
SCRIBE_HOST=<ip> just ssh-autostart
```

Writes `/etc/upstart/dropbear-system.conf` and registers it. Kindles use
**upstart, not systemd**. The rootfs is read-only, so the installer runs
`mntroot rw` first; that remount is session-scoped, but the job file persists
and is picked up on every subsequent boot.

Verified by rebooting the device: boot at `12:12:00`, dropbear pid 1960
listening by `12:12:11`, with a fresh PID and no scriptlet tap.

```sh
just ssh-status    # job state, pid + cmdline, listeners on 22
just ssh-start     # start now
just ssh-stop      # stop
```

`initctl list` reporting `dropbear-system stop/waiting` is **expected**, not a
failure. The job is declared `task`, so upstart does not track the process and
its start event (`filesystems_userstore`) fired at boot and will not fire again.
Do not "fix" it. `initctl start dropbear-system` also reports `Job failed to
start` for the same reason — harmless, and the installer no longer treats it as
an error.

## Boot-time trigger

```just
start on started filesystems_userstore
```

Not `started system` (fires before `/mnt/us` is mounted, so the binary isn't
there yet) and not `started userstore` (not a valid event name).

## Power model

**The Kindle sleeps, and that is intended.** It is not a device that stays
reachable on a shelf; it is a device you wake up.

| State | Wi-Fi | SSH |
| --- | --- | --- |
| awake | up | reachable |
| asleep | down | unreachable — expected |
| just woken | reassociating | back within a few seconds |
| reboot | up at boot | up in ~40s |

Measured on this device:

- Full sleep cycle observed: `Active` → `Screen Saver` → `Ready to suspend` →
  asleep. It then stayed asleep with port 22 closed, as it should.
- The cycle is roughly **20 minutes**, not 10: ~600s in `Active` before the
  screensaver, then ~600s of screensaver before suspend. Budget for that when
  checking whether a change broke sleeping, or you will conclude it is still
  awake when it is merely early.
- `powerd_test -s` reports `prevent_screen_saver:0`. That is the value that
  must stay 0.
- **dropbear survives the suspend untouched.** Across a boot at `14:22:29` and a
  wake at `16:14` — including a sleep in between — it was still the same pid
  (1976), started once, never restarted. Nothing has to be re-armed after a
  sleep.

So the working loop is: press a button, wait a few seconds, `ssh kindle`.

Nothing here pins the device awake. If you ever see `prevent_screen_saver:1`,
something has gone wrong — that setting keeps SSH perfectly reachable and the
battery quietly flat. An earlier version of the watchdog set it every 30s and
the Scribe stopped sleeping entirely.

```sh
just health    # uptime, wifi, power, port — the one-command diagnosis
```

## The watchdog — opt-in, off by default

`dropbear-watchdog.conf` is written but **never started**. It carries `manual`,
so upstart will not start it at boot either.

Its whole job: every 60s, check whether anything is listening on 22 and restart
dropbear if not. That is all.

**It is off because it cost twice and returned nothing.**

| Incident | What happened |
| --- | --- |
| 100% CPU | An escaped `\$TICK` put a literal `sleep $TICK` in the job with `TICK` unset. busybox `sleep` exits `rc=1` immediately, so the loop spun flat out. |
| Never sleeps | Its `lipc-get-prop` call once a minute reset the Kindle's idle timer. It reached screensaver and bounced straight back to `Active`, forever. |

Both measured, in both directions. With the job stopped, the countdown runs to
zero untouched:

```
Active 421s -> 340s -> 259s -> 179s -> 98s -> 17s -> Ready to suspend -> asleep
```

With it running, the timer never reached zero.

Against that: **dropbear has survived 4 reboots and a suspend cycle without ever
needing a nudge.** Restarting a listener that has never died is insurance whose
premium is the device never sleeping.

If you have seen dropbear exit on its own, start it deliberately:

```sh
just watchdog-start
just watchdog-log      # one line per tick
just watchdog-stop
```

Then confirm it is not the thing keeping the Kindle awake:

```sh
just health            # prevent_screen_saver must be 0, and the timer must count down
```

**If you enable it, never add a `lipc-get-prop` call to the loop.** Querying a
LIPC publisher resets the idle timer. Ask on demand with `just health` instead —
that only matters when you are already awake and connected.

Also true of any loop on this device: ticks landing exactly 60s apart is the
check that `sleep` is actually sleeping. It has failed once already — an escaped
`\$TICK` wrote a literal `sleep $TICK` into the job with `TICK` unset, busybox
`sleep` exited `rc=1` immediately, and the loop spun at 100% CPU.

If the standalone service refuses to start, work down this list — none of it
needs the cable:

1. **Is the device awake?** Press a button. This is the usual fix; a sleeping
   Kindle has no Wi-Fi and cannot be reached by anything.
2. **Is Wi-Fi connected?** If you get in, `ssh kindle 'ip -4 -o addr show wlan0'`.
   Otherwise read the address off the device: Settings → ⋮ → Device Options →
   About, or check your router's client list.
3. **Is dropbear listening?** `just ssh-status`. If the port is dead the
   watchdog should have restarted it within a minute.
4. **Still nothing?** Tap **Start SSH** in the Library. It runs as root and
   needs neither SSH nor the cable.
5. **Last resort:** KOReader's own SSH server, which lives and dies with the
   KOReader process and so does not depend on any of this:

   > Open KOReader → tap top edge for the menu → Cog → **Network** → **SSH server**
   > → enable **Login without password (DANGEROUS)**, then enable **SSH server**.
   > A popup shows the IP.

   ```sh
   ssh -p 2222 root@<ip>       # password: mario
   ```

kTerm is also installed and launches as root via
`/var/local/kmc/bin/kpm launch kterm` — a full root terminal on the device.

## Locking it down

Blank-password root on the LAN is fine on a home network and briefly; it is not
fine as a permanent state. A key is already installed for this workstation; to
close the password door entirely:

1. Change `AUTH=-n` to `AUTH=-s` in `scripts/start-ssh.sh`, and the matching
   `./dropbear` line in `/etc/upstart/dropbear-system.conf`. (`-s` is key-only.)
2. `just ssh-autostart` to reinstall the job.

Add other machines by putting their **public** keys in
`/mnt/us/koreader/settings/SSH/authorized_keys` — the patched cwd-relative path,
not `~/.ssh/authorized_keys`.

Use **ecdsa** or **ed25519** keys. KOReader's dropbear is new enough that
`ssh-rsa` still works here, but it has been rejected by modern OpenSSH on other
Kobo/Kindle builds; the workaround there is
`-o PubkeyAcceptedKeyTypes=+ssh-rsa`, which is worse than using a key type that
was never deprecated.

## Notes

- **Never use Toggle USBNet.** It puts the device on a USB gadget page you can
  only leave by holding power, and it breaks MTP. Everything here is Wi-Fi only.
- The device's IP is DHCP-assigned and will change. A reservation in the router
  pins it; `just find-kindle` re-finds it if it moves.
- The Kindle blocks its own UI while MTP is mounted, so the cable and the UI are
  mutually exclusive. Everything post-bootstrap works without it.

## Sources

- [KOReader SSH wiki](https://github.com/koreader/koreader/wiki/SSH) — the dropbear invocation, the Kindle iptables rules
- [koreader/koreader `plugins/SSH.koplugin/main.lua`](https://github.com/koreader/koreader/blob/master/plugins/SSH.koplugin/main.lua) — confirms the `-n` / `-s` patches and cwd-relative authorized_keys
- [afeige.com — A standalone SSH on the Kindle](https://afeige.com/en/log/kindle-standalone-ssh) — the upstart job, `filesystems_userstore` trigger, and the `-r <hostkey>` form
- [lancekrogers/kindle-userspace](https://github.com/lancekrogers/kindle-userspace) — Wi-Fi dropbear on a Scribe 5.19.5 after Véra; uses USBNetLite, which is why it does not apply here
- [MIP Wiki — USBNet(Lite)](https://mip-wiki.pages.dev/database/usbnet/) — the path that does not apply
