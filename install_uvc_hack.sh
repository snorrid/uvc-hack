#!/bin/bash
#
# Builds a patched uvcvideo kernel module that caps dwMaxPayloadTransferSize for
# compressed (MJPEG) formats, so more USB cameras can stream on one bus.
#
# The patched module is installed to /lib/modules/<kver>/updates/, which takes
# priority over the distro module without modifying it.
#
# Usage:
#   install_uvc_hack.sh              build and install the patched driver
#   install_uvc_hack.sh --uninstall  remove it and go back to the stock driver
#
# Environment:
#   UVC_PAYLOAD_SIZE   payload size to force for compressed formats (default 0x300)

set -euo pipefail

PAYLOAD_SIZE="${UVC_PAYLOAD_SIZE:-0x300}"
UVC_FILES="Kconfig Makefile uvc_ctrl.c uvc_debugfs.c uvc_driver.c uvc_entity.c uvc_isight.c
           uvc_metadata.c uvc_queue.c uvc_status.c uvc_v4l2.c uvc_video.c uvcvideo.h"

info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

if [ "$(uname)" != "Linux" ]; then
    die "Platform is not 'Linux', and hence is not supported by this script."
fi

[[ "$PAYLOAD_SIZE" =~ ^(0x[0-9a-fA-F]+|[0-9]+)$ ]] || die "UVC_PAYLOAD_SIZE must be a decimal or 0x-prefixed hex number."

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

KVER="$(uname -r)"
MODDIR="/lib/modules/$KVER"
STOCK_DIR="$MODDIR/kernel/drivers/media/usb/uvc"
INSTALL_DIR="$MODDIR/updates/uvc"
INSTALLED_KO="$INSTALL_DIR/uvcvideo.ko"

# Undo what older versions of this script did: they overwrote the stock
# uvcvideo.ko in place (keeping a .bak), or, on systems with compressed modules,
# dropped a stray uvcvideo.ko next to uvcvideo.ko.{zst,xz,gz}.
cleanup_legacy_install() {
    if [ -f "$STOCK_DIR/uvcvideo.ko.bak" ]; then
        info "Restoring stock driver replaced by an older version of this script"
        $SUDO mv -f "$STOCK_DIR/uvcvideo.ko.bak" "$STOCK_DIR/uvcvideo.ko"
    elif [ -f "$STOCK_DIR/uvcvideo.ko" ] && compgen -G "$STOCK_DIR/uvcvideo.ko.*" > /dev/null; then
        info "Removing stray uvcvideo.ko left by an older version of this script"
        $SUDO rm -f "$STOCK_DIR/uvcvideo.ko"
    fi
}

# Reload uvcvideo so the module selected by depmod takes effect. The autodarts
# service holds the cameras open, so stop it for the duration of the reload.
reload_driver() {
    local restart_autodarts=false
    if command -v systemctl > /dev/null && systemctl is-active --quiet autodarts 2> /dev/null; then
        info "Stopping autodarts service"
        $SUDO systemctl stop autodarts
        restart_autodarts=true
    fi

    info "Reloading uvc driver"
    if [ -d /sys/module/uvcvideo ] && ! $SUDO modprobe -r uvcvideo; then
        warn "Could not unload uvcvideo (a camera is probably in use)."
        warn "The new driver will be used after a reboot."
    else
        $SUDO modprobe uvcvideo
    fi

    if $restart_autodarts; then
        info "Starting autodarts service"
        $SUDO systemctl start autodarts
    fi
}

if [[ "${1:-}" == "--uninstall" ]]; then
    if [ ! -f "$INSTALLED_KO" ] && [ ! -f "$STOCK_DIR/uvcvideo.ko.bak" ]; then
        die "UVC hack does not seem to be installed for kernel $KVER."
    fi
    info "Removing patched uvc driver"
    $SUDO rm -f "$INSTALLED_KO"
    $SUDO rmdir "$INSTALL_DIR" 2> /dev/null || true
    cleanup_legacy_install
    $SUDO depmod -a "$KVER"
    reload_driver
    info "Done"
    exit 0
fi

if command -v mokutil > /dev/null && mokutil --sb-state 2> /dev/null | grep -q "SecureBoot enabled"; then
    die "Secure Boot is enabled, so the kernel will refuse to load an unsigned module. Disable Secure Boot or sign the module yourself."
fi

info "Checking build dependencies"
missing=()
command -v curl > /dev/null || missing+=(curl)
command -v perl > /dev/null || missing+=(perl)
{ command -v make > /dev/null && command -v gcc > /dev/null; } || missing+=(build-essential)
if [ ${#missing[@]} -gt 0 ] || [ ! -e "$MODDIR/build/Makefile" ]; then
    command -v apt-get > /dev/null \
        || die "Missing dependencies (${missing[*]:-kernel headers}) and apt-get is not available. Install them manually."
    $SUDO apt-get update
    if [ ${#missing[@]} -gt 0 ]; then
        $SUDO apt-get install -y "${missing[@]}"
    fi
    if [ ! -e "$MODDIR/build/Makefile" ]; then
        # Raspberry Pi OS before Bookworm only ships the meta package.
        $SUDO apt-get install -y "linux-headers-$KVER" \
            || $SUDO apt-get install -y raspberrypi-kernel-headers \
            || true
    fi
fi
[ -e "$MODDIR/build/Makefile" ] || die "Kernel headers for $KVER are not installed and could not be installed automatically."

KMAJMIN="$(echo "$KVER" | cut -d. -f1,2)"
if command -v odroid-tweaks > /dev/null; then
    SRC_URL="https://raw.githubusercontent.com/hardkernel/linux/$KVER/drivers/media/usb/uvc"
else
    SRC_URL="https://raw.githubusercontent.com/torvalds/linux/v$KMAJMIN/drivers/media/usb/uvc"
    # Raspberry Pi OS kernels (e.g. 6.12.47+rpt-rpi-v8) come from the raspberrypi fork.
    if [[ "$KVER" == *rpi* ]]; then
        RPI_URL="https://raw.githubusercontent.com/raspberrypi/linux/rpi-$KMAJMIN.y/drivers/media/usb/uvc"
        if curl -fsIL -o /dev/null "$RPI_URL/uvc_video.c"; then
            SRC_URL="$RPI_URL"
        fi
    fi
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

info "Downloading uvc driver source from $SRC_URL"
for f in $UVC_FILES; do
    curl -fsSL --retry 3 -o "$f" "$SRC_URL/$f" || die "Failed to download $SRC_URL/$f"
done

info "Applying code patch (dwMaxPayloadTransferSize = $PAYLOAD_SIZE)"
# Append the override as the last statement of uvc_fixup_video_ctrl(), so it
# wins over any bandwidth fixups the kernel applies before it.
perl -0pi -e "s/(\nstatic void uvc_fixup_video_ctrl\(.*?)\n}\n/\$1\n\tif (format->flags & UVC_FMT_FLAG_COMPRESSED)\n\t\tctrl->dwMaxPayloadTransferSize = $PAYLOAD_SIZE;\n}\n/s" uvc_video.c
grep -qF "ctrl->dwMaxPayloadTransferSize = $PAYLOAD_SIZE;" uvc_video.c \
    || die "Patch did not apply; the uvc source for this kernel has changed. Nothing was installed."

info "Compiling new uvc driver"
make -C "$MODDIR/build" M="$WORKDIR" modules
[ -f uvcvideo.ko ] || die "Build finished but uvcvideo.ko was not produced."

cleanup_legacy_install

info "Installing patched driver to $INSTALLED_KO"
$SUDO install -D -m 644 uvcvideo.ko "$INSTALLED_KO"
$SUDO depmod -a "$KVER"

if [ "$(modinfo -k "$KVER" -n uvcvideo 2> /dev/null)" != "$INSTALLED_KO" ]; then
    warn "modprobe resolves uvcvideo to '$(modinfo -k "$KVER" -n uvcvideo 2> /dev/null)' instead of the patched driver."
fi

reload_driver

info "Done"
echo "Note: the patched driver only applies to kernel $KVER. Re-run this script after every kernel upgrade."
