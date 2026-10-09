#!/usr/bin/env bash
# Sequential Sepolia deployment with explicit per-transaction gas limits.
# Requires DEPLOYER_PRIVATE_KEY, PAYER_ADDRESS, BENEFICIARY_ADDRESS in env.
set -euo pipefail
set +x
cd "$(dirname "$0")/.."

SEPOLIA_RPC_URL="${SEPOLIA_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
  echo "Set DEPLOYER_PRIVATE_KEY in the environment; do not put it in Git." >&2
  exit 1
fi
if [[ -z "${PAYER_ADDRESS:-}" || -z "${BENEFICIARY_ADDRESS:-}" ]]; then
  echo "Set PAYER_ADDRESS and BENEFICIARY_ADDRESS in the environment." >&2
  exit 1
fi

KEY="$DEPLOYER_PRIVATE_KEY"
if [[ "$KEY" != 0x* && "$KEY" != 0X* ]]; then
  KEY="0x$KEY"
fi
DEPLOYER_ADDRESS="$(cast wallet address --private-key "$KEY")"
echo "Verified signing account: $DEPLOYER_ADDRESS"
export SEPOLIA_RPC_URL

deploy_contract() {
  local label="$1"
  local artifact="$2"
  local gas_limit="$3"
  shift 3
  local output address
  echo "Deploying $label (gas limit: $gas_limit)..." >&2
  if ! output="$(forge create "$artifact" \
      --rpc-url "$SEPOLIA_RPC_URL" \
      --private-key "$KEY" \
      --gas-limit "$gas_limit" \
      --timeout 60 \
      --broadcast \
      --constructor-args "$@" 2>&1)"; then
    printf '%s\n' "$output" >&2
    echo "FAILED: $label. Stopping; no later transaction will be sent." >&2
    return 1
  fi
  printf '%s\n' "$output" >&2
  address="$(printf '%s\n' "$output" | sed -nE 's/^Deployed to: (0x[0-9a-fA-F]{40}).*/\1/p' | tail -n 1)"
  if [[ -z "$address" ]]; then
    echo "Could not parse $label address from forge create output. Inspect output above." >&2
    return 1
  fi
  printf '%s\n' "$address"
}

send_and_confirm() {
  local label="$1"
  local target="$2"
  local signature="$3"
  shift 3
  echo "Sending $label..." >&2
  cast send "$target" "$signature" "$@" \
    --rpc-url "$SEPOLIA_RPC_URL" \
    --private-key "$KEY" \
    --gas-limit 500000 \
    --timeout 60
  echo "$label confirmed." >&2
}

TOKEN="$(deploy_contract "DemoSettlementToken" "contracts/DemoSettlementToken.sol:DemoSettlementToken" 3000000 "$DEPLOYER_ADDRESS")"
SETTLEMENT="$(deploy_contract "InvoiceSettlement" "contracts/InvoiceSettlement.sol:InvoiceSettlement" 8000000 "$DEPLOYER_ADDRESS")"
EXECUTOR="$(deploy_contract "DemoAgentExecutor" "contracts/DemoAgentExecutor.sol:DemoAgentExecutor" 2000000 "$SETTLEMENT" "$PAYER_ADDRESS")"

INVOICE_ID="$(cast keccak 'INV-1001')"
TERMS_HASH="$(cast keccak 'INV-1001|Synthetic invoice|10000 dUSD|NET30|v1')"
FACE_VALUE=10000000000
CHAIN_TIMESTAMP="$(cast block latest --rpc-url "$SEPOLIA_RPC_URL" --json | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["timestamp"], 16))')"
DUE_AT="$((CHAIN_TIMESTAMP + 2592000))"

send_and_confirm "register invoice" "$SETTLEMENT" \
  "registerInvoice(bytes32,address,address,address,uint128,uint64,bytes32)" \
  "$INVOICE_ID" "$PAYER_ADDRESS" "$BENEFICIARY_ADDRESS" "$TOKEN" \
  "$FACE_VALUE" "$DUE_AT" "$TERMS_HASH"
send_and_confirm "mint demo settlement balance" "$TOKEN" \
  "mint(address,uint256)" "$PAYER_ADDRESS" "$FACE_VALUE"

python3 - "$TOKEN" "$SETTLEMENT" "$EXECUTOR" "$INVOICE_ID" "$TERMS_HASH" "$DUE_AT" "$DEPLOYER_ADDRESS" "$PAYER_ADDRESS" "$BENEFICIARY_ADDRESS" <<'PY'
import json, sys
from pathlib import Path

token, settlement, executor, invoice_id, terms_hash, due_at, deployer, payer, beneficiary = sys.argv[1:]
record = {
    "chainId": 11155111,
    "token": token,
    "settlement": settlement,
    "agentExecutor": executor,
    "invoiceId": invoice_id,
    "termsHash": terms_hash,
    "dueAt": int(due_at),
    "deployer": deployer,
    "payer": payer,
    "beneficiary": beneficiary
}
Path("deployments-sepolia.json").write_text(json.dumps(record, indent=2) + "\n")
Path("ui/config.js").write_text(
    "window.AEGIS_CONFIG = " + json.dumps({
        "chainId": 11155111,
        "token": token,
        "settlement": settlement,
        "agentExecutor": executor,
        "invoiceId": invoice_id
    }, indent=2) + ";\n"
)
print("\nWrote deployment config using public addresses only.")
print(json.dumps(record, indent=2))
PY

unset KEY
echo "Deployment steps completed. Verify receipts and code before using the UI."
