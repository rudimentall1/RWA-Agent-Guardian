#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -v SEPOLIA_RPC_URL ]] || [[ -z "$SEPOLIA_RPC_URL" ]]; then
  SEPOLIA_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
fi
if [[ ! -v DEPLOYER_PRIVATE_KEY ]] || [[ -z "$DEPLOYER_PRIVATE_KEY" ]]; then
  echo "Set DEPLOYER_PRIVATE_KEY in the environment; do not put it in Git." >&2
  exit 1
fi
if [[ ! -v PAYER_ADDRESS ]] || [[ -z "$PAYER_ADDRESS" ]]; then
  echo "Set PAYER_ADDRESS to the payer wallet." >&2
  exit 1
fi
if [[ ! -v BENEFICIARY_ADDRESS ]] || [[ -z "$BENEFICIARY_ADDRESS" ]]; then
  echo "Set BENEFICIARY_ADDRESS to the invoice beneficiary." >&2
  exit 1
fi

export SEPOLIA_RPC_URL DEPLOYER_PRIVATE_KEY PAYER_ADDRESS BENEFICIARY_ADDRESS
# Wait for every transaction and stop on a failed receipt; use a conservative
# gas multiplier because the RPC estimator underpriced contract creation twice.
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast \
  --slow \
  --gas-estimate-multiplier 300 \
  --timeout 60
