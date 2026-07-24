#!/bin/bash
#
# install.sh - stage config and user systemd units for llama-server.
#
# Run this after cloning the repo (or after wiping ~/.config) to get back
# online quickly:
#   - stages the api-keys file, secrets file, and one tunables file per
#     deployment under ~/.config/llama-server/, without touching this repo
#     or any systemd unit
#   - symlinks systemd/*.service into ~/.config/systemd/user/ and reloads
#     the user systemd daemon
#
# Safe to re-run: api-keys, secrets.env, and the *.env tunables files are
# only created if missing, never overwritten (so your edits survive a
# reclone). The systemd symlinks and daemon-reload always run, since those
# are just pointers back into this checkout.
#
# Also handles the one-time migration for existing installs from before the
# API key had its own file: if secrets.env still has a real LLAMA_API_KEY=
# value and api-keys doesn't exist yet, the key is moved over automatically
# (old line backed up, then replaced with a comment - see migrate_api_key
# below). New installs and already-migrated ones are unaffected.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CONFIG_DIR="$HOME/.config/llama-server"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
DEPLOYMENTS=(full-128k full-256k limited)

if [[ "$SCRIPT_DIR" != "$HOME/llama-server" ]]; then
  cat >&2 <<EOF
warning: this checkout is at $SCRIPT_DIR, not \$HOME/llama-server.
The systemd units and llm-server.sh's default model path both assume
~/llama-server - either move the checkout there, or expect to override
LLAMA_MODEL_PATH and edit WorkingDirectory/ExecStart in systemd/*.service
yourself.
EOF
fi

stage() {
  local src="$1" dest="$2" mode="$3"
  if [[ -e "$dest" ]]; then
    echo "    skip $dest (already exists)"
    return
  fi
  cp "$src" "$dest"
  chmod "$mode" "$dest"
  echo "    created $dest"
}

# One-time migration for pre-api-keys-file installs. Only acts if
# secrets.env has a real (non-empty, non-placeholder) LLAMA_API_KEY= value
# AND api-keys doesn't exist yet - never overwrites an api-keys file that's
# already there, same "only create if missing" rule as stage() above.
migrate_api_key() {
  local secrets_file="$CONFIG_DIR/secrets.env"
  local keys_file="$CONFIG_DIR/api-keys"

  [[ -f "$secrets_file" && ! -e "$keys_file" ]] || return 0

  local key
  key="$(grep -E '^[[:space:]]*LLAMA_API_KEY=' "$secrets_file" 2>/dev/null | tail -n1 \
    | sed -E 's/^[[:space:]]*LLAMA_API_KEY=//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')"
  [[ -n "$key" && "$key" != "change-me" ]] || return 0

  echo "==> migrating API key: found LLAMA_API_KEY in $secrets_file (pre-api-keys-file install)"
  printf '%s\n' "$key" > "$keys_file"
  chmod 600 "$keys_file"
  echo "    created $keys_file"

  local backup="$secrets_file.pre-api-key-migration.bak"
  cp "$secrets_file" "$backup"
  chmod 600 "$backup"
  sed -i -E "s|^[[:space:]]*LLAMA_API_KEY=.*|# LLAMA_API_KEY moved to $keys_file by install.sh - see README's Secrets section (original line backed up: $backup)|" "$secrets_file"
  echo "    removed the key from $secrets_file (backup: $backup)"
}

echo "==> staging config in $CONFIG_DIR"
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

migrate_api_key
stage "$SCRIPT_DIR/config/api-keys.example" "$CONFIG_DIR/api-keys" 600
stage "$SCRIPT_DIR/config/llama-server.env.example" "$CONFIG_DIR/secrets.env" 600

for d in "${DEPLOYMENTS[@]}"; do
  stage "$SCRIPT_DIR/config/${d}.env.example" "$CONFIG_DIR/${d}.env" 644
done

echo "==> installing user systemd units in $SYSTEMD_USER_DIR"
mkdir -p "$SYSTEMD_USER_DIR"
for d in "${DEPLOYMENTS[@]}"; do
  ln -sf "$SCRIPT_DIR/systemd/llama-server-${d}.service" "$SYSTEMD_USER_DIR/"
  echo "    linked llama-server-${d}.service"
done

systemctl --user daemon-reload
echo "==> systemctl --user daemon-reload done"

if ! compgen -G "$SCRIPT_DIR/models/*.gguf" > /dev/null; then
  echo
  echo "note: no .gguf found under $SCRIPT_DIR/models/ - place the model there," \
       "or set LLAMA_MODEL_PATH in a tunables file, before starting a service."
fi

cat <<EOF

Next steps:
  1. Set your API key:
       \$EDITOR $CONFIG_DIR/api-keys
  2. (optional) adjust tunables - ncmoe, ctx-size, sampling, etc:
       \$EDITOR $CONFIG_DIR/full-128k.env
       \$EDITOR $CONFIG_DIR/full-256k.env
       \$EDITOR $CONFIG_DIR/limited.env
  3. Start a deployment:
       systemctl --user enable --now llama-server-full-128k.service

See README.md for details.
EOF
