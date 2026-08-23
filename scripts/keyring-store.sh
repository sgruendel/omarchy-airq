#!/bin/sh
set -eu

serial=${1:-}
if [ -z "$serial" ]; then
  exit 2
fi

if ! IFS= read -r password; then
  exit 3
fi
if [ -z "$password" ]; then
  exit 3
fi

printf '%s' "$password" | secret-tool store \
  --label='air-Q device password' \
  application omarchy-airq \
  serial "$serial"
