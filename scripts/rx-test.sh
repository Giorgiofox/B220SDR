#!/usr/bin/env bash
#
# Receive-only smoke test. Streams IQ from the LibreSDR B220 Mini and reports
# the achieved sample rate plus overflow counters, without starting NovaSDR.
#
# Use this to answer three questions before touching the web UI:
#   - does the board stream at all
#   - did it come up on USB 3.0 or is it stuck on USB 2.0
#   - what sample rate does this host sustain without overflows
#
# Usage:
#   scripts/rx-test.sh                       8 MS/s at 100 MHz for 5 s
#   scripts/rx-test.sh 145000000 8000000 10  freq, rate, seconds
#
# An "O" printed by UHD is an overflow: the host did not drain the buffers
# fast enough. A "D" is a dropped packet on the bus.

set -uo pipefail

FREQ="${1:-100000000}"
RATE="${2:-8000000}"
SECS="${3:-5}"
GAIN="${4:-40}"
ANT="${5:-RX2}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "${UHD_IMAGES_DIR:-}" ] && [ -d "$REPO_DIR/uhd-images" ]; then
    export UHD_IMAGES_DIR="$REPO_DIR/uhd-images"
fi

OUT="${OUT:-$(mktemp -d)/rx.iq}"

echo "freq=${FREQ} Hz  rate=${RATE} S/s  gain=${GAIN} dB  antenna=${ANT}  duration=${SECS} s"
echo "output: $OUT"
echo

# rx_samples_to_file ships with uhd-host. sc16 on the wire, fc32 on the host.
uhd_rx_samples_to_file=$(command -v rx_samples_to_file || echo /usr/lib/uhd/examples/rx_samples_to_file)
if [ ! -x "$uhd_rx_samples_to_file" ]; then
    echo "rx_samples_to_file not found. Falling back to a Python UHD streamer." >&2
    python3 - "$FREQ" "$RATE" "$SECS" "$GAIN" "$ANT" "$OUT" <<'PY'
import sys, time, numpy as np, uhd

freq, rate, secs, gain, ant, out = (
    float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]),
    float(sys.argv[4]), sys.argv[5], sys.argv[6],
)

usrp = uhd.usrp.MultiUSRP("type=b200")
usrp.set_rx_rate(rate, 0)
usrp.set_rx_freq(uhd.types.TuneRequest(freq), 0)
usrp.set_rx_gain(gain, 0)
usrp.set_rx_antenna(ant, 0)

actual_rate = usrp.get_rx_rate(0)
print(f"actual rate : {actual_rate/1e6:.6f} MS/s")
print(f"actual freq : {usrp.get_rx_freq(0)/1e6:.6f} MHz")
print(f"actual gain : {usrp.get_rx_gain(0):.1f} dB")

st_args = uhd.usrp.StreamArgs("fc32", "sc16")
st_args.channels = [0]
streamer = usrp.get_rx_stream(st_args)
meta = uhd.types.RXMetadata()
spb = streamer.get_max_num_samps()
buf = np.zeros((1, spb), dtype=np.complex64)

streamer.issue_stream_cmd(
    uhd.types.StreamCMD(uhd.types.StreamMode.start_cont)
)

total, overflows, t0 = 0, 0, time.time()
power_acc, blocks = 0.0, 0
with open(out, "wb") as fh:
    while time.time() - t0 < secs:
        n = streamer.recv(buf, meta)
        if meta.error_code == uhd.types.RXMetadataErrorCode.overflow:
            overflows += 1
            continue
        if meta.error_code != uhd.types.RXMetadataErrorCode.none:
            print(f"error: {meta.strerror()}")
            break
        total += n
        blocks += 1
        power_acc += float(np.mean(np.abs(buf[0, :n]) ** 2))
        fh.write(buf[0, :n].tobytes())

streamer.issue_stream_cmd(
    uhd.types.StreamCMD(uhd.types.StreamMode.stop_cont)
)

elapsed = time.time() - t0
print()
print(f"samples     : {total}")
print(f"elapsed     : {elapsed:.2f} s")
print(f"throughput  : {total/elapsed/1e6:.3f} MS/s")
print(f"overflows   : {overflows}")
if blocks:
    mean_power = power_acc / blocks
    print(f"mean power  : {10*np.log10(mean_power + 1e-20):.1f} dBFS")
    if mean_power < 1e-9:
        print("WARNING: signal is essentially zero. Check the antenna and the gain.")
PY
    exit $?
fi

"$uhd_rx_samples_to_file" \
    --args "type=b200" \
    --freq "$FREQ" \
    --rate "$RATE" \
    --gain "$GAIN" \
    --ant "$ANT" \
    --duration "$SECS" \
    --file "$OUT" \
    --type short 2>&1

echo
ls -la "$OUT"
expected=$(python3 -c "print(int($RATE * $SECS * 4))")
actual=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
echo "expected ~${expected} bytes, got ${actual} bytes"
