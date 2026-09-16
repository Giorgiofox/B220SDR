#!/usr/bin/env bash
#
# Host preparation for the LibreSDR B220 Mini on Linux.
#
# Run this once on the machine the SDR is plugged into. It is safe to re-run.
#
# What it does:
#   1. installs UHD host tools and the SoapySDR UHD module
#   2. downloads the Ettus B2xx images (the FX3 firmware is the part we need)
#   3. replaces the B210 FPGA bitstream with the LibreSDR one
#   4. applies the udev rules so the device is reachable without root
#
# The container image carries its own copy of everything in steps 2 and 3, so
# this script is only required if you also want to use the SDR from the host
# (uhd_usrp_probe, GNU Radio, SDR++, ...).

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FPGA_BIN="${FPGA_BIN:-$REPO_DIR/fpga/libresdr_b210_bkerler.bin}"
IMAGES_DIR="${UHD_IMAGES_DIR:-/usr/share/uhd/images}"

log()  { printf '[host-setup] %s\n' "$*"; }
fail() { printf '[host-setup] ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$FPGA_BIN" ] || fail "FPGA bitstream not found: $FPGA_BIN"

if [ "$(id -u)" -ne 0 ]; then
    fail "must run as root (use: sudo $0)"
fi

# --- 1. packages ------------------------------------------------------------
if ! command -v uhd_find_devices >/dev/null 2>&1; then
    log "installing UHD and SoapySDR packages"
    apt-get update
    apt-get install -y --no-install-recommends \
        uhd-host libuhd-dev python3-uhd \
        soapysdr-tools soapysdr0.8-module-uhd
else
    log "UHD already present: $(uhd_config_info --version)"
fi

# --- 2. Ettus images --------------------------------------------------------
# usrp_b200_fw.hex is the Cypress FX3 firmware. The LibreSDR uses the same FX3
# as a genuine B2xx, so the stock Ettus firmware is correct.
log "downloading B2xx images into $IMAGES_DIR"
uhd_images_downloader -t b2xx -i "$IMAGES_DIR"

# --- 3. FPGA bitstream ------------------------------------------------------
# A genuine B210 has a Spartan-6 XC6SLX150. The LibreSDR B220 Mini has an
# Artix-7 XC7A200T (IDCODE 0x03636093). The Ettus bitstream cannot configure
# it, so it has to be replaced.
if [ -f "$IMAGES_DIR/usrp_b210_fpga.bin" ] \
   && [ ! -f "$IMAGES_DIR/usrp_b210_fpga.bin.ettus-orig" ]; then
    log "backing up the Ettus bitstream"
    mv "$IMAGES_DIR/usrp_b210_fpga.bin" "$IMAGES_DIR/usrp_b210_fpga.bin.ettus-orig"
fi

log "installing the LibreSDR bitstream as usrp_b210_fpga.bin"
install -m 0644 "$FPGA_BIN" "$IMAGES_DIR/usrp_b210_fpga.bin"

# --- 4. udev ----------------------------------------------------------------
# uhd-host ships /lib/udev/rules.d/60-uhd-host.rules, which sets MODE 0666 on
# vendor 2500. Rules are not applied retroactively, so a device that was
# already plugged in when UHD was installed keeps its original root-only
# permissions until the rules are re-triggered.
log "reloading udev rules"
udevadm control --reload-rules
# --action=add matters. The default action for `udevadm trigger` is `change`,
# which does not reliably re-apply a MODE:= assignment to an existing device
# node. Replaying an `add` event does.
udevadm trigger --action=add --subsystem-match=usb --attr-match=idVendor=2500
udevadm settle

for dev in /sys/bus/usb/devices/*-*; do
    [ -r "$dev/idVendor" ] || continue
    [ "$(cat "$dev/idVendor")" = "2500" ] || continue
    node="/dev/bus/usb/$(printf %03d "$(cat "$dev/busnum")")/$(printf %03d "$(cat "$dev/devnum")")"
    log "device node $node is now $(stat -c '%A %U:%G' "$node")"
done

log "done"
log ""
log "Verify with:  uhd_find_devices"
log "If it still reports 'insufficient permissions', unplug and replug the USB cable."
