#!/usr/bin/env python3
"""Minimal deterministic Sepolia agent runner. Requires Foundry's `cast` on PATH.

The payer must first accept/fund the invoice and authorize the *executor contract*.
AGENT_PRIVATE_KEY must correspond to agentOwner in deployments-sepolia.json.
This runner executes only within the already-authorized on-chain mandate.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def env(name, default=None):
    value = os.environ.get(name, default)
    if not value:
        raise SystemExit(f"Missing required environment variable: {name}")
    return value


def cast(*args, json_output=False):
    cmd = ["cast", *args]
    if json_output:
        cmd.append("--json")
    result = subprocess.run(cmd, check=True, text=True, capture_output=True)
    return result.stdout.strip()


def decode_words(raw, expected_words):
    data = raw.strip()
    if data.startswith("0x"):
        data = data[2:]
    if len(data) != expected_words * 64:
        raise RuntimeError(f"Unexpected ABI response length: got {len(data)} hex chars, expected {expected_words * 64}")
    return [int(data[i:i + 64], 16) for i in range(0, len(data), 64)]


def call_words(target, signature, *args, rpc, expected_words):
    raw = cast("call", target, signature, *args, "--rpc-url", rpc)
    return decode_words(raw, expected_words)


def main():
    config_path = Path(env("DEPLOYMENT_CONFIG", "deployments-sepolia.json"))
    config = json.loads(config_path.read_text())
    rpc = env("SEPOLIA_RPC_URL", "https://ethereum-sepolia-rpc.publicnode.com")
    private_key = env("AGENT_PRIVATE_KEY")
    executor = config["agentExecutor"]
    settlement = config["settlement"]
    invoice_id = config["invoiceId"]
    configured_owner = config.get("agentOwner")
    agent_address = cast("wallet", "address", "--private-key", private_key)
    if configured_owner and agent_address.lower() != configured_owner.lower():
        raise SystemExit(f"AGENT_PRIVATE_KEY address {agent_address} does not match configured agentOwner {configured_owner}")

    payment = int(env("AGENT_PAYMENT_AMOUNT", "2000000000"))
    interval = max(1, int(env("AGENT_INTERVAL_SECONDS", "30")))
    max_payments = max(1, int(env("AGENT_MAX_PAYMENTS", "3")))
    payments_sent = 0
    print(f"Agent {agent_address} watching invoice {invoice_id}; executor={executor}; interval={interval}s", flush=True)

    while payments_sent < max_payments:
        invoice = call_words(settlement, "invoices(bytes32)", invoice_id, rpc=rpc, expected_words=10)
        status = invoice[9]
        funded, paid, due_at = invoice[5], invoice[6], invoice[7]
        if status != 2:
            print(f"Stopping: invoice status={status}; only ACCEPTED (2) is executable", flush=True)
            return
        if paid >= funded:
            print(f"Waiting: no funded unpaid escrow (funded={funded}, paid={paid})", flush=True)
            time.sleep(interval)
            continue

        mandate = call_words(settlement, "mandates(bytes32,address)", invoice_id, executor, rpc=rpc, expected_words=6)
        per_payment, total_limit, spent, expires_at, nonce = mandate[:5]
        active = bool(mandate[5])
        if not active or int(time.time()) > expires_at:
            print("Stopping: executor mandate is inactive or expired", flush=True)
            return
        remaining = min(int(funded) - int(paid), total_limit - spent, per_payment, payment)
        if remaining <= 0:
            print("Stopping: mandate has no remaining spend authority", flush=True)
            return
        now = int(time.time())
        deadline = min(expires_at, now + 300)
        if deadline <= now:
            print("Stopping: no valid execution deadline remains", flush=True)
            return

        print(f"Decision=ALLOW amount={remaining} nonce={nonce} deadline={deadline}", flush=True)
        tx = cast("send", executor, "execute(bytes32,uint128,uint64,uint64)", invoice_id,
                  str(remaining), str(nonce), str(deadline), "--rpc-url", rpc,
                  "--private-key", private_key)
        print(f"Execution submitted: {tx}", flush=True)
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
