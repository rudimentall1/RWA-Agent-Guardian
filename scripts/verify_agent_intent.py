#!/usr/bin/env python3
"""Verify an RWA Agent Guardian signed-intent evidence JSON file.

By default this verifies the JSON hashes, EIP-712 signature, executor response, and (for
executed intents) transaction/receipt against the configured RPC. Use --offline-only for
local hash and signature checks without RPC access.
"""
import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from agent_runner import (
    POLICY_VERSION,
    build_intent_typed_data,
    canonical_json,
    cast,
    keccak_text,
    normalize_address,
    parse_ai_decision,
    validate_config_shape,
    verify_intent_onchain,
)

HASH_RE = re.compile(r"0x[0-9a-fA-F]{64}\Z")
EXECUTE_SIGNATURE = "executeWithIntent(bytes32,uint128,uint64,uint64,bytes32,bytes32,bytes)"


def validate_evidence(evidence, config):
    """Validate all portable fields before using any RPC or signature verification."""
    validate_config_shape(config)
    if not isinstance(evidence, dict) or evidence.get("schema") != "rwa-agent-intent-proof/v1":
        raise SystemExit("Unsupported or malformed signed-intent evidence file")
    if evidence.get("mode") != "ollama":
        raise SystemExit("Evidence file is not from Ollama decision mode")
    if evidence.get("model") is None or not isinstance(evidence.get("model"), str):
        raise SystemExit("Evidence file is missing model identity")
    if evidence.get("status") not in ("SIGNED_NOT_EXECUTED", "EXECUTED", "EXECUTION_FAILED"):
        raise SystemExit("Evidence file has an unknown execution status")

    signer = normalize_address(evidence.get("agentSigner"), "evidence agentSigner")
    if signer != normalize_address(config["agentOwner"], "configured agentOwner"):
        raise SystemExit("Evidence signer does not match the configured trusted agentOwner")

    context = evidence.get("context")
    decision = evidence.get("decision")
    decision_record = evidence.get("decisionRecord")
    if not isinstance(context, dict) or not isinstance(decision, dict) or not isinstance(decision_record, dict):
        raise SystemExit("Evidence context or decision record is missing")
    expected_context_bindings = {
        "chainId": config["chainId"],
        "executor": config["agentExecutor"],
        "settlement": config["settlement"],
        "token": config["token"],
        "invoiceId": config["invoiceId"],
    }
    for field, expected in expected_context_bindings.items():
        got = context.get(field)
        if isinstance(expected, str):
            matches = isinstance(got, str) and got.lower() == expected.lower()
        else:
            matches = got == expected
        if not matches:
            raise SystemExit(f"Evidence context {field} does not match configured deployment")

    maximum = context.get("maxAllowedAmount")
    if type(maximum) is not int or maximum < 0:
        raise SystemExit("Evidence context has an invalid policy maximum")
    checked_decision = parse_ai_decision(json.dumps(decision), maximum)
    context_hash = keccak_text(canonical_json(context))
    if evidence.get("contextHash") != context_hash:
        raise SystemExit("Context hash mismatch; evidence was changed or is inconsistent")

    expected_record = {
        "schema": "rwa-agent-decision/v1",
        "policyVersion": POLICY_VERSION,
        "mode": "ollama",
        "model": evidence["model"],
        "contextHash": context_hash,
        "decision": checked_decision["decision"],
        "amount": checked_decision["amount"],
        "reason": checked_decision["reason"],
    }
    if decision_record != expected_record:
        raise SystemExit("Signed decision record does not match the recorded model decision")
    decision_hash = keccak_text(canonical_json(expected_record))
    if evidence.get("decisionHash") != decision_hash:
        raise SystemExit("Decision hash mismatch; evidence was changed or is inconsistent")

    typed_data = build_intent_typed_data(
        int(config["chainId"]),
        config["agentExecutor"],
        config["invoiceId"],
        int(checked_decision["amount"]),
        int(context["mandate"]["nonce"]),
        int(context["decisionDeadline"]),
        context_hash,
        decision_hash,
    )
    if evidence.get("typedData") != typed_data:
        raise SystemExit("EIP-712 typed data does not match the recorded context and decision")

    signature = evidence.get("signature")
    if not isinstance(signature, str) or not re.fullmatch(r"0x[0-9a-fA-F]{130}", signature):
        raise SystemExit("Evidence has an invalid 65-byte signature encoding")
    status = evidence["status"]
    if status == "EXECUTED" and checked_decision["decision"] != "ALLOW":
        raise SystemExit("A WAIT/BLOCK decision cannot be marked as executed")
    if status == "EXECUTED" and not HASH_RE.fullmatch(str(evidence.get("transactionHash", ""))):
        raise SystemExit("Executed evidence is missing a valid transaction hash")
    return {
        "signer": signer,
        "context": context,
        "decision": checked_decision,
        "contextHash": context_hash,
        "decisionHash": decision_hash,
        "typedData": typed_data,
        "signature": signature,
        "status": status,
    }


def verify_signature_offline(typed_data, signature, signer):
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", suffix=".json", prefix="rwa-verify-intent-", delete=False
        ) as handle:
            json.dump(typed_data, handle, separators=(",", ":"))
            temp_path = handle.name
        try:
            result = cast(
                "wallet", "verify", "--data", "--from-file", temp_path,
                signature, "--address", signer
            ).strip().lower()
        except subprocess.CalledProcessError as exc:
            raise SystemExit("EIP-712 signature verification failed") from exc
    finally:
        if temp_path:
            try:
                Path(temp_path).unlink(missing_ok=True)
            except OSError:
                pass
    if result not in ("true", "1"):
        raise SystemExit("EIP-712 signature does not recover to the configured agentOwner")


def verify_execution_transaction(proof, rpc, executor):
    tx_hash = proof["transactionHash"]
    try:
        tx = json.loads(cast("tx", tx_hash, "--rpc-url", rpc, json_output=True))
        receipt = json.loads(cast("receipt", tx_hash, "--rpc-url", rpc, json_output=True))
    except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        raise SystemExit("Could not retrieve the recorded execution transaction and receipt") from exc

    target = tx.get("to")
    calldata = tx.get("input") or tx.get("data")
    if not isinstance(target, str) or target.lower() != executor.lower():
        raise SystemExit("Recorded transaction does not target the configured executor")
    if not isinstance(calldata, str) or not calldata.startswith("0x"):
        raise SystemExit("Recorded transaction has no decodable calldata")

    selector = keccak_text(EXECUTE_SIGNATURE)[:10]
    if calldata[:10].lower() != selector.lower():
        raise SystemExit("Recorded transaction does not call executeWithIntent")
    raw = calldata[10:].removeprefix("0x")
    if len(raw) < 8 * 64:
        raise SystemExit("Recorded execution calldata is truncated")
    words = [raw[i:i + 64].lower() for i in range(0, len(raw), 64)]
    expected_words = [
        proof["context"]["invoiceId"][2:].lower(),
        f"{proof['decision']['amount']:064x}",
        f"{proof['context']['mandate']['nonce']:064x}",
        f"{proof['context']['decisionDeadline']:064x}",
        proof["contextHash"][2:].lower(),
        proof["decisionHash"][2:].lower(),
    ]
    if words[:6] != expected_words:
        raise SystemExit("Recorded transaction parameters do not match the signed intent")

    # The seventh ABI argument is dynamic bytes: offset, byte length, then signature.
    if len(words) < 8 or int(words[6], 16) != 7 * 32 or int(words[7], 16) != 65:
        raise SystemExit("Recorded calldata has an invalid signature offset or length")
    signature_start = (7 * 32 + 32) * 2
    recorded_signature = "0x" + raw[signature_start:signature_start + 65 * 2]
    if recorded_signature.lower() != proof["signature"].lower():
        raise SystemExit("Transaction signature bytes do not match the evidence file")

    receipt_status = receipt.get("status", "0x0")
    try:
        successful = int(receipt_status, 16) == 1 if isinstance(receipt_status, str) else int(receipt_status) == 1
    except (TypeError, ValueError):
        successful = False
    if not successful:
        raise SystemExit("Recorded transaction receipt is not successful")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", help="path to agent-intent proof JSON")
    parser.add_argument("--config", default="deployments-sepolia.json", help="trusted public deployment config")
    parser.add_argument("--rpc-url", default=None, help="RPC URL; defaults to SEPOLIA_RPC_URL or public Sepolia RPC")
    parser.add_argument("--offline-only", action="store_true", help="verify hashes and EIP-712 signature without RPC")
    args = parser.parse_args()

    try:
        evidence = json.loads(Path(args.evidence).read_text(encoding="utf-8"))
        config = json.loads(Path(args.config).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"Could not read proof or deployment config: {exc}") from exc

    proof = validate_evidence(evidence, config)
    verify_signature_offline(proof["typedData"], proof["signature"], proof["signer"])
    print("Context and decision hashes: OK")
    print("EIP-712 signature and configured signer: OK")
    print(f"Decision: {proof['decision']['decision']}; amount={proof['decision']['amount']}")
    if args.offline_only:
        print("Offline verification completed; no on-chain state or execution receipt was checked.")
        return

    rpc = args.rpc_url or env_rpc_url()
    try:
        chain_id = int(cast("chain-id", "--rpc-url", rpc))
    except (ValueError, subprocess.CalledProcessError) as exc:
        raise SystemExit("Could not read RPC chain ID") from exc
    if chain_id != config["chainId"]:
        raise SystemExit("RPC chain ID does not match the trusted deployment config")
    executor = config["agentExecutor"]
    code = cast("code", executor, "--rpc-url", rpc)
    if not code or code.strip().lower() == "0x":
        raise SystemExit("No deployed executor code at the trusted configured address")
    c = proof["context"]
    verify_intent_onchain(
        rpc, executor, c["invoiceId"], proof["decision"]["amount"],
        c["mandate"]["nonce"], c["decisionDeadline"], proof["contextHash"],
        proof["decisionHash"], proof["signature"]
    )
    print("Executor verifyIntent(): OK")
    if proof["status"] == "EXECUTED":
        verify_execution_transaction(evidence, rpc, executor)
        print(f"Execution transaction and receipt: OK ({evidence['transactionHash']})")
    elif proof["status"] == "EXECUTION_FAILED":
        print("Signed intent is valid; transaction was not confirmed, as recorded in the evidence.")
    else:
        print("No execution was claimed in the evidence record.")


def env_rpc_url():
    import os
    return os.environ.get("SEPOLIA_RPC_URL", "https://ethereum-sepolia-rpc.publicnode.com")


if __name__ == "__main__":
    main()
