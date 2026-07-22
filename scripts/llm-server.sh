#!/bin/bash
#
# llm-server.sh - launcher for llama-server (Qwen3.6-35B-A3B-MTP)
#
# Has exactly one sane built-in default configuration (see "Defaults"
# below). To run a different configuration (more/less GPU offload, more
# context, different sampling, ...), don't edit this script - point
# --tunables-file at an env file that overrides what you need. See
# config/*.env.example for ready-made ones; install.sh stages copies of
# them to ~/.config/llama-server/ and the systemd units in systemd/ already
# reference them.
#
# Precedence, highest wins:
#
#   1. built-in defaults
#   2. tunables file        (optional, --tunables-file / LLAMA_TUNABLES_FILE)
#   3. secrets file         (~/.config/llama-server/secrets.env, optional)
#   4. environment variables (LLAMA_*)
#   5. command-line flags
#
# Both the tunables file and secrets file are just plain shell scripts that
# export LLAMA_* variables - source them yourself to see what they'll do.
# The tunables file is deliberately soft-optional (missing = silently fall
# back to the built-in defaults) since systemd units pass one by default
# whether or not `install.sh` has been run to create it - unlike an
# explicitly-passed --secrets-file, which is an error if missing.
#
# Run `llm-server.sh --help` for the full flag/env-var reference.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_DIR="$(dirname -- "$SCRIPT_DIR")"

usage() {
  cat <<'EOF'
Usage: llm-server.sh [OPTIONS]

This script has one built-in default configuration (ncmoe=27, ctx=131072,
threads=12 - the fastest single-GPU-only setup). Use --tunables-file to
switch to a different configuration instead of editing this script or the
systemd units - see config/*.env.example for ready-made ones.

Options (each has a matching LLAMA_* environment variable, see below):
  --model PATH             GGUF model path
  --ngl N                  GPU layers to offload (default: 99)
  --ncmoe N                MoE layers kept on CPU (default: 27)
  --threads N               CPU threads (default: 12)
  --ctx-size N              Context size in tokens (131072-262144, default: 131072)
  --parallel N              Parallel request slots (default: 1; must be 1
                              when --spec-type is draft-mtp, per model card)
  --cache-type-k TYPE       KV cache quantization for K (default: q8_0)
  --cache-type-v TYPE       KV cache quantization for V (default: q8_0)
  --spec-type TYPE          Speculative decoding type (default: draft-mtp)
  --spec-draft-n-max N      Max speculative draft tokens (default: 4 - tuned
                              by testing; accept rate falls off sharply at 5)
  --temp N                  Sampling temperature (default: 1.0)
  --top-p N                 Top-p sampling (default: 0.95)
  --top-k N                 Top-k sampling (default: 20)
  --presence-penalty N      Presence penalty (default: 1.5)
  --host HOST               Bind address (default: 0.0.0.0)
  --port PORT               Bind port (default: 8080)
  --api-key KEY              Bearer API key (normally set via secrets file)
  --mmap / --no-mmap        Enable/disable mmap (default: --no-mmap)
  --flash-attn on|off       Flash attention (default: on)
  --bin PATH                 llama-server binary (default: llama-server on PATH)
  --tunables-file PATH        Source deployment-specific tunables from PATH
                                (soft-optional: silently ignored if missing)
  --no-tunables                Skip sourcing the tunables file entirely
  --secrets-file PATH        Override secrets file location
  --no-secrets                Skip sourcing the secrets file entirely
  --allow-no-api-key          Allow starting without an API key (insecure)
  --extra-args "..."         Raw extra arguments appended verbatim
  --dry-run                    Print the resulting command instead of running it
  -h, --help                    Show this help

Environment variables (all optional, CLI flags win if both are set):
  LLAMA_MODEL_PATH, LLAMA_NGL, LLAMA_NCMOE, LLAMA_THREADS, LLAMA_CTX_SIZE,
  LLAMA_PARALLEL, LLAMA_CACHE_TYPE_K, LLAMA_CACHE_TYPE_V, LLAMA_SPEC_TYPE,
  LLAMA_SPEC_DRAFT_N_MAX, LLAMA_TEMP, LLAMA_TOP_P, LLAMA_TOP_K,
  LLAMA_PRESENCE_PENALTY, LLAMA_HOST, LLAMA_PORT, LLAMA_API_KEY,
  LLAMA_NO_MMAP (1/0), LLAMA_FLASH_ATTN, LLAMA_SERVER_BIN,
  LLAMA_TUNABLES_FILE, LLAMA_SECRETS_FILE, LLAMA_EXTRA_ARGS

Tunables file and secrets file are both sourced as shell, before real
environment variables are read, so either can set any LLAMA_* variable
above:
  - Tunables file has no default path - opt in with --tunables-file or
    LLAMA_TUNABLES_FILE. Missing file is silently ignored (see
    config/*.env.example for ready-made deployment configs; install.sh
    stages them to ~/.config/llama-server/<name>.env and the matching
    systemd unit already passes --tunables-file for you).
  - Secrets file defaults to ~/.config/llama-server/secrets.env (override
    with --secrets-file); typically just sets LLAMA_API_KEY.

Examples:
  llm-server.sh --dry-run
  llm-server.sh --tunables-file config/full-256k.env.example --dry-run
  LLAMA_NCMOE=40 llm-server.sh
  llm-server.sh --ncmoe 25 --extra-args "--verbose"
EOF
}

MIN_CTX_SIZE=131072
MAX_CTX_SIZE=262144

DRY_RUN=0
SKIP_SECRETS=0
SKIP_TUNABLES=0
ALLOW_NO_API_KEY=0
SECRETS_FILE_EXPLICIT=0

SECRETS_FILE="${LLAMA_SECRETS_FILE:-$HOME/.config/llama-server/secrets.env}"
TUNABLES_FILE="${LLAMA_TUNABLES_FILE:-}"

# ---------------------------------------------------------------------------
# 1. Tunables file + secrets file - both sourced before the "defaults" step
#    below, so either can set any LLAMA_* variable. Do a first pass over
#    argv just to catch the flags that affect *this* step
#    (--tunables-file/--no-tunables/--secrets-file/--no-secrets) - the full
#    CLI parse happens later and still wins over anything sourced here.
# ---------------------------------------------------------------------------
for ((i = 1; i <= $#; i++)); do
  arg="${!i}"
  case "$arg" in
    --tunables-file)
      j=$((i + 1))
      TUNABLES_FILE="${!j:-}"
      ;;
    --no-tunables)
      SKIP_TUNABLES=1
      ;;
    --secrets-file)
      j=$((i + 1))
      SECRETS_FILE="${!j:-}"
      SECRETS_FILE_EXPLICIT=1
      ;;
    --no-secrets)
      SKIP_SECRETS=1
      ;;
  esac
done

if [[ "$SKIP_TUNABLES" -eq 0 && -n "$TUNABLES_FILE" ]]; then
  if [[ -f "$TUNABLES_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$TUNABLES_FILE"
  else
    echo "note: tunables file not found at $TUNABLES_FILE, using built-in defaults" >&2
  fi
fi

if [[ "$SKIP_SECRETS" -eq 0 && -f "$SECRETS_FILE" ]]; then
  perms="$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || echo '???')"
  if [[ "$perms" != "600" && "$perms" != "400" ]]; then
    echo "warning: $SECRETS_FILE has mode $perms - recommend 'chmod 600 $SECRETS_FILE'" >&2
  fi
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
elif [[ "$SKIP_SECRETS" -eq 0 && "$SECRETS_FILE_EXPLICIT" -eq 1 ]]; then
  echo "error: secrets file not found: $SECRETS_FILE" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Defaults - from whatever's now in the environment (real env vars, plus
#    anything just sourced above), falling back to this script's built-in
#    values. ncmoe=27/ctx=131072/threads=12 is the fastest single-GPU-only
#    setup (see script header) - override via a tunables file, not by
#    editing these numbers.
# ---------------------------------------------------------------------------
MODEL_PATH="${LLAMA_MODEL_PATH:-$HOME/llama-server/models/Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL.gguf}"
NGL="${LLAMA_NGL:-99}"
NCMOE="${LLAMA_NCMOE:-27}"
THREADS="${LLAMA_THREADS:-12}"
CTX_SIZE="${LLAMA_CTX_SIZE:-131072}"
PARALLEL="${LLAMA_PARALLEL:-1}"
CACHE_TYPE_K="${LLAMA_CACHE_TYPE_K:-q8_0}"
CACHE_TYPE_V="${LLAMA_CACHE_TYPE_V:-q8_0}"
SPEC_TYPE="${LLAMA_SPEC_TYPE:-draft-mtp}"
# 4 was chosen by testing on this model/hardware: good speedup at 4, accept
# rate falls off sharply at 5. The model card's own example uses 2 - that's
# a safer generic default, but 4 is the better number for this setup.
SPEC_DRAFT_N_MAX="${LLAMA_SPEC_DRAFT_N_MAX:-4}"
# Sampling defaults per the model card's "thinking mode" recommendation.
TEMP="${LLAMA_TEMP:-1.0}"
TOP_P="${LLAMA_TOP_P:-0.95}"
TOP_K="${LLAMA_TOP_K:-20}"
PRESENCE_PENALTY="${LLAMA_PRESENCE_PENALTY:-1.5}"
HOST="${LLAMA_HOST:-0.0.0.0}"
PORT="${LLAMA_PORT:-8080}"
API_KEY="${LLAMA_API_KEY:-}"
NO_MMAP="${LLAMA_NO_MMAP:-1}"
FLASH_ATTN="${LLAMA_FLASH_ATTN:-on}"
SERVER_BIN="${LLAMA_SERVER_BIN:-llama-server}"
EXTRA_ARGS="${LLAMA_EXTRA_ARGS:-}"

# ---------------------------------------------------------------------------
# 3. CLI parsing (highest precedence)
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL_PATH="$2"; shift 2 ;;
    --ngl) NGL="$2"; shift 2 ;;
    --ncmoe) NCMOE="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --ctx-size) CTX_SIZE="$2"; shift 2 ;;
    --parallel) PARALLEL="$2"; shift 2 ;;
    --cache-type-k) CACHE_TYPE_K="$2"; shift 2 ;;
    --cache-type-v) CACHE_TYPE_V="$2"; shift 2 ;;
    --spec-type) SPEC_TYPE="$2"; shift 2 ;;
    --spec-draft-n-max) SPEC_DRAFT_N_MAX="$2"; shift 2 ;;
    --temp) TEMP="$2"; shift 2 ;;
    --top-p) TOP_P="$2"; shift 2 ;;
    --top-k) TOP_K="$2"; shift 2 ;;
    --presence-penalty) PRESENCE_PENALTY="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --api-key) API_KEY="$2"; shift 2 ;;
    --mmap) NO_MMAP=0; shift ;;
    --no-mmap) NO_MMAP=1; shift ;;
    --flash-attn) FLASH_ATTN="$2"; shift 2 ;;
    --bin) SERVER_BIN="$2"; shift 2 ;;
    --tunables-file) shift 2 ;;  # already handled above
    --no-tunables) shift ;;       # already handled above
    --secrets-file) shift 2 ;;   # already handled above
    --no-secrets) shift ;;        # already handled above
    --allow-no-api-key) ALLOW_NO_API_KEY=1; shift ;;
    --extra-args) EXTRA_ARGS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "error: unknown argument '$1' (see --help)" >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# 4. Validation
# ---------------------------------------------------------------------------
if [[ ! -f "$MODEL_PATH" && "$DRY_RUN" -eq 0 ]]; then
  echo "error: model not found at $MODEL_PATH (override with --model or LLAMA_MODEL_PATH)" >&2
  exit 1
fi

if [[ "$CTX_SIZE" -lt "$MIN_CTX_SIZE" ]]; then
  echo "error: --ctx-size $CTX_SIZE is below the model's recommended minimum of $MIN_CTX_SIZE (thinking quality drops off below this - see model card)" >&2
  exit 1
fi

if [[ "$CTX_SIZE" -gt "$MAX_CTX_SIZE" ]]; then
  echo "error: --ctx-size $CTX_SIZE exceeds the model's native max of $MAX_CTX_SIZE" >&2
  exit 1
fi

if [[ "$SPEC_TYPE" == draft-mtp* && "$PARALLEL" -gt 1 ]]; then
  echo "error: --parallel $PARALLEL is not supported with --spec-type draft-mtp (per model card: -np > 1 is not yet supported with MTP)" >&2
  exit 1
fi

if [[ -z "$API_KEY" && "$ALLOW_NO_API_KEY" -eq 0 ]]; then
  cat >&2 <<EOF
error: no API key set and the server binds to $HOST.
Set LLAMA_API_KEY in $SECRETS_FILE, pass --api-key, or pass
--allow-no-api-key to intentionally run without auth.
EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Build and run the command
# ---------------------------------------------------------------------------
cmd=("$SERVER_BIN"
  -m "$MODEL_PATH"
  -ngl "$NGL"
  -ncmoe "$NCMOE"
  -t "$THREADS"
  --ctx-size "$CTX_SIZE"
  --parallel "$PARALLEL"
)
[[ "$NO_MMAP" -eq 1 ]] && cmd+=(--no-mmap)
cmd+=(--flash-attn "$FLASH_ATTN")
cmd+=(--cache-type-k "$CACHE_TYPE_K" --cache-type-v "$CACHE_TYPE_V")
cmd+=(--spec-type "$SPEC_TYPE" --spec-draft-n-max "$SPEC_DRAFT_N_MAX")
cmd+=(--temp "$TEMP" --top-p "$TOP_P" --top-k "$TOP_K" --presence-penalty "$PRESENCE_PENALTY")
cmd+=(--jinja)
[[ -n "$API_KEY" ]] && cmd+=(--api-key "$API_KEY")
cmd+=(--reasoning-preserve)
cmd+=(--host "$HOST" --port "$PORT")
if [[ -n "$EXTRA_ARGS" ]]; then
  # shellcheck disable=SC2206
  cmd+=($EXTRA_ARGS)
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '%q ' "${cmd[@]}"
  echo
  exit 0
fi

exec "${cmd[@]}"
