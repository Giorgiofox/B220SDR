#!/usr/bin/env bash
#
# Switch the captured spectrum.
#
# NovaSDR sets the centre frequency once, when it opens the device, and never
# retunes at runtime. That is inherent to a WebSDR: it captures one slice and
# serves it to every listener, who then tune inside that slice independently.
# There is no frequency control in the web UI and there cannot be one without
# disrupting every other listener.
#
# So changing band means editing the config and restarting, which takes about
# fifteen seconds. This wraps that.
#
# Usage:
#   scripts/band.sh                       show the current slice and exit
#   scripts/band.sh list                  list the ready-made profiles
#   scripts/band.sh <profile>             switch to a profile
#   scripts/band.sh tune <MHz> [MS/s] [gain]
#                                         switch to an arbitrary centre
#
# Examples:
#   scripts/band.sh air
#   scripts/band.sh tune 1090 8 50        ADS-B, 8 MS/s, 50 dB
#   scripts/band.sh tune 1575.42 8 60     GPS L1

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="$REPO_DIR/config/config.json"
RXS="$REPO_DIR/config/receivers.json"

[ -f "$CFG" ] || { echo "missing $CFG" >&2; exit 1; }
[ -f "$RXS" ] || { echo "missing $RXS" >&2; exit 1; }

show() {
    python3 - "$CFG" "$RXS" <<'PY'
import json, sys
cfg  = json.load(open(sys.argv[1]))
rxs  = json.load(open(sys.argv[2]))
act  = cfg.get('active_receiver_id')
print(f"{'':2}{'id':12} {'rate':>9}  {'span':>25}  {'gain':>5}  name")
print('-' * 86)
for r in rxs['receivers']:
    i   = r['input']
    lo  = (i['frequency'] - i['sps'] // 2) / 1e6
    hi  = (i['frequency'] + i['sps'] // 2) / 1e6
    mark = '*' if r['id'] == act else ' '
    span = f"{lo:9.3f} - {hi:9.3f} MHz"
    print(f"{mark} {r['id']:12} {i['sps']/1e6:6.1f} MS/s  {span:>25}  {i['driver']['gain']:5.0f}  {r.get('name','')}")
print()
print('* = active')
PY
}

restart() {
    echo
    echo "restarting NovaSDR..."
    docker compose -f "$REPO_DIR/docker-compose.yml" restart novasdr >/dev/null
    # Wait for the DSP thread to actually open the device rather than guessing.
    for _ in $(seq 1 40); do
        if docker compose -f "$REPO_DIR/docker-compose.yml" logs --since 90s novasdr 2>&1 \
             | grep -q 'input opened'; then
            echo "device opened"
            docker compose -f "$REPO_DIR/docker-compose.yml" logs --since 90s novasdr 2>&1 \
              | grep -E 'runtime derived' | tail -1 \
              | sed 's/.*receiver_id=/  receiver_id=/'
            echo
            show
            return 0
        fi
        if docker compose -f "$REPO_DIR/docker-compose.yml" logs --since 90s novasdr 2>&1 \
             | grep -q 'DSP loop terminated'; then
            echo "ERROR: the DSP loop failed to open the device." >&2
            docker compose -f "$REPO_DIR/docker-compose.yml" logs --since 90s novasdr 2>&1 \
              | grep -A3 'DSP loop terminated' | head -8 >&2
            echo "See docs/TROUBLESHOOTING.md. A wedged B210 needs a USB replug." >&2
            return 1
        fi
        sleep 2
    done
    echo "WARNING: timed out waiting for the device to open. Check the logs." >&2
    return 1
}

case "${1:-show}" in
    show|'')
        show
        ;;

    list)
        show
        cat <<'EOF'

Add a profile by copying an entry in config/receivers.json, or use:
  scripts/band.sh tune <MHz> [MS/s] [gain]
EOF
        ;;

    tune)
        MHZ="${2:?usage: band.sh tune <MHz> [MS/s] [gain]}"
        RATE="${3:-56}"
        GAIN="${4:-40}"
        python3 - "$CFG" "$RXS" "$MHZ" "$RATE" "$GAIN" <<'PY'
import json, sys, copy
cfgp, rxsp, mhz, rate, gain = sys.argv[1:6]
freq = int(float(mhz) * 1e6)
sps  = int(float(rate) * 1e6)
gain = float(gain)

if sps > 56_000_000:
    raise SystemExit(f"rate {rate} MS/s exceeds the AD9361 analog bandwidth of 56 MHz")
if not (50e6 <= freq <= 6e9):
    raise SystemExit(f"centre {mhz} MHz is outside the 50 MHz - 6 GHz tuning range")

cfg = json.load(open(cfgp))
rxs = json.load(open(rxsp))

# Reuse an existing profile as the template so stream args and compression
# settings stay consistent.
template = copy.deepcopy(rxs['receivers'][0])

# FFT size follows the rate so bin width stays in the same ballpark.
fft = 65536
while fft < 262144 and sps / fft > 250:
    fft *= 2

r = template
r['id']      = 'rx_custom'
r['name']    = f'custom {freq/1e6:.3f} MHz @ {sps/1e6:.1f} MS/s'
r['enabled'] = True
i = r['input']
i['sps']       = sps
i['frequency'] = freq
i['fft_size']  = fft
i['defaults']['frequency'] = freq
i['driver']['gain'] = gain
# Never pass master_clock_rate: it wedges the B200 control core.
i['driver']['device'] = 'driver=uhd,type=b200'

rxs['receivers'] = [x for x in rxs['receivers'] if x['id'] != 'rx_custom']
for x in rxs['receivers']:
    x['enabled'] = False          # exactly one receiver may hold the device
rxs['receivers'].append(r)

cfg['active_receiver_id'] = 'rx_custom'
json.dump(cfg, open(cfgp, 'w'), indent=2); open(cfgp, 'a').write('\n')
json.dump(rxs, open(rxsp, 'w'), indent=2); open(rxsp, 'a').write('\n')
print(f"centre {freq/1e6:.3f} MHz, {sps/1e6:.1f} MS/s, fft {fft}, gain {gain:.0f} dB")
print(f"span   {(freq-sps//2)/1e6:.3f} - {(freq+sps//2)/1e6:.3f} MHz")
PY
        restart
        ;;

    *)
        PROFILE="$1"
        python3 - "$CFG" "$RXS" "$PROFILE" <<'PY'
import json, sys
cfgp, rxsp, want = sys.argv[1:4]
cfg = json.load(open(cfgp))
rxs = json.load(open(rxsp))
ids = [r['id'] for r in rxs['receivers']]

# Accept both the full id and a short suffix, so "air" matches "rx_air".
match = [i for i in ids if i == want or i == f'rx_{want}' or i.removeprefix('rx_') == want]
if not match:
    raise SystemExit(f"no such profile: {want}\navailable: {', '.join(ids)}")
target = match[0]

for r in rxs['receivers']:
    r['enabled'] = (r['id'] == target)
cfg['active_receiver_id'] = target
json.dump(cfg, open(cfgp, 'w'), indent=2); open(cfgp, 'a').write('\n')
json.dump(rxs, open(rxsp, 'w'), indent=2); open(rxsp, 'a').write('\n')
print(f"switched to {target}")
PY
        restart
        ;;
esac
