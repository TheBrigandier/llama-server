#!/usr/bin/env bash
# End-to-end memory/perf measurement for one llama-server deployment.
#
#   ./measure-profile.sh <profile> [target_tokens]
#     ./measure-profile.sh limited                  # 118000 default
#     ./measure-profile.sh full-128k
#     ./measure-profile.sh full-256k 250000         # near-full for a 262144 ctx
#
# What it does:
#   1. temporarily raises the cgroup caps (runtime only) so the measurement is
#      not clipped by the very limits you are trying to derive
#   2. restarts the deployment, waits for /health
#   3. samples anon+shmem while driving a conversation to ~target_tokens, then
#      layers a second branch to put the prompt cache under pressure
#   4. prints the peak unreclaimable figure to size MemoryHigh/MemoryMax from
#   5. reverts the runtime caps (on EXIT, so Ctrl-C is safe too)
#
# Environment:
#   MEAS_HIGH / MEAS_MAX / MEAS_SWAP   measurement-only cgroup caps
#   LLAMA_TEST_HOST / LLAMA_TEST_PORT  where the server listens (127.0.0.1:8080)
#   LLAMA_TEST_API_KEY_FILE            default ~/.config/llama-server/api-keys
#
# IMPORTANT: on this repo's hardware full-128k / full-256k only load under
# multi-user.target (the GPU must be free). Running this for them from a
# graphical session will fail AND stop `limited` via Conflicts=. Verify with
# `systemctl is-active graphical.target display-manager.service` first -
# `systemctl get-default` reports the default target, not the current one.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${1:?usage: measure-profile.sh <profile> [target_tokens]}"
TARGET="${2:-118000}"
UNIT="${UNIT:-llama-server-${PROFILE}.service}"
HOST="${LLAMA_TEST_HOST:-127.0.0.1}"
PORT="${LLAMA_TEST_PORT:-8080}"
CG="${CGROUP_PATH:-/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice/${UNIT}}"

KEY_FILE="${LLAMA_TEST_API_KEY_FILE:-$HOME/.config/llama-server/api-keys}"
AUTH=()
if [ -r "$KEY_FILE" ]; then
  AUTH=(-H "Authorization: Bearer $(grep -vE '^\s*#|^\s*$' "$KEY_FILE" | head -1)")
fi

# Measurement-only caps. These MUST be above whatever the deployment ships or
# step 1 is a no-op and you measure a clipped peak. This bit us: the defaults
# below are at/under what full-128k (28G/30G) and full-256k (29G/30G) already
# ship, so those profiles were measured with:
#   MEAS_HIGH=30G MEAS_MAX=31G MEAS_SWAP=6G ./measure-profile.sh full-128k
# Pick values near the top of what the host has; a peak that reaches them is
# itself a result (the deployment does not fit).
MEAS_HIGH="${MEAS_HIGH:-28G}"
MEAS_MAX="${MEAS_MAX:-30G}"
MEAS_SWAP="${MEAS_SWAP:-6G}"

cleanup() {
  [ -n "${SAMPLER_PID:-}" ] && kill "$SAMPLER_PID" 2>/dev/null
  echo "[reverting runtime cap overrides]"
  # `systemctl --user revert` is required - a plain restart does NOT clear a
  # --runtime drop-in (it lives in /run/user/<uid>/systemd/user.control/ until
  # reboot), and you would silently measure under the wrong caps next time.
  systemctl --user revert "$UNIT" >/dev/null 2>&1
  systemctl --user daemon-reload
}
trap cleanup EXIT

echo "== raising caps for measurement (runtime only): High=$MEAS_HIGH Max=$MEAS_MAX Swap=$MEAS_SWAP =="
systemctl --user set-property --runtime "$UNIT" \
  MemoryHigh="$MEAS_HIGH" MemoryMax="$MEAS_MAX" MemorySwapMax="$MEAS_SWAP"

echo "== restarting $UNIT =="
# StartLimitBurst counts manual restarts; clear a tripped limit pre-emptively.
systemctl --user reset-failed "$UNIT" 2>/dev/null
systemctl --user restart "$UNIT"
for _ in $(seq 1 200); do
  curl -sf "${AUTH[@]}" "http://${HOST}:${PORT}/health" >/dev/null 2>&1 && break
  sleep 2
done
curl -sf "${AUTH[@]}" "http://${HOST}:${PORT}/health" >/dev/null 2>&1 || {
  echo "ERROR: $UNIT never became healthy at http://${HOST}:${PORT}." >&2
  echo "  If this is a full-* profile, are you on multi-user.target?" >&2
  journalctl --user -u "$UNIT" -n 20 --no-pager >&2
  exit 1
}
sleep 8
echo "resting: $(awk '/^(anon|shmem) /{s+=$2} END{printf "%.2f GiB unreclaimable", s/1073741824}' "$CG/memory.stat")"

rm -f "$HERE/peaks-${PROFILE}.txt"
bash "$HERE/memsample.sh" "$PROFILE" > "$HERE/memsample-${PROFILE}.log" 2>&1 &
SAMPLER_PID=$!

echo "== driving context to ~${TARGET} tokens =="
TARGET_TOKENS="$TARGET" python3 "$HERE/ctx_fill.py" 2>&1 | tee "$HERE/ctxfill-${PROFILE}.log"

sleep 3
kill "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=""

echo
echo "=================== RESULT: $PROFILE ==================="
cat "$HERE/peaks-${PROFILE}.txt"
echo
echo "Size MemoryMax >= peak_unreclaimable + ~4GiB headroom; MemoryHigh ~= MemoryMax - 2G."
echo "Keep total system RAM minus MemoryMax >= ~6GiB if a desktop shares the box."
echo "MemorySwapMax must be BOUNDED and NON-ZERO (4G) - see testing/README.md."
echo
echo "Check the ctx_fill 'return to big branch' line above: a large reproc"
echo "means --cache-ram could not hold the branch, which is a separate"
echo "problem from the memory ceilings and is NOT fixed by raising them."
