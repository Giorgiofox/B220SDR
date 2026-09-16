# Hardware notes: LibreSDR B220 Mini

Everything below was verified against the board in hand and against the UHD
and FPGA sources, not taken from vendor marketing copy.

## Identification

The board is a HamGeek / LibreSDR B220 Mini. It is a USRP B210 clone with a
different FPGA.

| Part | Component |
| --- | --- |
| FPGA | Xilinx Artix-7 `XC7A200T-FBG484-2` |
| RF transceiver | Analog Devices `AD9361` |
| USB bridge | Cypress `CYUSB3014-BZX` (FX3) |
| Connector | USB-C |
| RF ports | 4x SMA |

It enumerates with Ettus Research identifiers because its FX3 EEPROM is
programmed that way:

```
Bus 001 Device 006: ID 2500:0020 Ettus Research LLC USRP B210
```

This is why the host, UHD and every SDR application call it a B210. That is
expected and is what makes stock UHD work.

## The FPGA is the one thing that is not interchangeable

A genuine Ettus B210 carries a **Spartan-6 XC6SLX150**. This board carries an
**Artix-7 XC7A200T**. The bitstreams are not compatible in either direction.

`uhd_images_downloader` fetches the Ettus `usrp_b210_fpga.bin`, which cannot
configure this FPGA. It has to be replaced with a LibreSDR build.

You can verify which bitstream you have by reading the IDCODE that the Xilinx
configuration sequence writes near the start of the file:

```
$ xxd -p usrp_b210_fpga.bin | tr -d '\n' | grep -o -m1 -E '30018001[0-9a-f]{8}'
3001800103636093
```

`0x03636093` is the XC7A200T JTAG IDCODE. `scripts/probe.sh` performs this
check automatically.

Two bitstreams are shipped in `fpga/`:

| File | Origin | Size | sha256 (first 16) |
| --- | --- | --- | --- |
| `libresdr_b210_bkerler.bin` | [bkerler/LibreSDR_UHD_B220_Mini_FPGA](https://github.com/bkerler/LibreSDR_UHD_B220_Mini_FPGA), rebuilt with Vivado 2025.1 | 4660064 | `c503101c6c130fe4` |
| `libresdr_b210_vendor.bin` | vendor blob, mirrored by [NustyFrozen/LibreSDR-UHD-B220-Mini](https://github.com/NustyFrozen/LibreSDR-UHD-B220-Mini) | 4337612 | `7322a2a9052520c8` |

The bkerler image is the default because that repository ships the full Vivado
project, so the binary is reproducible. The vendor blob is kept as a fallback.
Note that in the NustyFrozen repository the `linux/` and `windows/` files are
byte-identical to each other despite the directory names.

## Why stock UHD works

UHD accepts the LibreSDR because the FPGA reports the compatibility number
that the B200 driver expects.

In the FPGA sources, `lib/esdr_b210/top/b200_core.v`:

```verilog
localparam COMPAT_MAJOR = 16'h0010;   // 16
localparam COMPAT_MINOR = 16'h0000;
```

In UHD, `host/lib/usrp/b200/b200_impl.hpp`:

```cpp
static const uint8_t  B200_FW_COMPAT_NUM_MAJOR = 8;
static const uint8_t  B200_FW_COMPAT_NUM_MINOR = 0;
static const uint16_t B200_FPGA_COMPAT_NUM     = 16;
```

The value is 16 in UHD 4.6.0.0, 4.7.0.0 and 4.8.0.0, so no patched UHD and no
custom driver is needed. Ubuntu 24.04 ships 4.6.0.0, which is what this
project targets.

## "Flashing" is not permanent

There is no persistent firmware to write. On every connection:

1. UHD pushes `usrp_b200_fw.hex` into the FX3 over USB. The board then
   re-enumerates with real endpoints.
2. On the first device open, UHD pushes `usrp_b210_fpga.bin` into the FPGA.

Both are volatile. The only non-volatile part is the FX3 EEPROM, which holds
the USB vendor/product ID and the serial number, and which ships already
programmed. `b2xx_fx3_utils` is only needed if that EEPROM is corrupted.

So "installing the LibreSDR firmware" reduces to putting the right
`usrp_b210_fpga.bin` where UHD looks for it.

### Where to put the bitstream

Do not leave it at `/usr/share/uhd/images/usrp_b210_fpga.bin` and forget about
it: the next `uhd_images_downloader` run overwrites it. Either keep a backup
(which `scripts/host-setup.sh` does, as `usrp_b210_fpga.bin.ettus-orig`), or
point UHD at an explicit path per serial number in `~/.config/uhd.conf` or
`/etc/uhd/uhd.conf`:

```ini
[serial=YOURSERIAL]
fpga=/opt/libresdr/usrp_b210_fpga.bin
```

`fpga/uhd.conf.example` contains a template. Read the real serial with
`uhd_usrp_probe` after the firmware has loaded.

## Bandwidth and sample rate

| Property | Value |
| --- | --- |
| Tuning range | 70 MHz - 6 GHz |
| Maximum sample rate | 61.44 MS/s |
| Maximum analog RF bandwidth | 56 MHz |
| Channels | 2x2 MIMO (AD9361) |

The 70 MHz figure is the **lower tuning limit**, not a bandwidth. The widest
slice of spectrum you can put on a waterfall at once is 56 MHz.

Bus load at full rate, single channel:

| Wire format | Bytes/sample | Rate at 61.44 MS/s |
| --- | --- | --- |
| `sc16` (default) | 4 | 245 MB/s |
| `sc8` | 2 | 123 MB/s |

USB 2.0 tops out around 35-40 MB/s in practice, which caps you at roughly
8 MS/s. USB 3.0 is mandatory for anything wider. Receiver `rx2` in
`config/receivers.json` uses `WIRE=sc8` to halve the bus load at full rate, at
the cost of dynamic range.

## Reading the USB state correctly

Before the FX3 firmware is loaded, the board looks like this:

```
speed        : 480 Mbit/s
bcdUSB       : 2.00
manufacturer : Cypress
product      : WestBridge
endpoints    : 0
```

The FX3 boot ROM only enumerates at High Speed. **A 480 Mbit/s reading in this
state tells you nothing about your cable or your port.** Judge the link only
after the firmware has loaded and the board has re-enumerated, at which point a
SuperSpeed link moves the device onto the USB 3.0 root hub (a separate bus
number, typically `usb2` on a single-controller machine).

If it stays at 480 Mbit/s after re-enumeration, the usual causes, in order:

1. A USB-C cable wired for USB 2.0 only. Very common, including cables bundled
   with the board. A charge-only or "data" USB-C cable without the SuperSpeed
   pairs will never exceed 480 Mbit/s.
2. A USB 2.0 port. On desktops the rear ports are often mixed.
3. An intermediate USB 2.0 hub.

## Power

The board draws a meaningful amount of current over USB. Bus-powered operation
from an unpowered hub is a common source of intermittent resets and `S` or `U`
sequences in UHD logs. Use a direct port on the machine.

## References

- [bkerler/LibreSDR_UHD_B220_Mini_FPGA](https://github.com/bkerler/LibreSDR_UHD_B220_Mini_FPGA) - FPGA sources and bitstream
- [NustyFrozen/LibreSDR-UHD-B220-Mini](https://github.com/NustyFrozen/LibreSDR-UHD-B220-Mini) - vendor bitstream mirror, documentation PDFs
- [EttusResearch/uhd](https://github.com/EttusResearch/uhd) - UHD
- `fpga/miniRev0.pdf` - board schematic
- `fpga/Quick Start.pdf` - vendor quick start guide
