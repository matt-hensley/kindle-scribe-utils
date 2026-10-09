#!/usr/bin/env bash
# Convenience wrapper around the Scribe's MTP mount.
#
# The Kindle Scribe has no USB mass-storage mode — it is MTP only, so there is
# no /dev/sdX to mount. `gio` with the gvfs mtp backend is the path of least
# resistance on Linux; calibre is an alternative but heavier.
#
# Mount is lazy: the first call discovers the activation root.

set -euo pipefail

SERIAL="${SCRIBE_SERIAL:-}"
VENDOR="${SCRIBE_VENDOR:-Amazon}"
MODEL="${SCRIBE_MODEL:-Kindle_Scribe}"

# No default serial: it is a unique device identifier and this repo is public.
# Find yours with: lsusb | grep -i 1949      (1949 = Lab126; model 9981 = Scribe)
# It is also on the box, and in Settings > Device Options > About.
[ -n "$SERIAL" ] || {
    cat >&2 <<'EOF'
SCRIBE_SERIAL is not set.

The Kindle's serial is a unique device identifier, so it has no default here.
Set it for this shell:

    export SCRIBE_SERIAL=G0XXXXXXXXXX

Find it with:  lsusb | grep -i 1949
EOF
    exit 1
}

ROOT="mtp://${VENDOR}_${MODEL}_${SERIAL}_${SERIAL}/Internal Storage"

# Encode a path for gio: spaces become %20, slashes stay as separators.
enc() { printf '%s' "$1" | sed -e 's/ /%20/g'; }

# Join root + user path, tolerating a missing or duplicated separator.
join() {
    local base="${ROOT%/}" p="${1:-}"
    [ -n "$p" ] && printf '%s/%s' "$base" "$(enc "${p#/}")" || printf '%s/' "$base"
}

find_root() {
    # Prefer the predictable name, fall back to asking gio what it sees.
    local candidate="mtp://${VENDOR}_${MODEL}_${SERIAL}_${SERIAL}/"
    if timeout 20 gio list "$candidate" >/dev/null 2>&1; then
        printf '%s' "$candidate"
        return 0
    fi
    local uri
    uri=$(timeout 30 gio mount -i -l 2>/dev/null \
        | grep -oE "activation_root=mtp://[^/]+/" \
        | head -1 | cut -d= -f2)
    if [ -n "$uri" ]; then
        printf '%s' "$uri"
        return 0
    fi
    return 1
}

cmd_mount() {
    local uri
    if uri=$(find_root); then
        echo "$uri"
        timeout 60 gio list "$uri" >/dev/null 2>&1 || {
            echo "gio could not list $uri" >&2
            return 1
        }
        return 0
    fi
    cat >&2 <<'EOF'
Could not find the Kindle over MTP.

Checks:
  lsusb | grep -i 1949      # Lab126 vendor id 1949; model 9981 = Scribe
  gio mount -i -l           # look for Volume(...) activation_root

The Kindle must be awake and USB-connected. It does not appear as a block
device: the Scribe is MTP-only.
EOF
    return 1
}

cmd_ls()    { timeout 120 gio list "$(join "${1:-}")"; }
cmd_mkdir()  {
    # gio copy will not create intermediate directories on MTP, so each level
    # has to exist first.
    local uri="$(join "$1")" part=""
    local IFS='/'
    for part in $1; do
        [ -n "$part" ] || continue
        timeout 60 gio mkdir "$uri" 2>/dev/null || true
        uri="${uri}/${part}"
    done
    echo "ensured $1"
}
cmd_pull()  {
    local src="$(join "$1")"
    mkdir -p "$(dirname "$2")"
    echo "pulling $1 -> $2"
    timeout 600 gio copy "$src" "$2"
}
cmd_push()  {
    local dst="$(join "$1")"
    echo "pushing $2 -> $1"
    timeout 600 gio copy "$2" "$dst"
}
cmd_cat()   { timeout 300 gio cat "$(join "$1")"; }
cmd_stat()  { timeout 120 gio info -a "standard::size,standard::type,time::modified" "$(join "$1")"; }

case "${1:-mount}" in
    mount) cmd_mount ;;
    ls)    shift; cmd_ls "${1:-}" ;;
    cat)   shift; cmd_cat "$1" ;;
    pull)  shift; cmd_pull "$1" "$2" ;;
    push)  shift; cmd_push "$1" "$2" ;;
    stat)  shift; cmd_stat "$1" ;;
    mkdir) shift; cmd_mkdir "$1" ;;
    root)  echo "$ROOT" ;;
    *)     sed -n '2,12p' "$0"; exit 1 ;;
esac