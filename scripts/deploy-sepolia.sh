#!/usr/bin/env bash
# Sequential Sepolia deployment with explicit per-transaction gas limits.
# Requires DEPLOYER_PRIVATE_KEY, PAYER_ADDRESS, BENEFICIARY_ADDRESS in env.
set -euo pipefail
set +x
cd "$(dirname "$0")/.."

SEPOLIA_RPC_URL="${SEPOLIA_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
# Explicitly bump fees above stale low-fee transactions in the Sepolia mempool.
TX_MAX_FEE_PER_GAS="${TX_MAX_FEE_PER_GAS:-10000000}"
TX_PRIORITY_FEE_PER_GAS="${TX_PRIORITY_FEE_PER_GAS:-5000000}"
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
  local constructor_signature="$3"
  shift 3
  local constructor_args=("$@")
  local bytecode encoded payload estimate_hex gas_limit output address nonce

  # Sepolia activated Glamsterdam on 2026-10-06, which repriced state creation.
  # Estimate with the live RPC, then add 35% headroom. EIP-7825 caps a tx at
  # 16,777,216 gas, so stop before broadcast if a safe limit would exceed it.
  bytecode="$(forge inspect "$artifact" bytecode)"
  encoded="$(cast abi-encode "$constructor_signature" "${constructor_args[@]}")"
  payload="${bytecode}${encoded#0x}"
  if ! estimate_hex="$(cast rpc --rpc-url "$SEPOLIA_RPC_URL" eth_estimateGas \
      "{\"from\":\"$DEPLOYER_ADDRESS\",\"data\":\"$payload\"}")"; then
    echo "FAILED: could not estimate gas for $label. No transaction sent." >&2
    return 1
  fi
  if ! gas_limit="$(python3 - "$estimate_hex" <<'GASPY'
import sys
try:
    estimate = int(sys.argv[1].strip().strip('"'), 16)
except (ValueError, IndexError):
    print("Invalid eth_estimateGas response", file=sys.stderr)
    raise SystemExit(1)
limit = ((estimate * 135 + 99) // 100)
limit = ((limit + 9999) // 10000) * 10000
max_tx_gas = 16_700_000
if estimate <= 0 or limit > max_tx_gas:
    print(f"Estimated gas {estimate:,}; safe limit {limit:,} exceeds configured cap {max_tx_gas:,}.", file=sys.stderr)
    raise SystemExit(1)
print(limit)
GASPY
  )"; then
    echo "FAILED: no safe gas limit established for $label. No transaction sent." >&2
    return 1
  fi
  # Explicit pending nonce avoids Forge reusing a stale nonce from this RPC.
  if ! nonce="$(cast nonce "$DEPLOYER_ADDRESS" --block pending --rpc-url "$SEPOLIA_RPC_URL")" ||
      [[ ! "$nonce" =~ ^[0-9]+$ ]]; then
    echo "FAILED: could not read pending nonce for $label. No transaction sent." >&2
    return 1
  fi
  echo "Deploying $label (RPC estimate: $((gas_limit * 100 / 135)) gas; limit with 35% headroom: $gas_limit; nonce: $nonce)..." >&2
  if ! output="$(forge create "$artifact" \
      --rpc-url "$SEPOLIA_RPC_URL" \
      --private-key "$KEY" \
      --nonce "$nonce" \
      --gas-limit "$gas_limit" \
      --gas-price "$TX_MAX_FEE_PER_GAS" \
      --priority-gas-price "$TX_PRIORITY_FEE_PER_GAS" \
      --timeout 60 \
      --broadcast \
      --constructor-args "${constructor_args[@]}" 2>&1)"; then
    printf '%s\n' "$output" >&2
    echo "FAILED: $label. Stopping; no later transaction will be sent." >&2
    return 1
  fi
  printf '%s\n' "$output" >&2
  address="$(printf '%s\n' "$output" | sed -nE 's/^Deployed to: (0x[0-9a-fA-F]{40}).*/\1/p' | tail -n 1)"
  tx_hash="$(printf '%s\n' "$output" | sed -nE 's/^Transaction hash: (0x[0-9a-fA-F]{64}).*/\1/p' | tail -n 1)"
  if [[ -z "$address" || -z "$tx_hash" ]]; then
    echo "Could not parse deployed address or transaction hash for $label. Inspect output above." >&2
    return 1
  fi

  local receipt status code
  receipt=""
  for _ in $(seq 1 30); do
    receipt="$(cast receipt "$tx_hash" --rpc-url "$SEPOLIA_RPC_URL" --json 2>/dev/null || true)"
    if [[ -n "$receipt" && "$receipt" != "null" ]]; then break; fi
    sleep 2
  done
  status="$(printf '%s' "$receipt" | python3 -c 'import json,sys;
try: print(int(json.load(sys.stdin).get("status", "0x0"), 16))
except Exception: print(0)')"
  if [[ "$status" != "1" ]]; then
    echo "FAILED: $label transaction did not succeed (status=$status, tx=$tx_hash). Refusing to continue." >&2
    printf '%s\n' "$receipt" >&2
    return 1
  fi
  code="$(cast code "$address" --rpc-url "$SEPOLIA_RPC_URL")"
  if [[ "$code" == "0x" || ${#code} -le 2 ]]; then
    echo "FAILED: $label receipt succeeded but no bytecode is visible at $address. Refusing to continue." >&2
    return 1
  fi
  echo "Confirmed $label: $address (tx=$tx_hash, code bytes=$(( (${#code} - 2) / 2 )))" >&2
  printf '%s\n' "$address"
}

verify_existing_contract() {
  local label="$1"
  local address="$2"
  local code
  if [[ ! "$address" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "FAILED: invalid EXISTING address for $label." >&2
    return 1
  fi
  code="$(cast code "$address" --rpc-url "$SEPOLIA_RPC_URL")"
  if [[ "$code" == "0x" || ${#code} -le 2 ]]; then
    echo "FAILED: no bytecode at supplied $label address $address." >&2
    return 1
  fi
  echo "Reusing verified $label: $address (code bytes=$(( (${#code} - 2) / 2 )))" >&2
  printf '%s\n' "$address"
}

send_and_confirm() {
  local label="$1"
  local target="$2"
  local signature="$3"
  shift 3
  local output tx_hash receipt status nonce calldata estimate_hex gas_limit

  # Estimate this exact call on the live chain; a fixed 500k cap became too small
  # after Sepolia's October protocol upgrade.
  if ! calldata="$(cast calldata "$signature" "$@")"; then
    echo "FAILED: could not encode calldata for $label. No transaction sent." >&2
    return 1
  fi
  if ! estimate_hex="$(cast rpc --rpc-url "$SEPOLIA_RPC_URL" eth_estimateGas \
      "{\"from\":\"$DEPLOYER_ADDRESS\",\"to\":\"$target\",\"data\":\"$calldata\"}")"; then
    echo "FAILED: could not estimate gas for $label. No transaction sent." >&2
    return 1
  fi
  if ! gas_limit="$(python3 - "$estimate_hex" <<'GASPY'
import sys
try:
    estimate = int(sys.argv[1].strip().strip('"'), 16)
except (ValueError, IndexError):
    print("Invalid eth_estimateGas response", file=sys.stderr)
    raise SystemExit(1)
limit = ((estimate * 135 + 99) // 100)
limit = ((limit + 9999) // 10000) * 10000
max_tx_gas = 16_700_000
if estimate <= 0 or limit > max_tx_gas:
    print(f"Estimated gas {estimate:,}; safe limit {limit:,} exceeds configured cap {max_tx_gas:,}.", file=sys.stderr)
    raise SystemExit(1)
print(limit)
GASPY
  )"; then
    echo "FAILED: no safe gas limit established for $label. No transaction sent." >&2
    return 1
  fi
  if ! nonce="$(cast nonce "$DEPLOYER_ADDRESS" --block pending --rpc-url "$SEPOLIA_RPC_URL")" ||
      [[ ! "$nonce" =~ ^[0-9]+$ ]]; then
    echo "FAILED: could not read pending nonce for $label. No transaction sent." >&2
    return 1
  fi
  echo "Sending $label (RPC estimate: $((gas_limit * 100 / 135)) gas; limit with 35% headroom: $gas_limit; nonce: $nonce)..." >&2
  if ! output="$(cast send "$target" "$signature" "$@" \
      --rpc-url "$SEPOLIA_RPC_URL" \
      --private-key "$KEY" \
      --nonce "$nonce" \
      --gas-limit "$gas_limit" \
      --gas-price "$TX_MAX_FEE_PER_GAS" \
      --priority-gas-price "$TX_PRIORITY_FEE_PER_GAS" \
      --timeout 60 2>&1)"; then
    printf '%s\n' "$output" >&2
    echo "FAILED: $label transaction submission. Stopping." >&2
    return 1
  fi
  printf '%s\n' "$output" >&2
  tx_hash="$(printf '%s\n' "$output" | grep -Eo '0x[0-9a-fA-F]{64}' | tail -n 1)"
  if [[ -z "$tx_hash" ]]; then
    echo "Could not parse $label transaction hash; refusing to claim success." >&2
    return 1
  fi
  receipt="$(cast receipt "$tx_hash" --rpc-url "$SEPOLIA_RPC_URL" --json)"
  status="$(printf '%s' "$receipt" | python3 -c 'import json,sys;
try: print(int(json.load(sys.stdin).get("status", "0x0"), 16))
except Exception: print(0)')"
  if [[ "$status" != "1" ]]; then
    echo "FAILED: $label transaction status=$status (tx=$tx_hash). Stopping." >&2
    printf '%s\n' "$receipt" >&2
    return 1
  fi
  echo "$label confirmed: $tx_hash" >&2
}

# Set EXISTING_*_ADDRESS to reuse a verified deployment after a partial run.
# This prevents retrying a whole deployment from creating duplicate token/escrow contracts.
if [[ -n "${EXISTING_TOKEN_ADDRESS:-}" ]]; then
  TOKEN="$(verify_existing_contract "DemoSettlementToken" "$EXISTING_TOKEN_ADDRESS")"
else
  TOKEN="$(deploy_contract "DemoSettlementToken" "contracts/DemoSettlementToken.sol:DemoSettlementToken" 'constructor(address)' "$DEPLOYER_ADDRESS")"
fi
if [[ -n "${EXISTING_SETTLEMENT_ADDRESS:-}" ]]; then
  SETTLEMENT="$(verify_existing_contract "InvoiceSettlement" "$EXISTING_SETTLEMENT_ADDRESS")"
else
  SETTLEMENT="$(deploy_contract "InvoiceSettlement" "contracts/InvoiceSettlement.sol:InvoiceSettlement" 'constructor(address)' "$DEPLOYER_ADDRESS")"
fi
if [[ -n "${EXISTING_EXECUTOR_ADDRESS:-}" ]]; then
  EXECUTOR="$(verify_existing_contract "DemoAgentExecutor" "$EXISTING_EXECUTOR_ADDRESS")"
else
  EXECUTOR="$(deploy_contract "DemoAgentExecutor" "contracts/DemoAgentExecutor.sol:DemoAgentExecutor" 'constructor(address,address)' "$SETTLEMENT" "$PAYER_ADDRESS")"
fi

INVOICE_ID="$(cast keccak 'INV-1001')"
TERMS_HASH="$(cast keccak 'INV-1001|Synthetic invoice|10000 dUSD|NET30|v1')"
FACE_VALUE=10000000000

# Inspect invoice storage first so a retry after a partial run does not collide
# with InvoiceExists or write a mismatched dueAt into the public config.
read_invoice_state() {
  local raw
  raw="$(cast call "$SETTLEMENT" "invoices(bytes32)" "$INVOICE_ID" --rpc-url "$SEPOLIA_RPC_URL")"
  python3 - "$raw" "$DEPLOYER_ADDRESS" "$PAYER_ADDRESS" "$BENEFICIARY_ADDRESS" "$TOKEN" "$FACE_VALUE" "$TERMS_HASH" <<'INVOICEPY'
import sys
raw, issuer, payer, beneficiary, token, face_value, terms_hash = sys.argv[1:]
data = raw.strip()
if data.startswith("0x"): data = data[2:]
if len(data) != 10 * 64:
    print(f"Unexpected invoice getter response length: {len(data)}", file=sys.stderr)
    raise SystemExit(1)
w = [data[i:i+64].lower() for i in range(0, len(data), 64)]
addr = lambda word: "0x" + word[-40:]
status = int(w[9], 16)
if status == 0:
    print("MISSING")
    raise SystemExit(0)
expected = {
    "issuer": (addr(w[0]), issuer.lower()),
    "payer": (addr(w[1]), payer.lower()),
    "beneficiary": (addr(w[2]), beneficiary.lower()),
    "token": (addr(w[3]), token.lower()),
    "faceValue": (int(w[4],16), int(face_value)),
    "termsHash": ("0x" + w[8], terms_hash.lower()),
}
mismatches = [f"{k}: onchain={got}, expected={want}" for k, (got,want) in expected.items() if got != want]
if mismatches:
    print("Existing invoice differs from expected deployment configuration: " + "; ".join(mismatches), file=sys.stderr)
    raise SystemExit(2)
print(f"EXISTS:{int(w[7],16)}")
INVOICEPY
}

INVOICE_STATE="$(read_invoice_state)"
if [[ "$INVOICE_STATE" == "MISSING" ]]; then
  CHAIN_TIMESTAMP="$(cast block latest --rpc-url "$SEPOLIA_RPC_URL" --json | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["timestamp"], 16))')"
  DUE_AT="$((CHAIN_TIMESTAMP + 2592000))"
  send_and_confirm "register invoice" "$SETTLEMENT" \
    "registerInvoice(bytes32,address,address,address,uint128,uint64,bytes32)" \
    "$INVOICE_ID" "$PAYER_ADDRESS" "$BENEFICIARY_ADDRESS" "$TOKEN" \
    "$FACE_VALUE" "$DUE_AT" "$TERMS_HASH"
  INVOICE_STATE="$(read_invoice_state)"
fi
if [[ "$INVOICE_STATE" != EXISTS:* ]]; then
  echo "FAILED: invoice registration state not confirmed. State=$INVOICE_STATE" >&2
  exit 1
fi
DUE_AT="$(printf '%s' "$INVOICE_STATE" | cut -d: -f2)"
echo "Invoice registration verified onchain (dueAt=$DUE_AT)." >&2

BALANCE="$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$PAYER_ADDRESS" --rpc-url "$SEPOLIA_RPC_URL")"
if [[ ! "$BALANCE" =~ ^[0-9]+$ ]]; then
  echo "FAILED: could not parse payer token balance; refusing to mint." >&2
  exit 1
fi
if (( BALANCE < FACE_VALUE )); then
  MINT_AMOUNT="$((FACE_VALUE - BALANCE))"
  send_and_confirm "mint demo settlement balance" "$TOKEN" \
    "mint(address,uint256)" "$PAYER_ADDRESS" "$MINT_AMOUNT"
else
  echo "Payer already holds sufficient demo settlement tokens ($BALANCE); skipping duplicate mint." >&2
fi

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
