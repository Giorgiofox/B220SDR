# Troubleshooting

## `USB open failed: insufficient permissions`

```
[ERROR] [USB] USB open failed: insufficient permissions.
No UHD Devices Found
```

The udev rule that grants access exists but was not applied to the device.
`uhd-host` installs `/lib/udev/rules.d/60-uhd-host.rules`, which sets
`MODE:="0666"` on vendor `2500`. udev does not apply rules retroactively, so a
device that was already plugged in when UHD was installed keeps its original
`root:root 0664` node.

Fix:

```sh
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=usb --attr-match=idVendor=2500
```

Or just unplug and replug the cable.

Check it worked:

```sh
ls -la /dev/bus/usb/001/*        # the node should be crw-rw-rw-
```

## `No UHD Devices Found`, no permission error

Check the board is on the bus at all:

```sh
lsusb -d 2500:
```

Nothing listed means it is a power or cable problem, not software. Try another
port, directly on the machine rather than through a hub.

## `Could not find the FPGA image` or the device opens then disappears

UHD cannot locate `usrp_b210_fpga.bin`, or found the wrong one.

```sh
scripts/probe.sh
```

Look at the `FPGA bitstream target` section. It must report:

```
IDCODE 0x03636093 -> XC7A200T (LibreSDR B220, correct)
```

Anything else means the Ettus bitstream is in place. That image is a Spartan-6
bitstream and cannot configure this board's Artix-7. Re-run
`sudo scripts/host-setup.sh`, or copy `fpga/libresdr_b210_bkerler.bin` over
`usrp_b210_fpga.bin` in your UHD images directory.

This is also what happens after any `uhd_images_downloader` run: it restores the
Ettus image and silently undoes the fix. See `docs/HARDWARE.md` for how to pin
the path in `uhd.conf` instead.

## The device stays at 480 Mbit/s

First confirm the firmware actually loaded. Run `scripts/probe.sh` and look at
the `USB link state` section:

```
manufacturer : Cypress
product      : WestBridge
state        : FX3 bootloader, firmware NOT loaded yet
```

In this state the FX3 boot ROM only speaks High Speed, so 480 Mbit/s is
expected and means nothing. Run `uhd_find_devices` once to push the firmware,
then re-check.

If it is still 480 Mbit/s after the firmware has loaded:

1. **The cable.** By far the most common cause. A USB-C cable without the
   SuperSpeed pairs is electrically a USB 2.0 cable. Cables bundled with SDR
   boards are frequently USB 2.0 only. Try a cable known to carry USB 3 data,
   for example one sold with an external SSD.
2. **The port.** Verify the port itself is USB 3:
   ```sh
   lsusb -t                       # look for 5000M or 10000M root hubs
   ls /sys/bus/usb/devices/usb*/speed
   ```
3. **A hub.** Any USB 2.0 hub in the path caps the whole chain.

A SuperSpeed link shows up as a different bus number, because the USB 2 and
USB 3 halves of one physical connector are exposed as separate root hubs.

Consequence of staying on USB 2.0: about 8 MS/s maximum, so receiver `rx1` and
`rx2` in `config/receivers.json` will not run. Use `rx0`.

## UHD prints a stream of `O` characters

`O` is an overflow: the host is not draining the USB buffers fast enough. In
NovaSDR's logs this shows up as dropped samples and a stuttering waterfall.

In order of effectiveness:

1. Lower `sps` in `config/receivers.json`.
2. Lower `fft_size`. FFT execution dominates CPU usage.
3. Raise `num_recv_frames` in `stream_args` to give UHD more buffering.
4. Set `"WIRE": "sc8"` in `stream_args` to halve the bus load.
5. Build with an FFT accelerator, see below.

`D` instead means packets were dropped on the bus itself, which points at the
USB link rather than at CPU load.

## High CPU usage

FFT cost scales with `sps` and `fft_size`; per-client cost scales with the
number of connected listeners. A CPU-only build is the default.

To use OpenCL:

```sh
NOVASDR_FEATURES="soapysdr,clfft" docker compose up -d --build
```

This needs an OpenCL ICD inside the container. For Intel integrated graphics
add `intel-opencl-icd` to the runtime stage of the `Dockerfile` and pass
`/dev/dri` through in `docker-compose.yml`.

Then set the accelerator in `config/receivers.json`:

```json
"accelerator": "clfft"
```

`vkfft` (Vulkan) is the other option and is Linux only. It needs
`libvulkan-dev`, `glslang-dev`, `spirv-tools` and `libvkfft-dev` in the build
stage plus `mesa-vulkan-drivers` in the runtime stage.

Neither is worth setting up until you have confirmed a CPU-only build is
actually the bottleneck.

## The web UI loads but the waterfall is empty

Check the server actually opened the device:

```sh
docker compose logs -f novasdr
```

A successful start logs the UHD banner, the detected motherboard and the
negotiated sample rate. If it reports the requested rate was coerced to
something else, UHD quantised it: the B210 can only produce
`master_clock_rate / N`, so ask for a rate that divides cleanly.

If the device opened but the spectrum is flat noise at the very bottom of the
scale, it is an RF problem, not a software one. Check:

- an antenna is actually connected to the SMA port named in `antenna`
  (`RX2` by default, the board has four ports)
- `gain` is not 0 (range is 0-76 dB, 40 is a reasonable start)
- the tuned frequency has something to hear. 100 MHz with `WBFM` should show
  broadcast FM carriers almost anywhere.

Run `scripts/rx-test.sh` to separate the two cases: it reports mean power in
dBFS and warns when the signal is essentially zero.

## `docker compose build` runs out of disk

The build pulls a Rust toolchain and a Node toolchain and compiles NovaSDR from
source. Budget several GB.

```sh
df -h /var/lib/docker
docker system df
```

Reclaim space carefully. `docker image prune -a` removes every image not used
by an existing container, which on a machine with other stacks on it may mean
re-pulling a lot. Inspect first:

```sh
docker system df -v
```

## Port 9002 already in use

```sh
NOVASDR_PORT=9010 docker compose up -d
```

Or set `NOVASDR_PORT` in `.env`.
