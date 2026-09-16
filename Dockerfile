# NovaSDR for LibreSDR B220 Mini (XC7A200T + AD9361, USRP B210 clone)
#
# Three stages:
#   1. frontend  - builds the React UI
#   2. backend   - builds the Rust server with the soapysdr feature
#   3. runtime   - UHD 4.6 + SoapyUHD + the LibreSDR FPGA bitstream
#
# The base is Ubuntu 24.04 in every stage that touches UHD, so the container
# uses exactly the same UHD 4.6.0.0 and SoapySDR 0.8.1 as a Noble host. That
# keeps the SoapySDR ABI consistent between the module and the Rust binding.

ARG NOVASDR_REPO=https://github.com/phasor-labs/NovaSDR.git
# Pinned for reproducible builds. Bump deliberately, not by accident.
ARG NOVASDR_REF=45b2951b5771ada2399deb3f6b3ed43c946840ba


# ---------------------------------------------------------------------------
# Stage 1: frontend
# ---------------------------------------------------------------------------
FROM node:20-slim AS frontend

ARG NOVASDR_REPO
ARG NOVASDR_REF

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone "$NOVASDR_REPO" . \
 && git checkout "$NOVASDR_REF" \
 && git submodule update --init --recursive --depth 1

WORKDIR /src/frontend
RUN npm ci && npm run build


# ---------------------------------------------------------------------------
# Stage 2: backend
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS backend

ARG NOVASDR_REPO
ARG NOVASDR_REF
# NovaSDR itself is edition 2021, but transitive dependencies (clap_lex and
# others) now require edition 2024, which is only stable from Rust 1.85.0.
ARG RUST_VERSION=1.98.1
# Cargo features. clfft needs an OpenCL ICD at runtime; drop it for a pure
# CPU build. vkfft is Linux only and needs a Vulkan stack in the container.
ARG NOVASDR_FEATURES=soapysdr

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential cmake pkg-config \
      clang libclang-dev \
      swig python3 python3-dev python3-numpy \
      libsoapysdr-dev libuhd-dev libusb-1.0-0-dev libopus-dev \
      ocl-icd-opencl-dev libclfft-dev \
      git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# Rust stable. NovaSDR is edition 2021 with no nightly features, so the
# nightly toolchain the upstream Dockerfile uses is not required.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain "$RUST_VERSION" --profile minimal
ENV PATH=/root/.cargo/bin:$PATH

WORKDIR /src
RUN git clone "$NOVASDR_REPO" . \
 && git checkout "$NOVASDR_REF"

RUN cargo build --release --features "$NOVASDR_FEATURES" -p novasdr-server \
 && cargo build --release -p ws_probe


# ---------------------------------------------------------------------------
# Stage 3: runtime
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libsoapysdr0.8 soapysdr-tools soapysdr0.8-module-uhd \
      libuhd4.6.0t64 uhd-host \
      libusb-1.0-0 libopus0 \
      ocl-icd-libopencl1 libclfft2 \
      python3 python3-requests \
      ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# FX3 firmware (usrp_b200_fw.hex) comes from Ettus and is correct for this
# board: the LibreSDR uses the same Cypress FX3 as a real B2xx.
RUN uhd_images_downloader -t b2xx

# The FPGA bitstream from Ettus is NOT usable here. A real B210 carries a
# Spartan-6 XC6SLX150; the LibreSDR B220 Mini carries an Artix-7 XC7A200T.
# Overwrite it with the LibreSDR build (IDCODE 0x03636093).
COPY fpga/libresdr_b210_bkerler.bin /usr/share/uhd/images/usrp_b210_fpga.bin

WORKDIR /app

COPY --from=backend  /src/target/release/novasdr-server /app/
COPY --from=backend  /src/target/release/ws_probe       /app/
COPY --from=frontend /src/frontend/dist                 /app/frontend/dist
COPY --from=backend  /src/crates/novasdr-server/resources/ /app/resources/

RUN mkdir -p /app/logs /app/data /app/config

EXPOSE 9002

ENV RUST_LOG=info \
    RUST_BACKTRACE=1 \
    UHD_IMAGES_DIR=/usr/share/uhd/images

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -fsS http://localhost:9002/ >/dev/null || exit 1

CMD ["/app/novasdr-server", "-c", "/app/config/config.json", "-r", "/app/config/receivers.json"]
