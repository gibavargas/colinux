#!/usr/bin/env bash
# =============================================================================
# CodexOS Lite — QEMU Test Image Builder
# =============================================================================
# Creates a QEMU-compatible qcow2 image from the built ISO or raw image.
# Optionally boots it in QEMU for interactive testing.
#
# Usage:
#   ./build-qemu.sh [--iso <path>] [--raw <path>] [--size 4G] [--boot]
#   ./build-qemu.sh --boot               # Auto-find ISO and boot
#
# Options:
#   --iso <path>   Path to the CodexOS ISO file
#   --raw <path>   Path to the CodexOS raw disk image
#   --size <size>  QCOW2 virtual size (default: 4G)
#   --boot         Boot the image in QEMU after creation
#   --arch <arch>  Target architecture (default: auto-detect or x86_64)
#   --memory <mb>  RAM allocation in MB (default: 2048)
#   --no-gui       Run QEMU without graphical display (serial console only)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/dist"

# ── Defaults ─────────────────────────────────────────────────────────────────
QCOW2_SIZE="${QCOW2_SIZE:-4G}"
ARCH="${ARCH:-}"
MEMORY="${MEMORY:-2048}"
BOOT=false
NO_GUI=false
ISO_PATH=""
RAW_PATH=""

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)      ISO_PATH="$2"; shift 2 ;;
        --raw)      RAW_PATH="$2"; shift 2 ;;
        --size)     QCOW2_SIZE="$2"; shift 2 ;;
        --boot)     BOOT=true; shift ;;
        --arch)     ARCH="$2"; shift 2 ;;
        --memory)   MEMORY="$2"; shift 2 ;;
        --no-gui)   NO_GUI=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--iso ISO] [--raw IMG] [--size 4G] [--boot] [--arch ARCH] [--memory 2048] [--no-gui]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Auto-detect files ───────────────────────────────────────────────────────
if [ -z "$ISO_PATH" ] && [ -z "$RAW_PATH" ]; then
    # Try to find an ISO in the dist directory
    ISO_PATH="$(find "$DIST_DIR" -name 'codexos-lite-*.iso' 2>/dev/null | head -1)"
    if [ -z "$ISO_PATH" ]; then
        # Try raw image
        RAW_PATH="$(find "$DIST_DIR" -name 'codexos-lite-*.raw.img' 2>/dev/null | head -1)"
    fi
fi

# ── Detect architecture ──────────────────────────────────────────────────────
if [ -z "$ARCH" ]; then
    if [ -n "$ISO_PATH" ]; then
        case "$ISO_PATH" in
            *aarch64*|*arm64*) ARCH="aarch64" ;;
            *x86_64*|*amd64*) ARCH="x86_64" ;;
            *) ARCH="x86_64" ;;
        esac
    elif [ -n "$RAW_PATH" ]; then
        case "$RAW_PATH" in
            *aarch64*|*arm64*) ARCH="aarch64" ;;
            *) ARCH="x86_64" ;;
        esac
    else
        ARCH="$(uname -m)"
    fi
fi

# ── Build QCOW2 from raw image ──────────────────────────────────────────────
build_from_raw() {
    local raw="$1"
    local qcow2="${raw%.raw.img}.qcow2"

    echo "==> Converting raw image to QCOW2..."
    qemu-img convert -f raw -O qcow2 -q "$raw" "$qcow2"

    # Resize if needed
    qemu-img resize "$qcow2" "$QCOW2_SIZE" 2>/dev/null || true

    echo "==> QCOW2 image created: $qcow2"
    echo "    Virtual size: $(qemu-img info --output=json "$qcow2" | grep -o '"virtual-size": [0-9]*' | awk '{print $2}') bytes"
    echo "$qcow2"
}

# ── Build QCOW2 from ISO (install to disk) ──────────────────────────────────
build_from_iso() {
    local iso="$1"
    local qcow2="$DIST_DIR/codexos-lite-${ARCH}.qcow2"

    echo "==> Creating QCOW2 disk from ISO..."

    # Create a blank QCOW2 disk
    qemu-img create -f qcow2 "$qcow2" "$QCOW2_SIZE" >/dev/null

    # Boot from ISO and run a non-interactive install
    # We use the raw approach: create the image, partition it, and copy
    echo "    (Skipping automated ISO install — use raw image or manual install)"
    echo "    To install from ISO, boot with: qemu-system-$ARCH -cdrom $iso -drive file=$qcow2"
    echo ""
    echo "    Or use the raw image workflow instead."

    # Fallback: just create a reference
    echo "$qcow2"
}

# ── Boot in QEMU ─────────────────────────────────────────────────────────────
boot_qemu() {
    local disk="$1"
    local cdrom="${ISO_PATH:-}"

    echo "==> Starting QEMU ($ARCH, ${MEMORY}MB RAM)..."

    local qemu_bin
    local qemu_args=()

    case "$ARCH" in
        x86_64)
            qemu_bin="qemu-system-x86_64"
            qemu_args+=(
                -cpu qemu64
                -machine q35
                -smp 2
            )
            ;;
        aarch64)
            qemu_bin="qemu-system-aarch64"
            qemu_args+=(
                -cpu cortex-a57
                -machine virt
                -smp 2
            )
            ;;
        *)
            echo "Unsupported arch: $ARCH"
            exit 1
            ;;
    esac

    qemu_args+=(
        -m "$MEMORY"
        -drive "file=${disk},format=qcow2,if=virtio"
    )

    # Add ISO as CD-ROM if provided
    if [ -n "$cdrom" ]; then
        qemu_args+=(-cdrom "$cdrom")
    fi

    # Display options
    if $NO_GUI; then
        qemu_args+=(
            -nographic
            -serial mon:stdio
        )
    else
        qemu_args+=(
            -display gtk
            -serial stdio
        )
    fi

    # Enable KVM if available
    if [ -e /dev/kvm ] && [ -w /dev/kvm ]; then
        qemu_args+=(-enable-kvm)
        echo "    KVM acceleration: enabled"
    else
        echo "    KVM acceleration: not available (software emulation)"
    fi

    # User-mode networking with port forwarding for SSH
    qemu_args+=(
        -netdev user,id=net0,hostfwd=tcp::2222-:22
        -device virtio-net-pci,netdev=net0
    )

    echo "    Disk:    $disk"
    [ -n "$cdrom" ] && echo "    CD-ROM:  $cdrom"
    echo "    SSH:     localhost:2222"
    echo ""
    echo "==> Starting QEMU (Ctrl+A X to exit)..."

    exec "$qemu_bin" "${qemu_args[@]}"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    # Check for QEMU
    if ! command -v qemu-img >/dev/null 2>&1; then
        echo "ERROR: qemu-img not found. Install qemu-utils." >&2
        exit 1
    fi

    local disk=""

    if [ -n "$RAW_PATH" ] && [ -f "$RAW_PATH" ]; then
        disk="$(build_from_raw "$RAW_PATH")"
    elif [ -n "$ISO_PATH" ] && [ -f "$ISO_PATH" ]; then
        disk="$(build_from_iso "$ISO_PATH")"
    else
        echo "ERROR: No ISO or raw image found."
        echo "Build one first with: ./scripts/build-alpine.sh"
        exit 1
    fi

    if $BOOT && [ -n "$disk" ]; then
        boot_qemu "$disk"
    fi
}

main "$@"
