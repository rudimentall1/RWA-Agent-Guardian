# AI inference benchmark — 2026-10-10

Model: `qwen2.5:3b`, local Ollama on Gensyn2. The benchmark uses synthetic invoice/mandate state only. No invoice documents were parsed. It never signs intents or sends transactions.

## Repeated run: two attempts per scenario

Raw structured results: [`artifacts/ai-benchmark-repeat-2026-10-10.json`](../artifacts/ai-benchmark-repeat-2026-10-10.json).

| Scenario | Attempt 1 | Attempt 2 | Gate |
|---|---|---|---|
| Accepted invoice, active mandate, capacity 2000 | BLOCK, amount 0, `invoice_not_accepted` | Same | Both blocked: reason contradicts checked facts |
| Invoice not accepted | ALLOW, amount 2000, `within_limits` | Same | Both blocked: ALLOW contradicts invoice status |
| Inactive/expired mandate | BLOCK, amount 0, `invoice_not_accepted` | Same | Both blocked: reason contradicts checked facts |
| Zero capacity | BLOCK, amount 0, `invoice_not_accepted` | Same | Both blocked: reason contradicts checked facts |

**Result: 0/8 gate PASS, 8/8 gate BLOCK, 0 transactions sent.** This is not an 8/8 model-success score. The gate rejected all eight proposals; the two ALLOW proposals for an unaccepted invoice are direct unsafe decisions, and the repeated reason-code mismatch makes the other six proposals invalid for their scenario.

Latency across the eight inferences: mean **11.795 s**, minimum **6.980 s**, maximum **16.271 s**. Eight samples are diagnostic only, not a production latency SLO.

## Earlier single-run sample

The earlier single-run sample had 1 PASS and 3 BLOCKs. It is superseded for diagnostic purposes by the repeated sample above, which reproduced scenario-specific failures across both attempts.

## Conclusion

The current model layer is **not reliable enough to be an authority source**. It can suggest a structured action, but it cannot safely decide invoice eligibility or consistently explain why a mandate is unavailable. The deterministic policy gate did block all eight contradictory proposals in this sample. That is evidence of fail-closed behavior in these test cases—not proof of production security.

## Limits

- Synthetic chain context only; no real invoice, underlying contract, delivery proof, or acceptance document was parsed.
- No legal claim, ownership, duplicate financing, or encumbrance was verified.
- Two attempts per scenario are too few to estimate reliability statistically.
- The sample does not demonstrate production security or readiness for real RWA.
- No wallet signing and no transaction broadcast were performed.

## Offline regression tests

`scripts/test_ai_benchmark.py` has four tests covering the scenario matrix, gate rejection/reporting, fail-closed handling of inference exceptions, and repeated attempts. All four passed on Gensyn2 in 0.023 seconds. They mock inference; they do not establish model quality.
