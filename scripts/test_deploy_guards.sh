#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export CAST_LOG="$TMP/cast.log"
export FORGE_LOG="$TMP/forge.log"
export FAKE_CHAIN_ID=1
export FAKE_SETTLEMENT_VERSION=1
: > "$CAST_LOG"
: > "$FORGE_LOG"

cat > "$TMP/bin/cast" <<'CAST'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CAST_LOG"
if [[ "$1" == "wallet" && "$2" == "address" ]]; then
  echo "0x1111111111111111111111111111111111111111"
elif [[ "$1" == "chain-id" ]]; then
  echo "$FAKE_CHAIN_ID"
elif [[ "$1" == "rpc" && "$*" == *"eth_gasPrice"* ]]; then
  echo "0x3b9aca00"
elif [[ "$1" == "rpc" && "$*" == *"eth_maxPriorityFeePerGas"* ]]; then
  echo "0x3b9aca00"
elif [[ "$1" == "code" ]]; then
  echo "0x60006000"
elif [[ "$1" == "call" && "$*" == *"owner()(address)"* ]]; then
  echo "0x1111111111111111111111111111111111111111"
elif [[ "$1" == "call" && "$*" == *"SETTLEMENT_VERSION()(uint256)"* ]]; then
  echo "$FAKE_SETTLEMENT_VERSION"
else
  echo "Unexpected cast invocation in deploy guard test: $*" >&2
  exit 97
fi
CAST
chmod +x "$TMP/bin/cast"

cat > "$TMP/bin/forge" <<'FORGE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FORGE_LOG"
echo "Unexpected forge invocation in a preflight-only test" >&2
exit 98
FORGE
chmod +x "$TMP/bin/forge"

DEPLOY_KEY="0x1111111111111111111111111111111111111111111111111111111111111111"
PAYER="0x3333333333333333333333333333333333333333"
BENEFICIARY="0x4444444444444444444444444444444444444444"
AGENT_OWNER="0x2222222222222222222222222222222222222222"
TOKEN="0x5555555555555555555555555555555555555555"
SETTLEMENT="0x6666666666666666666666666666666666666666"

# Case 1: an RPC connected to a non-Sepolia chain must stop before fee checks or deployments.
: > "$CAST_LOG"
: > "$FORGE_LOG"
if output="$(env PATH="$TMP/bin:$PATH" CAST_LOG="$CAST_LOG" FORGE_LOG="$FORGE_LOG" \
    FAKE_CHAIN_ID=1 FAKE_SETTLEMENT_VERSION=1 DEPLOYER_PRIVATE_KEY="$DEPLOY_KEY" \
    PAYER_ADDRESS="$PAYER" BENEFICIARY_ADDRESS="$BENEFICIARY" AGENT_OWNER_ADDRESS="$AGENT_OWNER" \
    bash "$ROOT/scripts/deploy-sepolia.sh" 2>&1)"; then
  echo "FAIL: deploy script accepted chain ID 1" >&2
  exit 1
fi
grep -q "expected Sepolia 11155111" <<< "$output" || {
  printf 'FAIL: wrong-chain rejection was not clear:\n%s\n' "$output" >&2
  exit 1
}
grep -q "chain-id" "$CAST_LOG"
if grep -Eq "eth_gasPrice|eth_estimateGas| nonce | send " "$CAST_LOG" || [[ -s "$FORGE_LOG" ]]; then
  echo "FAIL: wrong-chain check reached fee estimation, nonce or deployment." >&2
  cat "$CAST_LOG" >&2
  exit 1
fi
echo "PASS: non-Sepolia chain rejected before deployment work"

# Case 2: a valid Sepolia RPC must still refuse a reused legacy settlement before invoice calls or sends.
: > "$CAST_LOG"
: > "$FORGE_LOG"
if output="$(env PATH="$TMP/bin:$PATH" CAST_LOG="$CAST_LOG" FORGE_LOG="$FORGE_LOG" \
    FAKE_CHAIN_ID=11155111 FAKE_SETTLEMENT_VERSION=1 DEPLOYER_PRIVATE_KEY="$DEPLOY_KEY" \
    PAYER_ADDRESS="$PAYER" BENEFICIARY_ADDRESS="$BENEFICIARY" AGENT_OWNER_ADDRESS="$AGENT_OWNER" \
    EXISTING_TOKEN_ADDRESS="$TOKEN" EXISTING_SETTLEMENT_ADDRESS="$SETTLEMENT" \
    bash "$ROOT/scripts/deploy-sepolia.sh" 2>&1)"; then
  echo "FAIL: deploy script accepted legacy settlement version 1" >&2
  exit 1
fi
grep -q "current deployment requires version 2" <<< "$output" || {
  printf 'FAIL: legacy settlement rejection was not clear:\n%s\n' "$output" >&2
  exit 1
}
grep -q "SETTLEMENT_VERSION" "$CAST_LOG"
if grep -Eq 'invoices\(bytes32\)|eth_estimateGas| nonce | send ' "$CAST_LOG" || [[ -s "$FORGE_LOG" ]]; then
  echo "FAIL: legacy settlement guard ran after invoice/deployment work." >&2
  cat "$CAST_LOG" >&2
  exit 1
fi
echo "PASS: legacy settlement rejected before invoice calls or deployment"

echo "All deployment guard tests passed."
