#!/usr/bin/env bash
# Deploy only the upgraded signed-intent executor against the configured Sepolia settlement.
# This preserves the existing settlement, invoice, token and payment history.
set -euo pipefail
set +x
cd "$(dirname "$0")/.."

RPC_URL="${SEPOLIA_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
CONFIG_PATH="${DEPLOYMENT_CONFIG:-deployments-sepolia.json}"
UI_CONFIG_PATH="${UI_CONFIG_PATH:-ui/config.js}"
MAX_FEE="${TX_MAX_FEE_PER_GAS:-}"
PRIORITY_FEE="${TX_PRIORITY_FEE_PER_GAS:-}"
if [[ -z "$MAX_FEE" || -z "$PRIORITY_FEE" ]]; then
  GAS_PRICE_HEX="$(cast rpc --rpc-url "$RPC_URL" eth_gasPrice)"
  PRIORITY_HEX="$(cast rpc --rpc-url "$RPC_URL" eth_maxPriorityFeePerGas 2>/dev/null || true)"
  BASE_FEE_HEX="$(cast block latest --rpc-url "$RPC_URL" --json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("baseFeePerGas") or "")')"
  read -r DEFAULT_MAX_FEE DEFAULT_PRIORITY_FEE < <(
    python3 scripts/fee_policy.py "$GAS_PRICE_HEX" "$PRIORITY_HEX" "$BASE_FEE_HEX"
  )
  MAX_FEE="${MAX_FEE:-$DEFAULT_MAX_FEE}"
  PRIORITY_FEE="${PRIORITY_FEE:-$DEFAULT_PRIORITY_FEE}"
fi
if [[ ! "$MAX_FEE" =~ ^[0-9]+$ || ! "$PRIORITY_FEE" =~ ^[0-9]+$ ]] ||
   (( PRIORITY_FEE > MAX_FEE )); then
  echo "Invalid EIP-1559 fee configuration: max=$MAX_FEE priority=$PRIORITY_FEE. No transaction sent." >&2
  exit 1
fi
echo "Using transaction fees: maxFeePerGas=$MAX_FEE wei; maxPriorityFeePerGas=$PRIORITY_FEE wei." >&2

if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
  echo "Set DEPLOYER_PRIVATE_KEY in the environment. It is never written to config." >&2
  exit 1
fi
if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Deployment config not found: $CONFIG_PATH. No transaction sent." >&2
  exit 1
fi

read_config_value() {
  python3 - "$CONFIG_PATH" "$1" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
value = data.get(sys.argv[2])
if value is None:
    print(f"Missing {sys.argv[2]} in deployment config", file=sys.stderr)
    raise SystemExit(1)
print(value)
PY
}

EXPECTED_CHAIN_ID="$(read_config_value chainId)"
SETTLEMENT="${EXISTING_SETTLEMENT_ADDRESS:-$(read_config_value settlement)}"
TOKEN="$(read_config_value token)"
INVOICE_ID="$(read_config_value invoiceId)"
CONFIG_OWNER="$(read_config_value agentOwner)"
OWNER="${AGENT_OWNER_ADDRESS:-$CONFIG_OWNER}"

if [[ ! "$SETTLEMENT" =~ ^0x[0-9a-fA-F]{40}$ || ! "$OWNER" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "Settlement or agent-owner address is invalid. No transaction sent." >&2
  exit 1
fi
if [[ "${OWNER,,}" != "${CONFIG_OWNER,,}" ]]; then
  echo "AGENT_OWNER_ADDRESS differs from the configured owner; refusing to change signer identity." >&2
  exit 1
fi
python3 - "$CONFIG_PATH" "$SETTLEMENT" <<'PY'
import json, sys
from pathlib import Path
cfg = json.loads(Path(sys.argv[1]).read_text())
if str(cfg["settlement"]).lower() != sys.argv[2].lower():
    print("Settlement override differs from deployment config; use a matching config copy.", file=sys.stderr)
    raise SystemExit(1)
PY

python3 - "$UI_CONFIG_PATH" "$SETTLEMENT" "$OWNER" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
if not path.is_file():
    print(f"UI config not found: {path}. No transaction sent.", file=sys.stderr)
    raise SystemExit(1)
text = path.read_text()
prefix = "window.RWA_AGENT_GUARDIAN_CONFIG = "
if not text.startswith(prefix) or not text.rstrip().endswith(";"):
    print(f"Unexpected UI config format in {path}. No transaction sent.", file=sys.stderr)
    raise SystemExit(1)
data = json.loads(text[len(prefix):].strip()[:-1])
if data.get("settlement", "").lower() != sys.argv[2].lower():
    print("UI settlement differs from configured target. No transaction sent.", file=sys.stderr)
    raise SystemExit(1)
if data.get("agentOwner", "").lower() != sys.argv[3].lower():
    print("UI agentOwner differs from configured owner. No transaction sent.", file=sys.stderr)
    raise SystemExit(1)
PY

if [[ "$(cast chain-id --rpc-url "$RPC_URL")" != "$EXPECTED_CHAIN_ID" ]]; then
  echo "RPC chain does not match configured chainId $EXPECTED_CHAIN_ID. No transaction sent." >&2
  exit 1
fi
if [[ "$EXPECTED_CHAIN_ID" != "11155111" ]]; then
  echo "This helper is restricted to Sepolia (11155111). No transaction sent." >&2
  exit 1
fi

for pair in "settlement:$SETTLEMENT" "token:$TOKEN"; do
  label="${pair%%:*}"
  address="${pair#*:}"
  code="$(cast code "$address" --rpc-url "$RPC_URL")"
  if [[ -z "$code" || "$code" == "0x" ]]; then
    echo "No bytecode at configured $label address $address. No transaction sent." >&2
    exit 1
  fi
done

if ! SETTLEMENT_VERSION="$(cast call "$SETTLEMENT" "SETTLEMENT_VERSION()(uint256)" --rpc-url "$RPC_URL" 2>/dev/null)"; then
  echo "Configured settlement predates SETTLEMENT_VERSION=2 and the ESCALATED dispute lifecycle." >&2
  echo "Use scripts/deploy-sepolia.sh to deploy a fresh current-source settlement and executor. No transaction sent." >&2
  exit 1
fi
if [[ "$SETTLEMENT_VERSION" != "2" ]]; then
  echo "Configured settlement version is $SETTLEMENT_VERSION, expected 2. No transaction sent." >&2
  exit 1
fi

INVOICE_RAW="$(cast call "$SETTLEMENT" "invoices(bytes32)" "$INVOICE_ID" --rpc-url "$RPC_URL")"
python3 - "$INVOICE_RAW" "$TOKEN" <<'PY'
import sys
raw = sys.argv[1].strip().removeprefix("0x")
if len(raw) != 10 * 64:
    print("Invoice getter response has an unexpected ABI length.", file=sys.stderr)
    raise SystemExit(1)
words = [raw[i:i+64].lower() for i in range(0, len(raw), 64)]
token = "0x" + words[3][-40:]
status = int(words[9], 16)
if status == 0:
    print("Configured invoice does not exist on the configured settlement. No transaction sent.", file=sys.stderr)
    raise SystemExit(1)
if token != sys.argv[2].lower():
    print("On-chain invoice token does not match config. No transaction sent.", file=sys.stderr)
    raise SystemExit(1)
PY

KEY="$DEPLOYER_PRIVATE_KEY"
if [[ "$KEY" != 0x* && "$KEY" != 0X* ]]; then KEY="0x$KEY"; fi
DEPLOYER_ADDRESS="$(cast wallet address --private-key "$KEY")"
echo "Deploying signed-intent executor only; settlement and invoice state will not be changed." >&2
echo "Deployer: $DEPLOYER_ADDRESS; settlement: $SETTLEMENT; owner: $OWNER" >&2

BYTECODE="$(forge inspect contracts/DemoAgentExecutor.sol:DemoAgentExecutor bytecode)"
ENCODED="$(cast abi-encode 'constructor(address,address)' "$SETTLEMENT" "$OWNER")"
PAYLOAD="${BYTECODE}${ENCODED#0x}"
ESTIMATE_HEX="$(cast rpc --rpc-url "$RPC_URL" eth_estimateGas "{\"from\":\"$DEPLOYER_ADDRESS\",\"data\":\"$PAYLOAD\"}")"
GAS_LIMIT="$(python3 - "$ESTIMATE_HEX" <<'PY'
import sys
try:
    estimate = int(sys.argv[1].strip().strip('"'), 16)
except (ValueError, IndexError):
    print("Invalid eth_estimateGas response", file=sys.stderr)
    raise SystemExit(1)
limit = ((estimate * 135 + 99) // 100)
limit = ((limit + 9999) // 10000) * 10000
if estimate <= 0 or limit > 16_700_000:
    print(f"Estimated gas {estimate:,}; safe limit {limit:,} exceeds configured cap.", file=sys.stderr)
    raise SystemExit(1)
print(limit)
PY
)"
NONCE="$(cast nonce "$DEPLOYER_ADDRESS" --block pending --rpc-url "$RPC_URL")"
if [[ ! "$NONCE" =~ ^[0-9]+$ ]]; then
  echo "Could not read pending deployer nonce. No transaction sent." >&2
  exit 1
fi

OUTPUT="$(forge create contracts/DemoAgentExecutor.sol:DemoAgentExecutor \
  --rpc-url "$RPC_URL" --private-key "$KEY" --nonce "$NONCE" --gas-limit "$GAS_LIMIT" \
  --gas-price "$MAX_FEE" --priority-gas-price "$PRIORITY_FEE" --timeout 60 --broadcast \
  --constructor-args "$SETTLEMENT" "$OWNER" 2>&1)" || {
    printf '%s\n' "$OUTPUT" >&2
    echo "Executor deployment failed. Config files were not changed." >&2
    exit 1
  }
printf '%s\n' "$OUTPUT" >&2
EXECUTOR="$(printf '%s\n' "$OUTPUT" | sed -nE 's/^Deployed to: (0x[0-9a-fA-F]{40}).*/\1/p' | tail -n 1)"
TX_HASH="$(printf '%s\n' "$OUTPUT" | sed -nE 's/^Transaction hash: (0x[0-9a-fA-F]{64}).*/\1/p' | tail -n 1)"
if [[ -z "$EXECUTOR" || -z "$TX_HASH" ]]; then
  echo "Could not parse deployment address or tx hash. Inspect output; config files were not changed." >&2
  exit 1
fi

RECEIPT=""
for _ in $(seq 1 30); do
  RECEIPT="$(cast receipt "$TX_HASH" --rpc-url "$RPC_URL" --json 2>/dev/null || true)"
  if [[ -n "$RECEIPT" && "$RECEIPT" != "null" ]]; then break; fi
  sleep 2
done
STATUS="$(printf '%s' "$RECEIPT" | python3 -c 'import json,sys
try: print(int(json.load(sys.stdin).get("status", "0x0"), 16))
except Exception: print(0)')"
if [[ "$STATUS" != "1" ]]; then
  echo "Executor deployment receipt is not successful (status=$STATUS). Config files were not changed." >&2
  exit 1
fi

CODE="$(cast code "$EXECUTOR" --rpc-url "$RPC_URL")"
ACTUAL_SETTLEMENT="$(cast call "$EXECUTOR" "settlement()(address)" --rpc-url "$RPC_URL")"
ACTUAL_OWNER="$(cast call "$EXECUTOR" "owner()(address)" --rpc-url "$RPC_URL")"
DOMAIN="$(cast call "$EXECUTOR" "intentDomainSeparator()(bytes32)" --rpc-url "$RPC_URL")"
if [[ "$CODE" == "0x" || "${ACTUAL_SETTLEMENT,,}" != "${SETTLEMENT,,}" || "${ACTUAL_OWNER,,}" != "${OWNER,,}" || ! "$DOMAIN" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
  echo "New executor bytecode or immutable bindings failed verification. Config files were not changed." >&2
  exit 1
fi

python3 - "$CONFIG_PATH" "$UI_CONFIG_PATH" "$SETTLEMENT" "$OWNER" "$EXECUTOR" <<'PY'
import json, sys
from pathlib import Path
config_path, ui_path, settlement, owner, executor = map(str, sys.argv[1:])
config_file = Path(config_path)
config = json.loads(config_file.read_text())
if config["settlement"].lower() != settlement.lower() or config["agentOwner"].lower() != owner.lower():
    print("Config changed during deployment; refusing to overwrite it.", file=sys.stderr)
    raise SystemExit(1)
config["agentExecutor"] = executor
temp_path = config_file.with_suffix(config_file.suffix + ".tmp")
temp_path.write_text(json.dumps(config, indent=2) + "\n")
temp_path.replace(config_file)

ui_file = Path(ui_path)
ui_text = ui_file.read_text()
prefix = "window.RWA_AGENT_GUARDIAN_CONFIG = "
if not ui_text.startswith(prefix) or not ui_text.rstrip().endswith(";"):
    print(f"Unexpected UI config format in {ui_file}; deployment is complete but config update failed.", file=sys.stderr)
    raise SystemExit(1)
ui_data = json.loads(ui_text[len(prefix):].strip()[:-1])
if ui_data["settlement"].lower() != settlement.lower() or ui_data["agentOwner"].lower() != owner.lower():
    print("UI settlement or agent owner differs from deployed values; config update failed.", file=sys.stderr)
    raise SystemExit(1)
ui_data["agentExecutor"] = executor
ui_file.write_text(prefix + json.dumps(ui_data, indent=2) + ";\n")
print(f"Updated {config_file} and {ui_file} with executor {executor}")
PY

unset KEY
echo "Verified signed-intent executor deployed at $EXECUTOR (tx=$TX_HASH)."
echo "Next: connect the configured payer in the UI and authorize this new executor before running AGENT_DECISION_MODE=ollama."
