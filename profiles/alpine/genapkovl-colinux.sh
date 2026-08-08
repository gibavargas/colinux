#!/bin/sh -e
# =============================================================================
# CoLinux Lite — apkovl generator
# =============================================================================
# Called by Alpine's mkimage.sh section_apkovl() to produce
# <hostname>.apkovl.tar.gz, which is baked into the ISO and extracted into the
# root filesystem at boot.
#
# This does two things the base Alpine ISO lacks:
#   1. Copies the CoLinux overlay (codex-* wrappers, shared libs, inittab with
#      serial getty, doas.conf, OpenRC services, motd, profile, etc.) into the
#      root filesystem.
#   2. Creates OpenRC runlevel symlinks so essential services start
#      automatically (devfs, mdev, modloop, networking, sshd, and all
#      codex-* services).
#
# Without this script the overlay directory under
#   scripts/colinux-lite/overlay
# is never packaged — the ISO boots a stock Alpine with no codex binaries, no
# serial getty, and no enabled services beyond the absolute minimum.
# =============================================================================

HOSTNAME="$1"
if [ -z "$HOSTNAME" ]; then
    echo "usage: $0 hostname" >&2
    exit 1
fi

cleanup() {
    rm -rf "$tmp"
}

tmp="$(mktemp -d)"
trap cleanup EXIT

# ── Copy overlay files into the staging tree ─────────────────────────────────
# build_apkovl() in mkimg.base.sh invokes this script as:
#   (cd "$DESTDIR"; fakeroot "$_script" "$_host")
# so CWD=$DESTDIR (the ISO staging tree) and mkimage.sh's $scriptdir is NOT
# exported into this child process. We resolve our own directory from $0
# instead; $0 is the absolute path to this script as found by build_apkovl's
# search ($scriptdir/$apkovl in the aports tree).
_self="$0"
case "$_self" in
    /*) : ;;                      # absolute path — use as-is
    *)  _self="$PWD/$_self" ;;    # relative — resolve against CWD
esac
_mydir="$(dirname "$_self")"

# The overlay was placed by build-alpine*.sh:install_profile() into the
# aports scripts/ tree. Different editions use different subdirectory names:
#   lite:     scripts/colinux-lite/overlay
#   lite-gui: scripts/colinux-lite-gui/overlay-gui
#   desktop:  scripts/colinux-desktop/overlay-desktop
OVERLAY_DIR=""
for _d in \
    "$_mydir/colinux-lite/overlay" \
    "$_mydir/colinux-lite-gui/overlay-gui" \
    "$_mydir/colinux-desktop/overlay-desktop" \
    "$_mydir/colinux/overlay"; do
    if [ -d "$_d" ]; then
        OVERLAY_DIR="$_d"
        break
    fi
done

if [ -n "$OVERLAY_DIR" ] && [ -d "$OVERLAY_DIR" ]; then
    cp -a "$OVERLAY_DIR/." "$tmp/"
fi

# ── Ensure hostname is set ───────────────────────────────────────────────────
mkdir -p "$tmp/etc"
echo "$HOSTNAME" > "$tmp/etc/hostname"

# ── OpenRC runlevel symlinks ─────────────────────────────────────────────────
# These mirror what `rc-update add <service> <runlevel>` does. We create them
# here so the booted system has essential services enabled without needing a
# first-boot hook.
rc_add() {
    _svc="$1"
    _rl="$2"
    mkdir -p "$tmp/etc/runlevels/$_rl"
    ln -sf "/etc/init.d/$_svc" "$tmp/etc/runlevels/$_rl/$_svc"
}

# ── sysinit runlevel (hardware / device setup) ───────────────────────────────
rc_add devfs sysinit
rc_add dmesg sysinit
rc_add mdev sysinit
rc_add hwdrivers sysinit
rc_add modloop sysinit

# ── boot runlevel (base system) ──────────────────────────────────────────────
rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot
rc_add networking boot        # enables dhcpcd / network setup
rc_add loadkmap boot          # keyboard map (if configured)

# ── default runlevel (user-facing services) ──────────────────────────────────
rc_add chronyd default        # NTP time sync
rc_add sshd default           # SSH daemon for remote access
rc_add local default          # /etc/local.d/ scripts

# ── CoLinux services ─────────────────────────────────────────────────────────
# Only add services whose init.d scripts exist in the overlay. Using -f checks
# avoids dangling symlinks if an edition's overlay is trimmed.
for _svc in codex-firstboot codex-auto-update codex-disk-inventory; do
    if [ -f "$tmp/etc/init.d/$_svc" ]; then
        rc_add "$_svc" default
    fi
done

# ── shutdown runlevel ────────────────────────────────────────────────────────
rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

# ── Basic network config (loopback + eth0 DHCP) ──────────────────────────────
mkdir -p "$tmp/etc/network"
cat > "$tmp/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# ── Set secure permissions on sensitive files ────────────────────────────────
[ -f "$tmp/etc/doas.conf" ] && chmod 640 "$tmp/etc/doas.conf"
if [ -d "$tmp/etc/sudoers.d" ]; then
    find "$tmp/etc/sudoers.d" -type f -exec chmod 440 {} \;
fi

# ── Ensure codex user exists in passwd/shadow/group ──────────────────────────
# The alpine-base package provides a minimal /etc/passwd. We append the codex
# user so login works and doas can match it.
if ! grep -q '^codex:' "$tmp/etc/passwd" 2>/dev/null; then
    mkdir -p "$tmp/etc"
    # UID/GID 1000 is the standard first non-system user
    if ! grep -q '^codex:' "$tmp/etc/group" 2>/dev/null; then
        echo 'codex:x:1000:' >> "$tmp/etc/group"
    fi
    if [ -f "$tmp/etc/shadow" ] && ! grep -q '^codex:' "$tmp/etc/shadow" 2>/dev/null; then
        echo 'codex:!:10000:0:99999:7:::' >> "$tmp/etc/shadow"
    fi
    if [ -f "$tmp/etc/passwd" ]; then
        echo 'codex:x:1000:1000:codex:/home/codex:/bin/bash' >> "$tmp/etc/passwd"
    fi
fi

# Ensure the codex home directory exists with correct ownership metadata
if [ -d "$tmp/home/codex" ]; then
    # Record ownership so the tar preserves it (fakeroot context)
    chown 1000:1000 "$tmp/home/codex" 2>/dev/null || true
    chown -R 1000:1000 "$tmp/home/codex" 2>/dev/null || true
fi

# ── Package the overlay ──────────────────────────────────────────────────────
# gzip -9n = no name timestamp (reproducible)
tar -c -C "$tmp" . | gzip -9n > "$HOSTNAME.apkovl.tar.gz"
