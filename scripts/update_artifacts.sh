#!/usr/bin/env bash
# Regenerate the pinned bytecode hex files in artifacts/ from the Forge build.
# Run after any change to src/ that affects compiled output. CI's bytecode
# guard requires these files to be updated in the same PR as src/ changes.
#
# Usage:
#   make artifacts                      # from repo root (recommended)
#   ./scripts/update_artifacts.sh       # from repo root
#   bash scripts/update_artifacts.sh    # if not executable
#
# Requires: foundry (forge) and jq on PATH.

set -euo pipefail

cd "$(dirname "$0")/.."

forge build --silent

extract() {
  local contract="$1"
  local prefix="$2"
  local json="out/${contract}.sol/${contract}.json"

  if [[ ! -f "$json" ]]; then
    echo "error: $json not found — did 'forge build' succeed?" >&2
    exit 1
  fi

  jq -r '.bytecode.object'         "$json" > "artifacts/${prefix}_deployment.hex"
  jq -r '.deployedBytecode.object' "$json" > "artifacts/${prefix}_runtime.hex"
  echo "  artifacts/${prefix}_{deployment,runtime}.hex"
}

echo "Updating bytecode artifacts:"
extract EscrowERC20  erc20
extract EscrowNative native
extract EscrowBatch  erc20_batch
