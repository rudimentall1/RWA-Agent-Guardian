#!/usr/bin/env python3
"""Ollama-assisted payment runner with a deterministic policy gate and signed EIP-712 intents.

The model proposes a bounded decision. It does not hold authority: the runner validates
the proposal, and InvoiceSettlement remains the final on-chain enforcement boundary.
Requires Foundry's `cast` on PATH. No model response is trusted without schema and cap checks.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


POLICY_VERSION = "rwa-agent-policy-v1"
INTENT_DOMAIN_NAME = "RWA Agent Guardian Executor"
INTENT_DOMAIN_VERSION = "1"
DECISION_REASON_CODES = (
    "within_limits",
    "invoice_not_accepted",
    "mandate_unavailable",
    "no_capacity",
    "model_wait",
    "model_block",
)
DECISION_SCHEMA = {
    "type": "object",
    "properties": {
        "decision": {"type": "string", "enum": ["ALLOW", "WAIT", "BLOCK"]},
        "amount": {"type": "integer", "minimum": 0},
        "reason": {"type": "string", "enum": list(DECISION_REASON_CODES)},
    },
    "required": ["decision", "amount", "reason"],
    "additionalProperties": False,
}
ADDRESS_RE = re.compile(r"0x[0-9a-fA-F]{40}\Z")
BYTES32_RE = re.compile(r"0x[0-9a-fA-F]{64}\Z")
HASH_RE = re.compile(r"0x[0-9a-fA-F]{64}")


def env(name, default=None):
    value = os.environ.get(name, default)
    if value is None or value == "":
        raise SystemExit(f"Missing required environment variable: {name}")
    return value


def env_bool(name, default=False):
    """Parse an explicit boolean environment flag; reject ambiguous values."""
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    normalized = value.strip().lower()
    if normalized in ("1", "true", "yes", "on"):
        return True
    if normalized in ("0", "false", "no", "off"):
        return False
    raise SystemExit(f"{name} must be a boolean (true/false); no transaction sent")


def cast(*args, json_output=False):
    cmd = ["cast", *args]
    if json_output:
        cmd.append("--json")
    result = subprocess.run(cmd, check=True, text=True, capture_output=True)
    return result.stdout.strip()


def load_agent_private_key():
    """Load the agent signer from an environment variable or a local JSON wallet file."""
    private_key = os.environ.get("AGENT_PRIVATE_KEY")
    if private_key:
        return private_key.strip()
    wallet_path = os.environ.get("AGENT_WALLET_FILE")
    if not wallet_path:
        raise SystemExit("Set AGENT_PRIVATE_KEY or AGENT_WALLET_FILE; keep wallet secrets out of Git.")
    wallet_data = json.loads(Path(wallet_path).read_text())
    entries = wallet_data if isinstance(wallet_data, list) else [wallet_data]
    if not entries or not isinstance(entries[0], dict):
        raise SystemExit("Agent wallet file has an unsupported structure")
    private_key = entries[0].get("private_key")
    if not isinstance(private_key, str) or not private_key.strip():
        raise SystemExit("Agent wallet file does not contain a private key")
    return private_key.strip()


def decode_words(raw, expected_words):
    data = raw.strip()
    if data.startswith("0x"):
        data = data[2:]
    if len(data) != expected_words * 64:
        raise RuntimeError(
            f"Unexpected ABI response length: got {len(data)} hex chars, expected {expected_words * 64}"
        )
    return [int(data[i:i + 64], 16) for i in range(0, len(data), 64)]


def call_words(target, signature, *args, rpc, expected_words):
    raw = cast("call", target, signature, *args, "--rpc-url", rpc)
    return decode_words(raw, expected_words)


def normalize_address(value, name):
    if not isinstance(value, str) or not ADDRESS_RE.fullmatch(value):
        raise SystemExit(f"Invalid {name} address in deployment config")
    return value.lower()


def validate_config_shape(config):
    """Reject malformed or incomplete deployment settings before RPC calls."""
    if not isinstance(config, dict):
        raise SystemExit("Deployment config must be a JSON object")
    chain_id = config.get("chainId")
    if type(chain_id) is not int or chain_id <= 0:
        raise SystemExit("Deployment config must contain a positive integer chainId")
    for key in ("token", "settlement", "agentExecutor", "agentOwner"):
        normalize_address(config.get(key), key)
    invoice_id = config.get("invoiceId")
    if not isinstance(invoice_id, str) or not BYTES32_RE.fullmatch(invoice_id):
        raise SystemExit("Deployment config must contain a 32-byte invoiceId")


def validate_runtime_config(config, rpc, agent_address, require_signed_intent=False):
    """Check chain, deployed code, executor bindings and invoice token before any send."""
    configured_owner = normalize_address(config["agentOwner"], "agentOwner")
    if normalize_address(agent_address, "derived agent") != configured_owner:
        raise SystemExit(
            f"AGENT_PRIVATE_KEY address {agent_address} does not match configured agentOwner {config['agentOwner']}"
        )

    try:
        live_chain_id = int(cast("chain-id", "--rpc-url", rpc))
    except ValueError as exc:
        raise SystemExit("RPC returned an invalid chain ID") from exc
    if live_chain_id != config["chainId"]:
        raise SystemExit(
            f"RPC chain ID {live_chain_id} does not match deployment config {config['chainId']}; no transaction sent"
        )

    for key in ("token", "settlement", "agentExecutor"):
        address = config[key]
        code = cast("code", address, "--rpc-url", rpc)
        if not code or code.strip().lower() == "0x":
            raise SystemExit(f"No contract bytecode found for {key} at {address}; no transaction sent")

    executor = config["agentExecutor"]
    bound_settlement = cast("call", executor, "settlement()(address)", "--rpc-url", rpc)
    bound_owner = cast("call", executor, "owner()(address)", "--rpc-url", rpc)
    if normalize_address(bound_settlement, "executor settlement") != normalize_address(config["settlement"], "settlement"):
        raise SystemExit("Executor is bound to a different settlement contract; no transaction sent")
    if normalize_address(bound_owner, "executor owner") != configured_owner:
        raise SystemExit("Executor owner does not match configured agentOwner; no transaction sent")

    if require_signed_intent:
        try:
            settlement_version = cast(
                "call", config["settlement"], "SETTLEMENT_VERSION()(uint256)", "--rpc-url", rpc
            )
        except subprocess.CalledProcessError as exc:
            raise SystemExit(
                "Configured settlement is legacy and does not expose SETTLEMENT_VERSION=2. "
                "Deploy the current InvoiceSettlement before running AI mode; no transaction sent."
            ) from exc
        if settlement_version.strip() != "2":
            raise SystemExit(
                f"Configured settlement version is {settlement_version.strip()}, expected 2; no transaction sent"
            )

        try:
            domain = cast("call", executor, "intentDomainSeparator()(bytes32)", "--rpc-url", rpc)
        except subprocess.CalledProcessError as exc:
            raise SystemExit(
                "Configured executor does not support EIP-712 signed intents. Deploy the updated "
                "DemoAgentExecutor and authorize that executor on the invoice; no transaction sent."
            ) from exc
        if not BYTES32_RE.fullmatch(domain.strip()):
            raise SystemExit("Executor returned an invalid EIP-712 domain separator; no transaction sent")

    invoice = call_words(
        config["settlement"], "invoices(bytes32)", config["invoiceId"], rpc=rpc, expected_words=10
    )
    invoice_token = f"0x{invoice[3]:040x}"
    if normalize_address(invoice_token, "invoice token") != normalize_address(config["token"], "token"):
        raise SystemExit("Invoice token does not match deployment config; no transaction sent")


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def keccak_text(value):
    """Use Ethereum Keccak-256 via cast (not the incompatible NIST SHA3-256)."""
    result = cast("keccak", value).strip()
    if not BYTES32_RE.fullmatch(result):
        raise SystemExit("cast returned an invalid Keccak-256 hash")
    return result.lower()


def parse_ai_decision(raw, max_allowed):
    """Strictly validate the model proposal. Any ambiguity fails closed."""
    try:
        parsed = json.loads(raw)
    except (TypeError, json.JSONDecodeError) as exc:
        raise SystemExit("AI response is not valid JSON; no transaction sent") from exc
    if not isinstance(parsed, dict) or set(parsed) != {"decision", "amount", "reason"}:
        raise SystemExit("AI response must contain exactly decision, amount, and reason; no transaction sent")

    decision = parsed["decision"]
    amount = parsed["amount"]
    reason = parsed["reason"]
    if decision not in ("ALLOW", "WAIT", "BLOCK"):
        raise SystemExit("AI returned an unsupported decision; no transaction sent")
    if type(amount) is not int or amount < 0:
        raise SystemExit("AI amount must be a non-negative integer in token base units; no transaction sent")
    if not isinstance(reason, str) or reason not in DECISION_REASON_CODES:
        raise SystemExit("AI reason must be one of the allowed policy reason codes; no transaction sent")
    if decision == "ALLOW":
        if max_allowed <= 0 or amount < 1 or amount > max_allowed:
            raise SystemExit(
                f"AI ALLOW amount must be between 1 and the policy maximum {max_allowed}; no transaction sent"
            )
    elif amount != 0:
        raise SystemExit("AI WAIT/BLOCK decisions must use amount 0; no transaction sent")
    return {"decision": decision, "amount": amount, "reason": reason.strip()}


def compact_model_context(context, max_allowed):
    """Expose the minimal decision facts; full chain context stays in signed evidence."""
    invoice = context.get("invoice", {})
    mandate = context.get("mandate", {})
    return {
        "status": invoice.get("status"),
        "observedAt": context.get("observedAt"),
        "mandateActive": mandate.get("active"),
        "mandateExpiresAt": mandate.get("expiresAt"),
        "maxAllowedAmount": max_allowed,
    }


def canonical_decision_reason(context, decision):
    """Check the model's categorical reason against facts and return human-readable text."""
    invoice = context.get("invoice", {})
    mandate = context.get("mandate", {})
    status = invoice.get("status")
    observed_at = context.get("observedAt")
    expires_at = mandate.get("expiresAt")
    active = mandate.get("active") is True
    max_allowed = context.get("maxAllowedAmount", 0)
    choice = decision.get("decision")

    if choice == "ALLOW":
        if (
            status != 2
            or not active
            or type(observed_at) is not int
            or type(expires_at) is not int
            or expires_at < observed_at
            or type(max_allowed) is not int
            or max_allowed <= 0
            or type(decision.get("amount")) is not int
            or not 1 <= decision["amount"] <= max_allowed
        ):
            raise SystemExit("AI ALLOW does not match the checked policy facts; no transaction sent")
        expected_code = "within_limits"
        human_reason = "Within current on-chain caps"
    elif choice == "BLOCK":
        expected_code = "invoice_not_accepted" if status != 2 else "model_block"
        human_reason = "Invoice is not accepted" if status != 2 else "Model blocked payment"
    elif choice == "WAIT":
        if not active or type(observed_at) is not int or type(expires_at) is not int or expires_at < observed_at:
            expected_code = "mandate_unavailable"
            human_reason = "Mandate unavailable or expired"
        elif type(max_allowed) is not int or max_allowed <= 0:
            expected_code = "no_capacity"
            human_reason = "No spend capacity remains"
        else:
            expected_code = "model_wait"
            human_reason = "Model chose to wait"
    else:
        raise SystemExit("Unsupported decision while deriving canonical reason")

    if decision.get("reason") != expected_code:
        raise SystemExit(
            "AI reason code contradicts the decision or checked policy facts; no transaction sent"
        )
    return human_reason


def ask_ollama(context, max_allowed, model, url, timeout_seconds=300):
    """Ask a local Ollama model for a bounded decision; fail closed on every invalid response."""
    system_prompt = (
        "Return one JSON payment decision. If status is not 2, use BLOCK, amount 0, reason invoice_not_accepted. "
        "If mandateActive is false or mandateExpiresAt is before observedAt, use WAIT, amount 0, "
        "reason mandate_unavailable. If maxAllowedAmount is 0, use WAIT, amount 0, reason no_capacity. "
        "Otherwise use ALLOW, amount exactly maxAllowedAmount, reason within_limits. "
        "You may choose WAIT/model_wait or BLOCK/model_block instead, but amount must be 0. "
        "Reason must be one of the schema's exact reason codes."
    )
    user_prompt = canonical_json(compact_model_context(context, max_allowed))
    body = {
        "model": model,
        "stream": False,
        "format": DECISION_SCHEMA,
        "options": {
            "temperature": 0,
            "num_ctx": 256,
            "num_predict": 32,
            "num_thread": int(os.environ.get("AGENT_AI_NUM_THREADS", "4")),
        },
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
    }
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=float(timeout_seconds)) as response:
            api_result = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError, UnicodeDecodeError, ValueError) as exc:
        raise SystemExit(f"AI service unavailable or returned invalid JSON ({type(exc).__name__}); no transaction sent") from exc
    message = api_result.get("message", {}) if isinstance(api_result, dict) else {}
    model_content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(model_content, str):
        raise SystemExit("AI response is missing message.content; no transaction sent")
    return parse_ai_decision(model_content, max_allowed)


def build_intent_typed_data(chain_id, executor, invoice_id, amount, nonce, deadline, context_hash, decision_hash):
    return {
        "domain": {
            "name": INTENT_DOMAIN_NAME,
            "version": INTENT_DOMAIN_VERSION,
            "chainId": chain_id,
            "verifyingContract": executor,
        },
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "version", "type": "string"},
                {"name": "chainId", "type": "uint256"},
                {"name": "verifyingContract", "type": "address"},
            ],
            "AgentIntent": [
                {"name": "invoiceId", "type": "bytes32"},
                {"name": "amount", "type": "uint128"},
                {"name": "nonce", "type": "uint64"},
                {"name": "deadline", "type": "uint64"},
                {"name": "contextHash", "type": "bytes32"},
                {"name": "decisionHash", "type": "bytes32"},
            ],
        },
        "primaryType": "AgentIntent",
        "message": {
            "invoiceId": invoice_id,
            "amount": amount,
            "nonce": nonce,
            "deadline": deadline,
            "contextHash": context_hash,
            "decisionHash": decision_hash,
        },
    }


def sign_intent(private_key, typed_data):
    """Sign typed data with cast; the intent file contains no private key and is removed after signing."""
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", suffix=".json", prefix="rwa-agent-intent-", delete=False
        ) as handle:
            json.dump(typed_data, handle, separators=(",", ":"))
            temp_path = handle.name
        signature = cast(
            "wallet", "sign", "--data", "--from-file", temp_path, "--private-key", private_key
        ).strip()
    finally:
        if temp_path:
            try:
                Path(temp_path).unlink(missing_ok=True)
            except OSError:
                pass
    if not signature.startswith("0x") or len(signature) != 132:
        raise SystemExit("cast did not return a valid 65-byte EIP-712 signature; no transaction sent")
    return signature


def verify_intent_onchain(rpc, executor, invoice_id, amount, nonce, deadline, context_hash, decision_hash, signature):
    try:
        result = cast(
            "call",
            executor,
            "verifyIntent(bytes32,uint128,uint64,uint64,bytes32,bytes32,bytes)(bool)",
            invoice_id,
            str(amount),
            str(nonce),
            str(deadline),
            context_hash,
            decision_hash,
            signature,
            "--rpc-url",
            rpc,
        ).strip().lower()
    except subprocess.CalledProcessError as exc:
        raise SystemExit("On-chain intent verification call failed; no transaction sent") from exc
    valid = result in ("true", "1") or (result.startswith("0x") and result != "0x" and int(result, 16) == 1)
    if not valid:
        raise SystemExit("Executor rejected the signed intent during preflight; no transaction sent")


def extract_transaction_hash(raw_tx_output):
    """Prefer the explicit transactionHash JSON field over other 32-byte hashes."""
    try:
        payload = json.loads(raw_tx_output)
    except (TypeError, json.JSONDecodeError):
        payload = None

    if isinstance(payload, dict):
        for field in ("transactionHash", "transaction_hash", "txHash", "hash"):
            value = payload.get(field)
            if isinstance(value, str) and HASH_RE.fullmatch(value):
                return value
        for container in ("receipt", "transaction"):
            nested = payload.get(container)
            if isinstance(nested, dict):
                for field in ("transactionHash", "transaction_hash", "txHash", "hash"):
                    value = nested.get(field)
                    if isinstance(value, str) and HASH_RE.fullmatch(value):
                        return value
        return None
    match = HASH_RE.search(raw_tx_output) if isinstance(raw_tx_output, str) else None
    return match.group(0) if match else None


def validate_successful_receipt(raw_receipt, expected_tx_hash):
    """Require a successful, matching on-chain receipt before claiming EXECUTED."""
    if not isinstance(expected_tx_hash, str) or not HASH_RE.fullmatch(expected_tx_hash):
        raise SystemExit("Transaction hash is missing or malformed; execution not confirmed")
    try:
        receipt = json.loads(raw_receipt)
    except (TypeError, json.JSONDecodeError) as exc:
        raise SystemExit("RPC returned invalid transaction receipt JSON; execution not confirmed") from exc
    if not isinstance(receipt, dict):
        raise SystemExit("RPC transaction receipt has an invalid shape; execution not confirmed")

    status = receipt.get("status")
    try:
        if isinstance(status, str):
            status_value = int(status, 16) if status.startswith("0x") else int(status)
        elif type(status) is int:
            status_value = status
        else:
            raise ValueError("missing status")
    except (TypeError, ValueError) as exc:
        raise SystemExit("Transaction receipt has no valid status; execution not confirmed") from exc
    if status_value != 1:
        raise SystemExit("Transaction receipt status is not successful; execution not confirmed")

    receipt_hash = receipt.get("transactionHash")
    if receipt_hash is not None and (
        not isinstance(receipt_hash, str) or receipt_hash.lower() != expected_tx_hash.lower()
    ):
        raise SystemExit("Receipt transaction hash does not match the submitted transaction")

    return {
        "transactionHash": expected_tx_hash,
        "status": "0x1",
        "blockNumber": receipt.get("blockNumber"),
        "gasUsed": receipt.get("gasUsed"),
    }


def write_evidence(evidence, invoice_id, nonce):
    folder = Path(os.environ.get("AGENT_EVIDENCE_DIR", "agent-evidence"))
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"{invoice_id.lower().removeprefix('0x')}-nonce-{nonce}.json"
    path.write_text(json.dumps(evidence, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return path


def main():
    config_path = Path(env("DEPLOYMENT_CONFIG", "deployments-sepolia.json"))
    try:
        config = json.loads(config_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"Could not read deployment config {config_path}: {exc}") from exc
    validate_config_shape(config)

    mode = env("AGENT_DECISION_MODE", "ollama").strip().lower()
    if mode not in ("ollama", "deterministic"):
        raise SystemExit("AGENT_DECISION_MODE must be 'ollama' or 'deterministic'; no transaction sent")
    dry_run = env_bool("AGENT_DRY_RUN", default=False)
    if dry_run and mode != "ollama":
        raise SystemExit("AGENT_DRY_RUN requires AGENT_DECISION_MODE=ollama; no transaction sent")
    rpc = env("SEPOLIA_RPC_URL", "https://ethereum-sepolia-rpc.publicnode.com")
    private_key = load_agent_private_key()
    executor = config["agentExecutor"]
    settlement = config["settlement"]
    invoice_id = config["invoiceId"]
    agent_address = cast("wallet", "address", "--private-key", private_key)
    validate_runtime_config(config, rpc, agent_address, require_signed_intent=(mode == "ollama"))

    payment = int(env("AGENT_PAYMENT_AMOUNT", "2000000000"))
    interval = max(1, int(env("AGENT_INTERVAL_SECONDS", "30")))
    max_payments = max(1, int(env("AGENT_MAX_PAYMENTS", "3")))
    model = os.environ.get("AGENT_AI_MODEL", "qwen2.5:3b")
    ai_url = os.environ.get("AGENT_AI_URL", "http://127.0.0.1:11434/api/chat")
    ai_timeout = float(os.environ.get("AGENT_AI_TIMEOUT_SECONDS", "300"))
    payments_sent = 0
    print(
        f"Agent {agent_address} mode={mode} watching invoice {invoice_id}; "
        f"executor={executor}; interval={interval}s",
        flush=True,
    )

    while payments_sent < max_payments:
        invoice = call_words(settlement, "invoices(bytes32)", invoice_id, rpc=rpc, expected_words=10)
        status = invoice[9]
        funded, paid, due_at = invoice[5], invoice[6], invoice[7]
        if status != 2:
            print(f"Stopping: invoice status={status}; only ACCEPTED (2) is executable", flush=True)
            return
        if paid >= funded:
            print(f"Stopping: no funded unpaid escrow remains (funded={funded}, paid={paid})", flush=True)
            return

        mandate = call_words(
            settlement, "mandates(bytes32,address)", invoice_id, executor, rpc=rpc, expected_words=6
        )
        per_payment, total_limit, spent, expires_at, nonce = mandate[:5]
        active = bool(mandate[5])
        now = int(time.time())
        if not active or now > expires_at:
            print("Stopping: executor mandate is inactive or expired", flush=True)
            return
        remaining = min(int(funded) - int(paid), int(total_limit) - int(spent), int(per_payment), payment)
        if remaining <= 0:
            print("Stopping: mandate has no remaining spend authority", flush=True)
            return
        deadline = min(int(expires_at), now + 300)
        if deadline <= now:
            print("Stopping: no valid execution deadline remains", flush=True)
            return

        context = {
            "policyVersion": POLICY_VERSION,
            "chainId": config["chainId"],
            "executor": executor,
            "settlement": settlement,
            "token": config["token"],
            "invoiceId": invoice_id,
            "invoice": {
                "status": status,
                "funded": int(funded),
                "paid": int(paid),
                "dueAt": int(due_at),
            },
            "mandate": {
                "active": active,
                "perPaymentLimit": int(per_payment),
                "totalLimit": int(total_limit),
                "spent": int(spent),
                "expiresAt": int(expires_at),
                "nonce": int(nonce),
            },
            "maxAllowedAmount": int(remaining),
            "observedAt": int(now),
        }

        if mode == "deterministic":
            decision = {
                "decision": "ALLOW",
                "amount": int(remaining),
                "reason": "deterministic policy cap; no model inference",
            }
            print(
                f"Decision=ALLOW mode=deterministic amount={decision['amount']} nonce={nonce} deadline={deadline}",
                flush=True,
            )
            tx = cast(
                "send",
                executor,
                "execute(bytes32,uint128,uint64,uint64)",
                invoice_id,
                str(decision["amount"]),
                str(nonce),
                str(deadline),
                "--rpc-url",
                rpc,
                "--private-key",
                private_key,
            )
            print(f"Execution confirmed: {tx}", flush=True)
        else:
            decision = ask_ollama(
                context,
                int(remaining),
                model=model,
                url=ai_url,
                timeout_seconds=ai_timeout,
            )

            # Re-read on-chain state after inference. A slow/cold model load must not
            # turn a stale proposal into a valid transaction.
            fresh_invoice = call_words(
                settlement, "invoices(bytes32)", invoice_id, rpc=rpc, expected_words=10
            )
            fresh_mandate = call_words(
                settlement, "mandates(bytes32,address)", invoice_id, executor, rpc=rpc, expected_words=6
            )
            state_unchanged = (
                fresh_invoice[9] == status
                and tuple(fresh_invoice[5:8]) == tuple(invoice[5:8])
                and tuple(fresh_mandate) == tuple(mandate)
            )
            now_after_model = int(time.time())
            fresh_funded, fresh_paid, fresh_due = fresh_invoice[5], fresh_invoice[6], fresh_invoice[7]
            fresh_per_payment, fresh_total, fresh_spent, fresh_expiry, fresh_nonce = fresh_mandate[:5]
            fresh_active = bool(fresh_mandate[5])
            fresh_maximum = min(
                int(fresh_funded) - int(fresh_paid),
                int(fresh_total) - int(fresh_spent),
                int(fresh_per_payment),
                payment,
            )
            if (
                not state_unchanged
                or fresh_invoice[9] != 2
                or not fresh_active
                or now_after_model > int(fresh_expiry)
            ):
                raise SystemExit("On-chain invoice or mandate changed during AI inference; no transaction sent")
            if decision["decision"] == "ALLOW" and decision["amount"] > fresh_maximum:
                raise SystemExit("AI proposal no longer fits the live policy maximum; no transaction sent")
            model_reason_code = decision["reason"]
            decision["reason"] = canonical_decision_reason(context, decision)
            deadline = min(int(fresh_expiry), now_after_model + 300)
            if deadline <= now_after_model:
                raise SystemExit("No valid execution deadline remains after AI inference; no transaction sent")

            context_hash = keccak_text(canonical_json(context))
            decision_record = {
                "schema": "rwa-agent-decision/v1",
                "policyVersion": POLICY_VERSION,
                "mode": "ollama",
                "model": model,
                "contextHash": context_hash,
                "decision": decision["decision"],
                "amount": decision["amount"],
                "reason": decision["reason"],
                "modelReasonCode": model_reason_code,
            }
            decision_hash = keccak_text(canonical_json(decision_record))
            typed_data = build_intent_typed_data(
                int(config["chainId"]),
                executor,
                invoice_id,
                int(decision["amount"]),
                int(nonce),
                int(deadline),
                context_hash,
                decision_hash,
            )
            signature = sign_intent(private_key, typed_data)
            verify_intent_onchain(
                rpc,
                executor,
                invoice_id,
                int(decision["amount"]),
                int(nonce),
                int(deadline),
                context_hash,
                decision_hash,
                signature,
            )
            evidence = {
                "schema": "rwa-agent-intent-proof/v1",
                "status": "SIGNED_NOT_EXECUTED",
                "agentSigner": agent_address,
                "model": model,
                "mode": "ollama",
                "context": context,
                "contextHash": context_hash,
                "decision": decision,
                "modelReasonCode": model_reason_code,
                "decisionRecord": decision_record,
                "decisionHash": decision_hash,
                "intentDeadline": int(deadline),
                "typedData": typed_data,
                "signature": signature,
                "transactionHash": None,
            }
            evidence_path = write_evidence(evidence, invoice_id, int(nonce))
            print(
                f"AI Decision={decision['decision']} amount={decision['amount']} "
                f"reason={decision['reason']}",
                flush=True,
            )
            print(f"Signed intent evidence: {evidence_path}", flush=True)

            # Dry-run still performs live reads, model inference, signing, and on-chain
            # signature verification, but deliberately stops before cast send.
            if dry_run:
                print("DRY RUN: decision and signed intent verified; no transaction sent.", flush=True)
                return

            if decision["decision"] != "ALLOW":
                evidence["status"] = "SIGNED_NOT_EXECUTED"
                write_evidence(evidence, invoice_id, int(nonce))
                print("No transaction sent: model decision is not ALLOW.", flush=True)
                return

            try:
                tx_output = cast(
                    "send",
                    executor,
                    "executeWithIntent(bytes32,uint128,uint64,uint64,bytes32,bytes32,bytes)",
                    invoice_id,
                    str(decision["amount"]),
                    str(nonce),
                    str(deadline),
                    context_hash,
                    decision_hash,
                    signature,
                    "--rpc-url",
                    rpc,
                    "--private-key",
                    private_key,
                    json_output=True,
                )
            except subprocess.CalledProcessError as exc:
                evidence["status"] = "EXECUTION_FAILED"
                evidence["executionError"] = "cast send failed; inspect local RPC/Foundry diagnostics"
                write_evidence(evidence, invoice_id, int(nonce))
                raise SystemExit(f"Signed intent was not confirmed on-chain; evidence saved to {evidence_path}") from exc

            tx_hash = extract_transaction_hash(tx_output)
            if not tx_hash:
                evidence["status"] = "EXECUTION_FAILED"
                evidence["executionError"] = "cast send returned no transaction hash"
                write_evidence(evidence, invoice_id, int(nonce))
                raise SystemExit(f"No transaction hash returned; evidence saved to {evidence_path}")

            evidence["transactionHash"] = tx_hash
            try:
                receipt_output = cast("receipt", tx_hash, "--rpc-url", rpc, json_output=True)
                confirmed_receipt = validate_successful_receipt(receipt_output, tx_hash)
            except (subprocess.CalledProcessError, SystemExit) as exc:
                evidence["status"] = "EXECUTION_FAILED"
                evidence["executionError"] = "transaction receipt was not confirmed successful"
                write_evidence(evidence, invoice_id, int(nonce))
                raise SystemExit(f"Receipt verification failed; evidence saved to {evidence_path}") from exc

            evidence["status"] = "EXECUTED"
            evidence["receipt"] = confirmed_receipt
            write_evidence(evidence, invoice_id, int(nonce))
            print(
                f"Execution confirmed: {tx_hash}; block={confirmed_receipt.get('blockNumber')}; "
                f"evidence={evidence_path}",
                flush=True,
            )

        payments_sent += 1
        if payments_sent < max_payments:
            time.sleep(interval)

    print(f"Agent finished: sent {payments_sent} authorized payment(s)", flush=True)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as exc:
        print(f"cast command failed: {exc.stderr.strip() if exc.stderr else exc}", file=sys.stderr)
        raise SystemExit(exc.returncode or 1)
