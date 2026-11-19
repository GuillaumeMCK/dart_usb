#!/usr/bin/env bash
#
# Builds a kernel and its modules for the end-to-end tests, packaged as
# kernel-<version>.tar.zst next to this script, for vm-run.sh.
#
# Needs virtme-ng, zstd and the usual kernel build tools.
#
#   tool/ci/build-kernel.sh [--kernel-version VERSION]
#
# Adapted from surban/usb-gadget (.misc/build-kernel.sh), Apache-2.0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_VERSION="7.2.10"
WORK_DIR="/tmp/usb-gadget-kernel"

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel-version|-k) KERNEL_VERSION="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 64 ;;
    esac
done

OUTPUT="$SCRIPT_DIR/kernel-$KERNEL_VERSION.tar.zst"
KERNEL_SRC="$WORK_DIR/linux-$KERNEL_VERSION"
mkdir -p "$WORK_DIR"

if [ ! -d "$KERNEL_SRC" ]; then
    curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/linux-$KERNEL_VERSION.tar.xz" |
        tar xJ -C "$WORK_DIR"
fi

cd "$KERNEL_SRC"
vng --build --config "$SCRIPT_DIR/usb-gadget.config" --force

missing=0
for sym in CONFIGFS_FS USB_GADGET USB_DUMMY_HCD USB_CONFIGFS USB_LIBCOMPOSITE \
           USB_F_FS USB_F_ACM USB_F_ECM USB_F_HID USB_F_MASS_STORAGE; do
    if ! grep -q "CONFIG_${sym}=[ym]" .config; then
        echo "missing CONFIG_$sym" >&2
        missing=1
    fi
done
[ "$missing" = 0 ] || exit 1

STAGING="$WORK_DIR/staging"
rm -rf "$STAGING"
mkdir -p "$STAGING/boot"
make modules_install INSTALL_MOD_PATH="$STAGING" >/dev/null
release="$(ls "$STAGING/lib/modules")"
# These point into the build tree.
rm -f "$STAGING/lib/modules/$release/source" "$STAGING/lib/modules/$release/build"
cp arch/x86/boot/bzImage "$STAGING/boot/bzImage"

tar cf - -C "$STAGING" boot lib | zstd -12 -T0 -q -f -o "$OUTPUT"
echo "Built $OUTPUT ($release)"
