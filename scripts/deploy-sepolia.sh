#!/usr/bin/env bash
set -eo pipefail
cd "$(dirname "$0")/.."

if [ -z "$SEPOLIA_RPC_URL" ]; then
  SEPOLIA_RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
fi
if [ -z "$DEPLOYER_PRIVATE_KEY" ]; then
  echo "Set DEPLOYER_PRIVATE_KEY in your local environment or .env" >&2
  exit 1
fi
if [ -z "$PAYER_ADDRESS" ]; then
  echo "Set PAYER_ADDRESS to the payer wallet" >&2
  exit 1
fi
if [ -z "$BENEFICIARY_ADDRESS" ]; then
  echo "Set BENEFICIARY_ADDRESS to the invoice beneficiary" >&2
  exit 1
fi

export SEPOLIA_RPC_URL DEPLOYER_PRIVATE_KEY PAYER_ADDRESS BENEFICIARY_ADDRESS
forge script script/Deploy.s.sol:Deploy --rpc-url "$SEPOLIA_RPC_URL" --broadcast
