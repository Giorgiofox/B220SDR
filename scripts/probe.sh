#!/usr/bin/env bash
#
# Identify the LibreSDR B220 Mini and report what state it is in.
#
# Loading the FX3 firmware is a side effect of probing: UHD pushes
# usrp_b200_fw.hex over USB, the board re-enumerates, and only then does it
# expose real endpoints. Before that it appears as a bare Cypress FX3.
#
# Usage:
#   scripts/probe.sh            run on the host
#   scripts/probe.sh --docker   run inside the novasdr-b220 container

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${1:-}" = "--docker" ]; then
    exec docker compose -f "$REPO_DIR/docker-compose.yml" \
        run --rm --entrypoint /bin/bash novasdr -c "$(cat "${BASH_SOURCE[0]}")"
fi

# Fall back to a repo-local image directory when UHD is not installed
# system-wide (see scripts/host-setup.sh).
if [ -z "${UHD_IMAGES_DIR:-}" ] && [ -d "$REPO_DIR/uhd-images" ]; then
    export UHD_IMAGES_DIR="$REPO_DIR/uhd-images"
fi

rule() { printf '\n=== %s ===\n' "$1"; }

rule "USB enumeration"
lsusb -d 2500: || echo "no Ettus/LibreSDR device on the USB bus"

rule "USB link state"
for dev in /sys/bus/usb/devices/*-*; do
    [ -r "$dev/idVendor" ] || continue
    [ "$(cat "$dev/idVendor")" = "2500" ] || continue
    printf '  path       : %s\n' "$dev"
    printf '  speed      : %s Mbit/s\n' "$(cat "$dev/speed")"
    printf '  bcdUSB     : %s\n' "$(cat "$dev/version" | tr -d ' ')"
    printf '  manufacturer: %s\n' "$(cat "$dev/manufacturer" 2>/dev/null)"
    printf '  product    : %s\n' "$(cat "$dev/product" 2>/dev/null)"
    printf '  serial     : %s\n' "$(cat "$dev/serial" 2>/dev/null)"

    # An FX3 that has not been given its firmware yet reports itself as a
    # Cypress WestBridge with zero endpoints and bcdUSB 2.00. In that state it
    # cannot negotiate SuperSpeed, so a 480 Mbit/s reading here says nothing
    # about the cable or the port.
    if [ "$(cat "$dev/manufacturer" 2>/dev/null)" = "Cypress" ]; then
        echo "  state      : FX3 bootloader, firmware NOT loaded yet"
    else
        echo "  state      : firmware loaded"
    fi
done

rule "UHD images in use"
echo "  UHD_IMAGES_DIR=${UHD_IMAGES_DIR:-<default>}"
for f in usrp_b200_fw.hex usrp_b210_fpga.bin; do
    p="${UHD_IMAGES_DIR:-/usr/share/uhd/images}/$f"
    if [ -f "$p" ]; then
        printf '  %-22s %10d bytes  sha256=%s\n' "$f" \
            "$(stat -c%s "$p")" "$(sha256sum "$p" | cut -c1-16)"
    else
        printf '  %-22s MISSING\n' "$f"
    fi
done

rule "FPGA bitstream target"
# Bytes 0x30.. carry the Xilinx sync word followed by the IDCODE write.
# 0x03636093 is XC7A200T (LibreSDR). A genuine B210 image would not match,
# it is a Spartan-6 bitstream.
bit="${UHD_IMAGES_DIR:-/usr/share/uhd/images}/usrp_b210_fpga.bin"
if [ -f "$bit" ]; then
    idcode=$(xxd -p "$bit" | tr -d '\n' | grep -o -m1 -E '30018001[0-9a-f]{8}' | tail -c 9)
    case "$idcode" in
        03636093) echo "  IDCODE 0x$idcode -> XC7A200T (LibreSDR B220, correct)" ;;
        "")       echo "  no IDCODE found, this is probably not an Artix-7 bitstream" ;;
        *)        echo "  IDCODE 0x$idcode -> NOT XC7A200T, wrong bitstream for this board" ;;
    esac
fi

rule "uhd_find_devices"
uhd_find_devices 2>&1

rule "uhd_usrp_probe"
uhd_usrp_probe --init-only 2>&1 | tail -40

rule "SoapySDR"
SoapySDRUtil --probe="driver=uhd" 2>&1 | head -40
