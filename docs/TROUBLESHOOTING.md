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

## `AssertionError: accum_timeout < _timeout in wait_for_ack`

```
[ERROR] [b200_radio_ctrl_core.cpp:65] [UHD] Exception caught in safe-call.
this->peek32(0); _async_task.reset(); -> AssertionError: accum_timeout < _timeout
  in wait_for_ack at ./host/lib/usrp/b200/b200_radio_ctrl_core.cpp:227
DSP loop terminated receiver_id=rx2 error=open SoapySDR device
```

The control channel between the host and the FPGA timed out. Once this happens
the device stays broken for every subsequent open, including plain
`uhd_usrp_probe` on the host.

### Cause

Forcing `master_clock_rate` in the SoapySDR device string:

```json
"device": "driver=uhd,type=b200,master_clock_rate=56000000"
```

Setting the master clock at device-open time wedges the B200 control core on
this board. Do not pass it. Let UHD derive the master clock from the sample
rate you request:

```json
"device": "driver=uhd,type=b200"
```

UHD then logs `Setting master clock rate selection to 'automatic'` and picks a
clock that matches `sps`, which works at every rate up to 56 MS/s.

### Recovery

Nothing short of a power cycle fixes it. Specifically, these do NOT work:

- `USBDEVFS_RESET` on the device node. It resets the USB link but does not cut
  VBUS, so the FX3 keeps its firmware in RAM and the FPGA keeps its
  configuration, bad state included.
- `uhd_image_loader --args="type=b200"`. It reloads the bitstream, and the
  device becomes visible to `uhd_find_devices` again, but a full open still
  fails.

**Unplug the USB cable and plug it back in.** Only removing power clears the
FX3 RAM and the FPGA configuration SRAM. You can tell it worked because the log
shows `Loading firmware image: ...usrp_b200_fw.hex` again, which never appears
after a mere link reset.

With root you can approximate a replug without touching the hardware:

```sh
sudo sh -c 'echo 0 > /sys/bus/usb/devices/2-8/authorized
            sleep 3
            echo 1 > /sys/bus/usb/devices/2-8/authorized'
```

Substitute the correct sysfs path, which `scripts/probe.sh` prints.

## Only one receiver may be enabled at a time

The B210 is a single device. Two receivers with `"enabled": true` open two
independent UHD sessions against it, and the second open renegotiates
`master_clock_rate` out from under the first. The symptom is a burst of `O`
overflow markers and a `D` right after startup, plus a second
`input opened receiver_id=...` line in the log.

Keep exactly one receiver enabled and point `active_receiver_id` at it. A
healthy startup logs `Skip disabled receiver` for every other profile.

## The UI says "connection to backend lost"

Check whether `limits.audio` is `0` in `config/config.json`.

The audio upgrade handler refuses a connection when
`total_audio_clients() >= limits.audio`, so a limit of zero makes `/audio`
return 429 to every client. The frontend opens `/audio` at startup and treats
the refusal as the whole backend being unreachable: it tears down the waterfall
and events sockets as well and reconnects in a loop. The logs show repeated
`waterfall ws disconnected` and `events ws disconnected` every few tens of
seconds.

Set `limits.audio` back to a normal value. Disabling audio to save CPU is not
worth it anyway: audio demodulation is per-client and on demand, so it costs
nothing while nobody is listening.


## The Bands menu looks empty

Two things surprise people here, and neither is a fault.

### Your bands are under "Other", not "Amateur (HAM)"

The Bands dropdown has three submenus and fills them like this:

```js
const ham = hamBandsForItuRegion(ituRegion);   // hardcoded in the frontend
for (const b of bands) {
  if (!inReceiverRange(b)) continue;
  if (/\bHAM\b/i.test(b.name)) continue;       // dropped, the list above covers these
  if (/\bAM\b/i.test(b.name)) broadcast.push(b);
  else other.push(b);
}
```

"Amateur (HAM)" never reads `config/overlays/bands.json` at all: it comes from
a band plan compiled into the frontend, chosen by ITU region. Worse, every
entry in your file whose name contains "HAM" is explicitly discarded.

"Broadcast (AM)" only takes entries with "AM" as a whole word in the name.

Everything else, which is most of a service band plan, lands in **"Other"**.
That submenu is only rendered when it is non-empty, so at a centre frequency
with nothing nearby you see just the two empty submenus and conclude the
feature is broken.

### Only bands inside the captured slice are listed

`inReceiverRange` keeps an entry when it overlaps `basefreq` to
`basefreq + total_bandwidth`. With a 56 MHz slice at 5.2 GHz that is four
entries; at 82-138 MHz it is eight. The rest of the file is still sent to the
browser, it is simply filtered out of the menu.

Bands also draw as coloured regions directly on the waterfall, which does not
go through this menu at all.

### It did not update after you edited the file

The band list reaches the browser inside the first text message of the
`/waterfall` WebSocket, sent once when that socket connects. The server
re-reads `bands.json` every 60 seconds, but a page that is already open keeps
whatever it was given at connect time.

Reload the page with Ctrl+Shift+R, or Cmd+Shift+R on macOS.

To check what the server is actually sending, without a browser:

```sh
python3 - <<'EOF'
import asyncio, json, websockets
async def main():
    async with websockets.connect("ws://127.0.0.1:9002/waterfall", max_size=None) as ws:
        d = json.loads(await ws.recv())
        print(d['receiver_name'], d['basefreq'], d['total_bandwidth'])
        print(len(json.loads(d['bands'])['bands']), 'bands')
asyncio.run(main())
EOF
```


## The audio stutters

The usual cause is not CPU or network. It is the audio passband being wider
than the server will allow, which makes it reject the tuning request outright.

In `ws/audio.rs`:

```rust
let audio_fft_size = rt.audio_max_fft_size as i32;
if r - l > audio_fft_size {
    return;          // window too wide: the request is dropped silently
}
```

and `audio_max_fft_size` comes from `config.rs`:

```
audio_max_fft_size = ceil(audio_sps * fft_size / sps / 4) * 4
```

Multiply that back out by the bin width (`sps / fft_size`) and the ceiling on
the audio passband is, to within one bin, simply **`audio_sps`**.

So with the default `audio_sps` of 12000 the widest passband is about 12 kHz,
whatever the sample rate or FFT size. A receiver whose default modulation is
`WBFM` asks for far more than that, the request is dropped, and the audio comes
out in fragments.

Check the startup log for the computed value:

```
active receiver runtime derived ... audio_max_fft_size=60
```

At 56 MS/s with `fft_size` 262144 each bin is 213.6 Hz, so 60 bins is 12.8 kHz.

### Fix

Raise `audio_sps` in `config/receivers.json`. 48000 is the Opus maximum:

```json
"audio_sps": 48000
```

That takes the same receiver to 228 bins, or 48.7 kHz.

### What this does not fix

48 kHz is the hard ceiling, and a broadcast FM channel occupies roughly
200 kHz. `WBFM` will therefore stay band limited no matter how you configure
it. This is not a misconfiguration: NovaSDR targets HF WebSDR use, where SSB,
AM and CW all fit in a few kHz and the limit never shows.

AM, NFM, SSB and CW all fit comfortably and sound clean. For a clean test,
tune an AM carrier in the airband rather than a broadcast FM station.

### If it still stutters

Look for the audio socket reconnecting in a loop:

```sh
docker compose logs --since 15m novasdr | grep -c 'audio ws connected'
```

Repeated connects a minute apart mean the browser is giving up and retrying.
Check for genuine overflows at the same time, counting the raw markers UHD
writes straight to stderr rather than the rate limited tracing message:

```sh
docker compose logs novasdr | tr -cd 'O' | wc -c
```

Take that count twice, a minute apart. The `RX overflow` WARN line is emitted
far less often than the markers and will understate the problem badly.


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
