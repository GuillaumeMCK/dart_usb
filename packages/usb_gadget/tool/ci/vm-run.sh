#!/usr/bin/env bash
#
# Runs a command as root in a virtme-ng VM booted with the kernel from
# build-kernel.sh, with dummy_hcd and the gadget function drivers loaded.
# The VM sees the host's filesystem, so build first on the host:
#
#   dart test test/models_test.dart              # runs the build hooks
#   tool/ci/vm-run.sh dart test test/gadget_test.dart
#
# The command runs in the current directory with the caller's PATH and HOME,
# so the build hooks find their cached output (changing either variable
# invalidates it) and the Rust toolchain.
#
# Adapted from surban/usb-gadget (.misc/cargo-test-runner.sh), Apache-2.0.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARBALL="${KERNEL_TARBALL:-$(ls -t "$SCRIPT_DIR"/kernel-*.tar.zst 2>/dev/null | head -1 || true)}"
if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
    echo "No kernel tarball; build one with $SCRIPT_DIR/build-kernel.sh" >&2
    exit 1
fi

STAGING="${KERNEL_STAGING:-/tmp/usb-gadget-vm}"
if [ ! -f "$STAGING/boot/bzImage" ]; then
    mkdir -p "$STAGING"
    tar -I zstd -xf "$TARBALL" -C "$STAGING"
fi

SCRIPT="$(mktemp /tmp/usb-gadget-vm.XXXXXX.sh)"
trap 'rm -f "$SCRIPT"' EXIT
{
    echo '#!/bin/bash'
    echo 'set -euo pipefail'
    for name in PATH HOME PUB_CACHE CARGO_HOME RUSTUP_HOME; do
        if [ -n "${!name:-}" ]; then printf 'export %s=%q\n' "$name" "${!name}"; fi
    done
    printf 'cd %q\n' "$PWD"
    cat <<'EOF'
modprobe libcomposite
modprobe dummy_hcd
for m in usb_f_fs usb_f_acm usb_f_serial usb_f_ecm usb_f_ncm usb_f_hid \
         usb_f_mass_storage usb_f_midi usb_f_printer; do
    modprobe "$m" 2>/dev/null || true
done
EOF
    printf 'exec'
    printf ' %q' "$@"
    echo
} > "$SCRIPT"
chmod +x "$SCRIPT"

exec vng \
    --run "$STAGING/boot/bzImage" \
    --rw \
    --user root \
    --cpus "${VM_CPUS:-$(nproc)}" \
    --memory "${VM_MEMORY:-4G}" \
    --exec "$SCRIPT"
