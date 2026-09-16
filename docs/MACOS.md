# Running on macOS

## The constraint you need to know first

**Docker Desktop on macOS cannot pass through USB devices.**

Docker on macOS runs Linux containers inside a virtual machine. That VM has no
USB host controller attached to it, so there is no `/dev/bus/usb` to forward.
This is a property of the platform, not a configuration mistake. Adding
`devices:` entries, `privileged: true`, or `--device` flags changes nothing:
the SDR is simply not visible inside the container.

The same applies to Docker Desktop on Windows without usbipd, and to Colima,
OrbStack, Rancher Desktop and Podman Desktop on macOS.

So `docker-compose.yml` in this repository is for **Linux hosts only**.

On a Mac you have three options.

---

## Option A: build and run NovaSDR natively on the Mac

The SDR plugs into the Mac. No containers involved. This is the option that
gives you full performance and full sample rate.

### Dependencies

```sh
brew install cmake pkg-config llvm swig python node libusb opus \
             uhd soapysdr soapyuhd
```

`brew install uhd` provides UHD and `uhd_images_downloader`. `soapyuhd` is the
SoapySDR module that NovaSDR talks to.

If `soapyuhd` is not available in your tap, build it:

```sh
git clone https://github.com/pothosware/SoapyUHD.git
cd SoapyUHD && mkdir build && cd build
cmake .. && make -j"$(sysctl -n hw.ncpu)" && sudo make install
```

Verify SoapySDR can see the UHD module:

```sh
SoapySDRUtil --info | grep -i uhd
```

### Install the images and the LibreSDR bitstream

```sh
uhd_images_downloader -t b2xx

# Find where Homebrew put the images
IMAGES=$(brew --prefix uhd)/share/uhd/images

# Keep the Ettus bitstream, it is not usable on this board but is worth having
mv "$IMAGES/usrp_b210_fpga.bin" "$IMAGES/usrp_b210_fpga.bin.ettus-orig"

# Install the LibreSDR bitstream from this repository
cp fpga/libresdr_b210_bkerler.bin "$IMAGES/usrp_b210_fpga.bin"
```

macOS has no udev, and libusb can claim the device without special rules, so
there is no permissions step. If `uhd_find_devices` reports a claim failure,
make sure nothing else already has the device open.

Confirm:

```sh
uhd_find_devices
uhd_usrp_probe
```

### Build NovaSDR

```sh
git clone https://github.com/phasor-labs/NovaSDR.git
cd NovaSDR
git checkout 45b2951b5771ada2399deb3f6b3ed43c946840ba
git submodule update --init --recursive

cargo build --release --features soapysdr -p novasdr-server

cd frontend && npm ci && npm run build && cd ..
```

Rust stable is enough. NovaSDR is edition 2021 and uses no nightly features,
despite what its own Dockerfile implies.

### Run it with this repository's configuration

```sh
./target/release/novasdr-server \
    -c /path/to/B220SDR/config/config.json \
    -r /path/to/B220SDR/config/receivers.json
```

`config.json` sets `html_root` to `frontend/dist/`, resolved relative to the
working directory, so run the binary from the NovaSDR checkout or edit that
value to an absolute path.

Open <http://localhost:9002>.

### Apple Silicon note

UHD, SoapySDR and the Rust `soapysdr` crate all build natively on arm64. Make
sure you are not mixing an x86_64 Homebrew under Rosetta with an arm64 Rust
toolchain: `brew --prefix` under `/usr/local` means x86_64, under `/opt/homebrew`
means arm64. `cargo build` must find the matching `libSoapySDR`.

---

## Option B: keep the SDR on the Linux box, use the Mac as a browser

The simplest option, and the one that needs no work on the Mac at all.

Run the container on the Linux machine the SDR is plugged into:

```sh
docker compose up -d --build
```

Then from the Mac open `http://<linux-box-ip>:9002`.

NovaSDR is a multi-user server. The demodulation, the FFT and the waterfall all
happen on the Linux host; the browser only receives audio and waterfall frames
over WebSockets. Nothing is gained by moving the server to the Mac.

This is the recommended option unless you specifically need the SDR physically
attached to the Mac.

---

## Option C: SDR on the Linux box, NovaSDR on the Mac over the network

Only worth it if you need NovaSDR itself running on the Mac while the hardware
stays elsewhere.

On the Linux machine with the SDR:

```sh
sudo apt-get install -y soapyremote-server
SoapySDRServer --bind
```

On the Mac:

```sh
brew install soapyremote
SoapySDRUtil --find="driver=remote"
```

Then change the device string in `config/receivers.json`:

```json
"device": "driver=remote,remote=192.168.1.50,remote:driver=uhd"
```

### The catch

SoapyRemote ships raw IQ over the network. At 61.44 MS/s in `cs16` that is
245 MB/s, about 2 Gbit/s, which a 1 GbE link cannot carry. Realistic ceilings:

| Link | Practical maximum sample rate (`cs16`) |
| --- | --- |
| 1 GbE | around 25 MS/s |
| 1 GbE with `SOAPY_SDR_REMOTE_FORMAT=CS8` | around 50 MS/s |
| Wi-Fi | a few MS/s, with jitter |
| 10 GbE | full rate |

For wideband work, use Option A or Option B.
