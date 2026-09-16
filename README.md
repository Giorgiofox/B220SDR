# B220SDR

A ready-to-run [NovaSDR](https://github.com/phasor-labs/NovaSDR) web SDR
package for the **LibreSDR B220 Mini** (HamGeek XC7A200T + AD9361), the
Artix-7 based USRP B210 clone.

It gives you a browser interface with a real-time waterfall, tuning, and
AM / SAM / FM / WBFM / USB / LSB demodulation, served to as many simultaneous
listeners as your CPU can handle.

The package exists because the B220 needs one thing the stock UHD distribution
does not provide: an FPGA bitstream built for its Artix-7. Everything else is
plain UHD.

---

## What is in here

```
Dockerfile               NovaSDR + UHD 4.6 + SoapyUHD + the LibreSDR bitstream
docker-compose.yml       Linux deployment, USB passthrough
config/
  config.json            server, limits, which receiver is active
  receivers.json         three ready-made receiver profiles for the B220
fpga/
  libresdr_b210_bkerler.bin   FPGA bitstream (default)
  libresdr_b210_vendor.bin    FPGA bitstream (vendor fallback)
  uhd.conf.example            per-serial bitstream pinning
  miniRev0.pdf                board schematic
  Quick Start.pdf             vendor guide
scripts/
  host-setup.sh          one-shot host preparation (Linux, needs root)
  probe.sh               identify the board and report its exact state
  rx-test.sh             receive-only smoke test, no web UI involved
docs/
  HARDWARE.md            what this board is and why stock UHD works
  MACOS.md               running on a Mac, and why Docker will not do it
  TROUBLESHOOTING.md     symptom to cause to fix
```

---

## Requirements

- **Linux** for the Docker path. Docker Desktop on macOS and Windows cannot
  pass USB devices into containers, so the compose file will not see the SDR
  there. See [docs/MACOS.md](docs/MACOS.md).
- Docker with the Compose plugin.
- Several GB of free disk for the build. It compiles NovaSDR from source and
  builds the frontend.
- **USB 3.0** for anything above roughly 8 MS/s.

---

## Quick start

```sh
git clone https://github.com/Giorgiofox/B220SDR.git
cd B220SDR
```

### 1. Prepare the host

```sh
sudo scripts/host-setup.sh
```

This installs UHD, downloads the Ettus B2xx images, replaces the B210 FPGA
bitstream with the LibreSDR one, and applies the udev rules.

The container carries its own copy of the images and the bitstream, so this
step is strictly needed only for the udev rules. Run it anyway if you also want
to use the board from the host with `uhd_usrp_probe`, GNU Radio or SDR++.

### 2. Confirm the board is alive

```sh
scripts/probe.sh
```

Expected on a healthy setup:

```
=== USB link state ===
  speed      : 5000 Mbit/s
  state      : firmware loaded

=== FPGA bitstream target ===
  IDCODE 0x03636093 -> XC7A200T (LibreSDR B220, correct)

=== uhd_find_devices ===
  Device Address:
      serial: ...
      product: B210
      type: b200
```

If it reports `insufficient permissions`, or the board still identifies as a
Cypress WestBridge, go to [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

### 3. Check it actually receives

```sh
scripts/rx-test.sh 100000000 8000000 5
```

Streams 5 seconds at 8 MS/s centred on 100 MHz and reports the achieved
throughput, the overflow count and the mean signal power. This isolates
hardware problems from NovaSDR problems.

### 4. Start the web SDR

```sh
docker compose up -d --build
```

The first build takes a while. Then open <http://localhost:9002>.

```sh
docker compose logs -f novasdr
```

---

## Receiver profiles

`config/receivers.json` ships three profiles. Pick one with
`active_receiver_id` in `config/config.json` and set `enabled` accordingly.

| id | Sample rate | Spectrum shown | FFT size | Requires |
| --- | --- | --- | --- | --- |
| `rx0` | 8 MS/s | 8 MHz | 65536 | works on USB 2.0 |
| `rx1` | 32 MS/s | 32 MHz | 131072 | USB 3.0 |
| `rx2` | 61.44 MS/s | 56 MHz (analog limit) | 262144 | USB 3.0, strong CPU |

`rx0` is active by default because it is the profile that works everywhere.

Start there, confirm it is clean, then move up. Watch the logs for overflows
when you do.

`rx2` uses `"WIRE": "sc8"` to halve the USB load, trading dynamic range for
throughput. At 61.44 MS/s an `sc16` stream is 245 MB/s, which is close enough
to the practical USB 3.0 ceiling to cause trouble.

### Changing frequency and gain

Edit the active receiver in `config/receivers.json`:

```json
"frequency": 100000000,
"driver": {
  "antenna": "RX2",
  "gain": 40.0
}
```

- `frequency` is the **centre** of the captured spectrum, in Hz. Tuning range
  is 70 MHz to 6 GHz.
- `gain` range is 0 to 76 dB. 40 is a sensible start.
- `antenna` is `RX2` or `TX/RX`. The board has four SMA ports.

Listeners then tune anywhere inside the captured span from the browser, each
with their own frequency and modulation, independently of each other.

Restart after editing:

```sh
docker compose restart novasdr
```

---

## Configuration reference

### Environment variables

Copy `.env.example` to `.env` to override any of these.

| Variable | Default | Meaning |
| --- | --- | --- |
| `NOVASDR_PORT` | `9002` | Host port for the web UI |
| `NOVASDR_BIND` | `0.0.0.0` | Host interface to bind. Use `127.0.0.1` to keep it local |
| `NOVASDR_FEATURES` | `soapysdr` | Cargo features. Add `clfft` or `vkfft` for GPU FFT |
| `NOVASDR_REF` | pinned commit | NovaSDR commit to build |
| `NOVASDR_MEM_LIMIT` | `4G` | Container memory limit |
| `RUST_LOG` | `info` | Log verbosity |

### Exposing it publicly

The default binds to every interface. NovaSDR has no authentication. If you put
it on a public address, put a reverse proxy with TLS in front of it and forward
the `Upgrade` and `Connection` headers, otherwise the WebSockets will not
connect. Raise the proxy timeouts too, the sockets are long-lived.

To keep it local only:

```sh
NOVASDR_BIND=127.0.0.1 docker compose up -d
```

---

## Transmit

This package is receive-only by design. The AD9361 on this board can transmit,
and UHD exposes that, but NovaSDR does not.

If you add transmit capability yourself: transmitting on most of the 70 MHz to
6 GHz range requires an amateur radio licence or another form of authorisation,
and the rules differ by country. A shielded enclosure or a dummy load with
proper attenuation is the right way to test.

---

## Hardware background

The short version:

- The board is a USRP B210 clone with an **Artix-7 XC7A200T**, not the
  **Spartan-6 XC6SLX150** of a real B210.
- Its FX3 EEPROM is programmed with Ettus identifiers, so it enumerates as
  `2500:0020 USRP B210` and stock UHD drives it. No patched UHD needed.
- The FPGA reports compatibility number 16, which is what UHD 4.6, 4.7 and 4.8
  expect.
- The Ettus `usrp_b210_fpga.bin` **cannot** configure this FPGA and must be
  replaced. That is the entire job.
- Nothing is permanently flashed. UHD pushes the FX3 firmware and the FPGA
  bitstream over USB on every connection.

The long version, with the verification steps: [docs/HARDWARE.md](docs/HARDWARE.md).

---

## Credits

This package is glue. The work belongs to:

- [NovaSDR](https://github.com/phasor-labs/NovaSDR) (formerly PhantomSDR-Plus),
  the web SDR server and UI. GPL-3.0.
- [bkerler/LibreSDR_UHD_B220_Mini_FPGA](https://github.com/bkerler/LibreSDR_UHD_B220_Mini_FPGA),
  the FPGA sources and bitstream for the XC7A200T.
- [NustyFrozen/LibreSDR-UHD-B220-Mini](https://github.com/NustyFrozen/LibreSDR-UHD-B220-Mini),
  mirror of the vendor bitstream and documentation.
- [Ettus Research UHD](https://github.com/EttusResearch/uhd), the driver.

## Licence

The scripts, configuration and documentation in this repository are GPL-3.0, to
match NovaSDR and the UHD-derived FPGA sources.

The files under `fpga/` are redistributed from the upstream projects listed
above and carry their original terms.
