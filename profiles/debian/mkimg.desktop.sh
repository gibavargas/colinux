#!/usr/bin/env bash
# =============================================================================
# CoLinux Desktop — Live-Build Configuration
# =============================================================================
# Configures the Debian live-build (lb) environment for colinux-desktop.
# This is sourced or called by build-debian.sh.
#
# Sets up: distribution, packages, kernel, boot, overlays, hooks
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Build metadata ──
CODENAME="bookworm"
DISTRIBUTION="debian"
EDITION="colinux-desktop"
ARCH="amd64"
VERSION="${VERSION:-1.0.0}"
BUILD_DATE="$(date +%Y%m%d)"

# ── Paths ──
PROFILE_DIR="$SCRIPT_DIR"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/work/debian-build}"
OVERLAY_DIR="$PROFILE_DIR/overlay"
PACKAGE_LIST="$PROFILE_DIR/packages.desktop"

# ── Live-build configuration ──
lb_config() {
    echo "Configuring live-build for $EDITION..."

    cd "$BUILD_DIR"

    lb config \
        --distribution "$CODENAME" \
        --debian-installer none \
        --mode debian \
        --architectures "$ARCH" \
        --archive-areas "main contrib non-free non-free-firmware" \
        --debootstrap-options "--variant=minbase --include=apt-transport-https,ca-certificates,gnupg" \
        --bootloader "syslinux,grub-efi" \
        --uefi-secure-boot enable \
        --binary-images "iso-hybrid" \
        --iso-application "CoLinux Desktop" \
        --iso-publisher "CoLinux Project (https://github.com/colinux)" \
        --iso-volume "colinux-desktop" \
        --iso-level 3 \
        --linux-packages "linux-image-amd64" \
        --linux-flavours "amd64" \
        --firmware-binary true \
        --firmware-chroot true \
        --initramfs systemd \
        --kernel-packages "linux-image-amd64 linux-headers-amd64" \
        --system live \
        --memtest none \
        --source false \
        --verbose \
        2>&1

    echo "Base configuration complete."
}

# ── Install package lists ────────────────────────────────────────────────────
install_packages() {
    echo "Installing package lists..."

    mkdir -p "$BUILD_DIR/config/package-lists"

    if [ -f "$PACKAGE_LIST" ]; then
        cp "$PACKAGE_LIST" "$BUILD_DIR/config/package-lists/desktop.list.chroot"
        echo "  → desktop.list.chroot ($(wc -l < "$PACKAGE_LIST") packages)"
    fi

    # Additional task packages
    cat > "$BUILD_DIR/config/package-lists/tasks.list.chroot" <<'EOF'
# Task selections
tasksel
EOF
}

# ── Install overlay ──────────────────────────────────────────────────────────
install_overlay() {
    echo "Installing overlay filesystem..."

    if [ ! -d "$OVERLAY_DIR" ]; then
        echo "  WARNING: No overlay directory at $OVERLAY_DIR"
        return
    fi

    local target="$BUILD_DIR/config/overlays/colinux/chroot"
    mkdir -p "$target"

    # Copy entire overlay
    cp -a "$OVERLAY_DIR"/. "$target"/

    # Fix permissions for scripts
    find "$target/usr/local/bin" -type f -exec chmod 755 {} \; 2>/dev/null || true
    find "$target/etc/sudoers.d" -type f -exec chmod 440 {} \; 2>/dev/null || true

    # Fix ownership
    chown -R root:root "$target" 2>/dev/null || true

    # Count files
    local count
    count="$(find "$target" -type f | wc -l)"
    echo "  → Installed $count overlay files"
}

# ── Install hooks ────────────────────────────────────────────────────────────
install_hooks() {
    echo "Installing build hooks..."

    mkdir -p "$BUILD_DIR/config/hooks"

    # ── Pre-chroot hook: Setup repositories ──
    cat > "$BUILD_DIR/config/hooks/0010-setup-repos.chroot" <<'HOOK'
#!/bin/bash
set -e
echo "Setting up additional repositories..."

# Node.js 20.x (LTS)
if [ ! -f /etc/apt/sources.list.d/nodesource.list ]; then
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg 2>/dev/null || true
    echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
fi
HOOK

    # ── Post-chroot hook: System customization ──
    cat > "$BUILD_DIR/config/hooks/5000-colinux-customize.chroot" <<'HOOK'
#!/bin/bash
set -e
echo "Customizing CoLinux..."

# ── Copy setup script to chroot ──
mkdir -p /opt/colinux-setup
if [ -f /opt/colinux-setup/setup-codex-desktop.sh ]; then
    chmod +x /opt/colinux-setup/setup-codex-desktop.sh
fi

# ── Create codex user ──
if ! id codex &>/dev/null; then
    useradd -m -s /bin/bash \
        -G sudo,netdev,plugdev,cdrom,floppy,audio,video,systemd-journal,dip,bluetooth \
        codex
fi

# ── Apply codex user config ──
if [ -f /home/codex/.bashrc.codex ]; then
    cp /home/codex/.bashrc.codex /home/codex/.bashrc
    rm /home/codex/.bashrc.codex
fi

if [ -f /home/codex/.profile.codex ]; then
    cp /home/codex/.profile.codex /home/codex/.profile
    rm /home/codex/.profile.codex
fi

chown -R codex:codex /home/codex

# ── Set up MOTD ──
if [ -f /etc/motd.codex ]; then
    cat /etc/motd.codex > /etc/motd
    rm /etc/motd.codex
fi

# ── Set up fstab additions ──
if [ -f /etc/fstab.codex ]; then
    cat /etc/fstab.codex >> /etc/fstab
    rm /etc/fstab.codex
fi

# ── Fix permissions on utility scripts ──
chmod 755 /usr/local/bin/codex-* 2>/dev/null || true

# ── Set hostname ──
echo "colinux-desktop" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1	localhost
127.0.1.1	colinux-desktop
::1		localhost ip6-localhost ip6-loopback
ff02::1		ip6-allnodes
ff02::2		ip6-allrouters
HOSTS

# ── Configure locale ──
if [ -f /etc/default/locale ]; then
    echo "LANG=en_US.UTF-8" > /etc/default/locale
    echo "LANGUAGE=en_US:en" >> /etc/default/locale
fi
locale-gen en_US.UTF-8 2>/dev/null || true

# ── Configure timezone ──
ln -sf /usr/share/zoneinfo/UTC /etc/localtime 2>/dev/null || true
echo "UTC" > /etc/timezone

# ── Enable systemd services ──
systemctl enable codex-update.timer 2>/dev/null || true
systemctl enable codex-firstboot.service 2>/dev/null || true
systemctl enable codex-disk-inventory.service 2>/dev/null || true
systemctl enable NetworkManager 2>/dev/null || true
systemctl enable lightdm 2>/dev/null || true

# ── Remove unnecessary packages ──
apt-get autoremove -y --purge 2>/dev/null || true
apt-get clean

echo "CoLinux customization complete."
HOOK

    # ── Late chroot hook: Final cleanup ──
    cat > "$BUILD_DIR/config/hooks/9990-cleanup.chroot" <<'HOOK'
#!/bin/bash
set -e
echo "Final cleanup..."

# Remove build artifacts
rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
rm -f /etc/hostname.bak /etc/hosts.bak 2>/dev/null || true

# Truncate logs
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true

# Clear apt cache
rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true
rm -rf /var/lib/apt/lists/* 2>/dev/null || true

echo "Cleanup complete."
HOOK

    # Make hooks executable
    chmod 755 "$BUILD_DIR/config/hooks"/*.chroot

    echo "  → $(ls "$BUILD_DIR/config/hooks"/*.chroot 2>/dev/null | wc -l) hooks installed"
}

# ── Install bootloader config ────────────────────────────────────────────────
install_bootloader() {
    echo "Configuring bootloader..."

    mkdir -p "$BUILD_DIR/config/bootloaders"

    # Syslinux splash text
    mkdir -p "$BUILD_DIR/config/bootloaders/isolinux"
    cat > "$BUILD_DIR/config/bootloaders/isolinux/isolinux.cfg" <<'SYSLINUX'
DEFAULT colinux
TIMEOUT 30
PROMPT 0

LABEL colinux
    MENU LABEL CoLinux Desktop (Live)
    KERNEL /vmlinuz
    APPEND initrd=/initrd.img boot=live persistence quiet splash
    MENU DEFAULT

LABEL colinux-nomodeset
    MENU LABEL CoLinux Desktop (Safe Graphics)
    KERNEL /vmlinuz
    APPEND initrd=/initrd.img boot=live persistence quiet splash nomodeset

LABEL memtest
    MENU LABEL Memory Test
    KERNEL /live/memtest
SYSLINUX

    # GRUB config
    mkdir -p "$BUILD_DIR/config/bootloaders/grub"
    cat > "$BUILD_DIR/config/bootloaders/grub/grub.cfg" <<'GRUB'
set default=0
set timeout=5

menuentry "CoLinux Desktop (Live)" {
    linux /vmlinuz boot=live persistence quiet splash
    initrd /initrd.img
}

menuentry "CoLinux Desktop (Safe Graphics)" {
    linux /vmlinuz boot=live persistence quiet splash nomodeset
    initrd /initrd.img
}
GRUB

    echo "  → Bootloader configured"
}

# ── Run all ──────────────────────────────────────────────────────────────────
configure_all() {
    lb_config
    install_packages
    install_overlay
    install_hooks
    install_bootloader
    echo ""
    echo "Live-build configuration complete."
    echo "Run 'lb build' in $BUILD_DIR to create the ISO."
}

# If called directly (not sourced), run all
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    configure_all
fi
