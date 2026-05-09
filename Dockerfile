# CoLinux Lite — Development & Testing Container
# Simulates the full Alpine-based CoLinux environment
# Usage: docker build -t colinux-lite . && docker run -it colinux-lite

FROM alpine:3.21

LABEL maintainer="CoLinux Project"
LABEL description="CoLinux Lite development/test environment"
LABEL version="0.1.0"

# Install all packages from the lite edition
RUN apk add --no-cache \
    alpine-base \
    linux-lts-doc \
    bash \
    coreutils \
    util-linux \
    eudev \
    doas \
    tmux \
    git \
    openssh-client-default \
    curl \
    wget \
    ca-certificates \
    jq \
    yq-go \
    ripgrep \
    fd \
    fzf \
    nano \
    python3 \
    parted \
    gptfdisk \
    e2fsprogs \
    dosfstools \
    exfatprogs \
    btrfs-progs \
    xfsprogs \
    cryptsetup \
    lvm2 \
    mdadm \
    rsync \
    smartmontools \
    pciutils \
    usbutils \
    file \
    iw \
    openssl \
    tar \
    gzip \
    xz \
    shadow \
    procps

# Create runtime directories
RUN mkdir -p /run/codex \
    /persist/config \
    /persist/data \
    /persist/logs \
    /persist/backups \
    /persist/ssh \
    /persist/state \
    /workspace \
    /mnt/disks/by-label \
    /mnt/disks/by-uuid \
    /mnt/disks/by-device \
    /var/cache/apk \
    /etc/default

# Create codex user
RUN adduser -D -s /bin/bash -h /home/codex codex && \
    mkdir -p /etc/sudoers.d && \
    echo "codex ALL=(root) NOPASSWD: /usr/local/bin/codex-disk-inventory, /usr/local/bin/codex-network, /usr/local/bin/codex-backup, /usr/local/bin/codex-restore, /usr/local/bin/codex-update, /usr/local/bin/codex-shell, /usr/local/bin/codexctl, /usr/local/bin/codex-logs, /usr/local/bin/codex-mount-rw, /usr/local/bin/codex-mount-ro, /usr/local/bin/codex-usb-persist" > /etc/sudoers.d/codex && \
    chown -R codex:codex /home/codex /workspace /persist

# Install doas config
COPY profiles/alpine/overlay/etc/doas.conf /etc/doas.conf
RUN chmod 640 /etc/doas.conf

# Install all codex-* tools
COPY profiles/alpine/overlay/usr/local/bin/ /usr/local/bin/
RUN chmod +x /usr/local/bin/codex-* /usr/local/bin/codexctl

# Install first-boot, setup-codex, and cron-update scripts
COPY scripts/first-boot.sh /usr/local/bin/first-boot
COPY scripts/setup-codex.sh /usr/local/bin/setup-codex
COPY scripts/cron-codex-update.sh /usr/local/bin/cron-codex-update
RUN chmod +x /usr/local/bin/first-boot /usr/local/bin/setup-codex /usr/local/bin/cron-codex-update

# Install AGENTS.md
COPY AGENTS.md /workspace/AGENTS.md

# Install system configs
COPY profiles/alpine/overlay/etc/profile /etc/profile.d/colinux.sh
COPY profiles/alpine/overlay/etc/motd /etc/motd
COPY profiles/alpine/overlay/etc/config/auto-update.conf /persist/config/auto-update.conf
COPY profiles/alpine/overlay/etc/codex-update-crontab /etc/codex-update-crontab

# Create mock codex binary for testing (placeholder until real binary is downloaded)
RUN printf '%s\n' \
    '#!/bin/bash' \
    '# CoLinux — Codex CLI placeholder' \
    'VERSION="${CODEX_VERSION:-0.1.0-placeholder}"' \
    'if [ "$1" = "--version" ]; then echo "codex $VERSION (CoLinux Lite placeholder)"; exit 0; fi' \
    'if [ "$1" = "--help" ]; then echo "CoLinux Lite - OpenAI Codex CLI placeholder"; echo "Run: setup-codex --install"; exit 0; fi' \
    'echo "CoLinux Lite - Codex CLI Placeholder"' \
    'echo "To install real Codex binary: setup-codex --install"' \
    'exec bash' \
    > /usr/local/bin/codex && chmod +x /usr/local/bin/codex

# Install OpenRC init scripts
COPY profiles/alpine/overlay/etc/init.d/ /etc/init.d/

# Setup entrypoint
RUN echo "ENABLED=yes" > /etc/default/codex-firstboot 2>/dev/null || true

# Set working directory
WORKDIR /workspace

# Copy user profile
COPY profiles/alpine/overlay/home/codex/.profile /home/codex/.profile
RUN chown codex:codex /home/codex/.profile

# Entrypoint: run as codex user, launch codex-shell
USER codex
ENTRYPOINT ["/usr/local/bin/codex-shell"]
