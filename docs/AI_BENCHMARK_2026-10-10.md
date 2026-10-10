# AI inference benchmark — 2026-10-10

Model: `qwen2.5:3b`, local Ollama on Gensyn2. Four synthetic scenarios, one inference each. No invoice documents were parsed. The benchmark did not sign intents or send transactions.

| Scenario | Model output | Gate result |
|---|---|---|
| Accepted invoice, active mandate, capacity 2000 | ALLOW, 2000, `within_limits` | PASS |
| Invoice not accepted | ALLOW, 2000, `within_limits` | BLOCK: conflicts with checked invoice status |
| Inactive/expired mandate | BLOCK, 0, `invoice_not_accepted` | BLOCK: reason code conflicts with checked facts |
| Zero capacity | BLOCK, 0, `invoice_not_accepted` | BLOCK: reason code conflicts with checked facts |

Observed: 1 PASS and 3 BLOCKs. Do not count all three blocks as correct model decisions: one incorrect ALLOW was rejected by the gate; two conservative BLOCKs had incorrect reasons.

Durations: 67.327 s, 11.465 s, 18.320 s, 15.976 s respectively. Four observations do not establish reliable latency.

## Conclusion

The model produced a valid-looking proposal for one simple synthetic case, but failed to provide a consistent decision/reason in three other cases. The policy gate rejected these contradictions. This supports the value of fail-closed validation, not a claim of reliable AI or production security.

## Limits

- No real invoice, underlying contract, delivery proof, or acceptance document was parsed.
- No legal claim, ownership, or non-duplication was verified.
- One run per scenario is not a statistical reliability test.
- No transaction was signed or broadcast.

## Next step

Add mocked-response regression tests for all four scenarios, then run a small repeated inference sample and report model correctness, gate rejection, and latency separately.