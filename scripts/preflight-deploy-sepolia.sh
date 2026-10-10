#!/usr/bin/env bash
# Read-only preflight for a fresh hardened Sepolia deployment. Never broadcasts.
set -euo pipefail
set +x
cd "$(dirname "$0")/.."

RPC="${SEPOLIA_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
DEPLOYER_ADDRESS="${DEPLOYER_ADDRESS:-}"
PAYER_ADDRESS="${PAYER_ADDRESS:-}"
BENEFICIARY_ADDRESS="${BENEFICIARY_ADDRESS:-}"
AGENT_OWNER_ADDRESS="${AGENT_OWNER_ADDRESS:-}"
BUFFER_WEI="${DEPLOYMENT_BUFFER_WEI:-5000000000000000}"

for name in DEPLOYER_ADDRESS PAYER_ADDRESS BENEFICIARY_ADDRESS AGENT_OWNER_ADDRESS; do
  value="${!name}"
  if [[ ! "$value" =~ ^0x[0-9a-fA-F]{40}$ || "${value,,}" == "0x0000000000000000000000000000000000000000" ]]; then
    echo "Set $name to a non-zero 20-byte address. No transaction sent." >&2
    exit 1
  fi
done
if [[ "${PAYER_ADDRESS,,}" == "${AGENT_OWNER_ADDRESS,,}" ]]; then
  echo "Payer and agent owner must be separate addresses. No transaction sent." >&2
  exit 1
fi
if [[ ! "$BUFFER_WEI" =~ ^[0-9]+$ ]]; then
  echo "DEPLOYMENT_BUFFER_WEI must be a non-negative integer. No transaction sent." >&2
  exit 1
fi

CHAIN_ID="$(cast chain-id --rpc-url "$RPC")"
if [[ "$CHAIN_ID" != "11155111" ]]; then
  echo "RPC chain ID is $CHAIN_ID, expected Sepolia 11155111. No transaction sent." >&2
  exit 1
fi

MAX_FEE="${TX_MAX_FEE_PER_GAS:-}"
PRIORITY_FEE="${TX_PRIORITY_FEE_PER_GAS:-}"
if [[ -z "$MAX_FEE" || -z "$PRIORITY_FEE" ]]; then
  GAS_PRICE="$(cast rpc --rpc-url "$RPC" eth_gasPrice)"
  PRIORITY_RPC="$(cast rpc --rpc-url "$RPC" eth_maxPriorityFeePerGas 2>/dev/null || true)"
  BASE_FEE="$(cast block latest --rpc-url "$RPC" --json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("baseFeePerGas") or "")')"
  read -r DEFAULT_MAX DEFAULT_PRIORITY < <(python3 scripts/fee_policy.py "$GAS_PRICE" "$PRIORITY_RPC" "$BASE_FEE")
  MAX_FEE="${MAX_FEE:-$DEFAULT_MAX}"
  PRIORITY_FEE="${PRIORITY_FEE:-$DEFAULT_PRIORITY}"
fi
if [[ ! "$MAX_FEE" =~ ^[0-9]+$ || ! "$PRIORITY_FEE" =~ ^[0-9]+$ ]] ||
   (( PRIORITY_FEE > MAX_FEE )); then
  echo "Invalid EIP-1559 fee values. No transaction sent." >&2
  exit 1
fi

DEPLOYER_BALANCE="$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$RPC")"
PAYER_BALANCE="$(cast balance "$PAYER_ADDRESS" --rpc-url "$RPC")"
AGENT_BALANCE="$(cast balance "$AGENT_OWNER_ADDRESS" --rpc-url "$RPC")"
if [[ ! "$DEPLOYER_BALANCE" =~ ^[0-9]+$ || ! "$PAYER_BALANCE" =~ ^[0-9]+$ || ! "$AGENT_BALANCE" =~ ^[0-9]+$ ]]; then
  echo "Could not parse one or more wallet balances. No transaction sent." >&2
  exit 1
fi

reserve_constructor() {
  local label="$1"
  local artifact="$2"
  local signature="$3"
  local headroom="$4"
  shift 4
  local args=("$@")
  local bytecode encoded payload estimate_hex estimate gas_limit reserve

  bytecode="$(forge inspect "$artifact" bytecode)"
  encoded="$(cast abi-encode "$signature" "${args[@]}")"
  payload="${bytecode}${encoded#0x}"
  estimate_hex="$(cast rpc --rpc-url "$RPC" eth_estimateGas \
    "{\"from\":\"$DEPLOYER_ADDRESS\",\"data\":\"$payload\"}")"
  read -r estimate gas_limit reserve < <(python3 - "$estimate_hex" "$headroom" "$MAX_FEE" <<'PY'
import sys
try:
    estimate = int(sys.argv[1].strip().strip('"'), 16)
    headroom = int(sys.argv[2])
    max_fee = int(sys.argv[3])
except (ValueError, IndexError) as exc:
    print("Invalid gas-estimation inputs", file=sys.stderr)
    raise SystemExit(1) from exc
gas_limit = ((estimate * (100 + headroom) + 99) // 100)
gas_limit = ((gas_limit + 9999) // 10000) * 10000
if estimate <= 0 or gas_limit > 16_700_000:
    print(f"Estimate {estimate:,}; limit {gas_limit:,} exceeds safety cap for a single deployment transaction.", file=sys.stderr)
    raise SystemExit(1)
print(estimate, gas_limit, gas_limit * max_fee)
PY
)
  printf '%s\n' "$reserve"
  echo "$label: estimate=$estimate gas; limit=$gas_limit; max-fee reserve=$(python3 -c 'import sys; print(int(sys.argv[1])/1e18)' "$reserve") SepoliaETH" >&2
}

echo "Read-only Sepolia preflight. No transaction will be sent."
echo "Deployer: $DEPLOYER_ADDRESS"
echo "Payer: $PAYER_ADDRESS"
echo "Beneficiary: $BENEFICIARY_ADDRESS"
echo "Agent owner: $AGENT_OWNER_ADDRESS"
echo "Fee quote: maxFeePerGas=$MAX_FEE wei; priority=$PRIORITY_FEE wei"

TOKEN_RESERVE="$(reserve_constructor "DemoSettlementToken" "contracts/DemoSettlementToken.sol:DemoSettlementToken" 'constructor(address)' 35 "$DEPLOYER_ADDRESS")"
SETTLEMENT_RESERVE="$(reserve_constructor "InvoiceSettlement" "contracts/InvoiceSettlement.sol:InvoiceSettlement" 'constructor(address)' 5 "$DEPLOYER_ADDRESS")"
# Constructor arguments are fixed-size addresses; their values do not affect creation gas.
EXECUTOR_RESERVE="$(reserve_constructor "DemoAgentExecutor" "contracts/DemoAgentExecutor.sol:DemoAgentExecutor" 'constructor(address,address)' 35 "0x1111111111111111111111111111111111111111" "$AGENT_OWNER_ADDRESS")"
TOTAL_CONSTRUCTOR_RESERVE=$((TOKEN_RESERVE + SETTLEMENT_RESERVE + EXECUTOR_RESERVE))
TOTAL_REQUIRED=$((TOTAL_CONSTRUCTOR_RESERVE + BUFFER_WEI))

echo "Constructor reserve total: $(python3 -c 'import sys; print(int(sys.argv[1])/1e18)' "$TOTAL_CONSTRUCTOR_RESERVE") SepoliaETH"
echo "Additional transaction buffer: $(python3 -c 'import sys; print(int(sys.argv[1])/1e18)' "$BUFFER_WEI") SepoliaETH"
echo "Deployer balance: $(python3 -c 'import sys; print(int(sys.argv[1])/1e18)' "$DEPLOYER_BALANCE") SepoliaETH"
echo "Payer balance for accept/fund/authorize transactions: $(python3 -c 'import sys; print(int(sys.argv[1])/1e18)' "$PAYER_BALANCE") SepoliaETH"
echo "Agent-owner balance for later execution transactions: $(python3 -c 'import sys; print(int(sys.argv[1])/1e18)' "$AGENT_BALANCE") SepoliaETH"

if (( DEPLOYER_BALANCE < TOTAL_REQUIRED )); then
  echo "INSUFFICIENT DEPLOYER BALANCE: constructor reserve plus buffer exceeds current balance. No transaction sent." >&2
  exit 2
fi
if (( PAYER_BALANCE == 0 )); then
  echo "WARNING: payer has no Sepolia ETH for wallet transactions; acceptance/funding/authorization will fail until funded." >&2
fi
if (( AGENT_BALANCE == 0 )); then
  echo "WARNING: agent owner has no Sepolia ETH for relayed execution transactions." >&2
fi

echo "PASS: estimated constructor reserve and configured buffer fit the deployer balance."
echo "This is a gas preflight only; it does not deploy, accept, fund, authorize, or transfer any token."
