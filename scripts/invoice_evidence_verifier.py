#!/usr/bin/env python3
"""Compare extracted invoice claims with independently supplied evidence; never authorize payment."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path

CLAIM_TO_EVIDENCE = {
    "invoice_number": "invoice_number",
    "issuer_name": "issuer_name",
    "debtor_name": "debtor_name",
    "currency": "currency",
    "total_amount_text": "total_amount_text",
    "issue_date": "issue_date",
    "due_date": "due_date",
}
REQUIRED_EVIDENCE = (
    "invoice_number", "issuer_name", "debtor_name", "currency", "total_amount_text",
    "issue_date", "due_date", "accepted", "accepted_invoice_sha256",
    "duplicate_check_clear", "encumbrance_check_clear",
)


def verify(extraction: dict, evidence: dict) -> dict:
    """Return a consistency report. A MATCH is not authenticity or legal proof."""
    errors = []
    if extraction.get("schema") != "rwa-invoice-claims/v1":
        errors.append("unsupported_extraction_schema")
    source_hash = extraction.get("source", {}).get("sha256")
    if not isinstance(source_hash, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", source_hash):
        errors.append("missing_or_invalid_source_sha256")
    missing = [key for key in REQUIRED_EVIDENCE if key not in evidence or evidence[key] is None]
    comparisons = []
    for claim_key, evidence_key in CLAIM_TO_EVIDENCE.items():
        claim = extraction.get("claims", {}).get(claim_key)
        independent = evidence.get(evidence_key)
        if claim is None or independent is None:
            comparisons.append({"field": claim_key, "status": "INCOMPLETE"})
        else:
            # Exact string equality is intentional: normalization can conceal ambiguity.
            comparisons.append({
                "field": claim_key,
                "status": "MATCH" if str(claim) == str(independent) else "MISMATCH",
                "claim": claim,
                "independentEvidence": independent,
            })
    # Missing assertions are INCOMPLETE; explicit negative assertions are MISMATCH.
    # Never let an absent field masquerade as a confirmed negative or a pass.
    if "accepted" in evidence and evidence.get("accepted") is not True:
        errors.append("debtor_acceptance_not_confirmed")
    accepted_hash = evidence.get("accepted_invoice_sha256")
    if accepted_hash is not None and isinstance(source_hash, str) and accepted_hash != source_hash:
        errors.append("acceptance_not_bound_to_exact_source_hash")
    if "duplicate_check_clear" in evidence and evidence.get("duplicate_check_clear") is not True:
        errors.append("duplicate_financing_check_not_clear")
    if "encumbrance_check_clear" in evidence and evidence.get("encumbrance_check_clear") is not True:
        errors.append("encumbrance_check_not_clear")
    mismatches = [item["field"] for item in comparisons if item["status"] == "MISMATCH"]
    incomplete = [item["field"] for item in comparisons if item["status"] == "INCOMPLETE"]
    if errors or mismatches:
        status = "MISMATCH"
    elif missing or incomplete:
        status = "INCOMPLETE"
    else:
        status = "CONSISTENT"
    return {
        "schema": "rwa-invoice-evidence-check/v1",
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "status": status,
        "sourceSha256": source_hash,
        "comparisons": comparisons,
        "missingEvidenceFields": missing,
        "errors": errors,
        "trustBoundary": {
            "paymentAuthorization": False,
            "meaning": "CONSISTENT means only that supplied values agree; it does not prove source authenticity, signer authority, delivery, enforceability, or absence of undisclosed claims.",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extraction", required=True, help="JSON from invoice_evidence_extractor.py")
    parser.add_argument("--evidence", required=True, help="Independently obtained evidence JSON")
    parser.add_argument("--output", default="artifacts/invoice-evidence-check-latest.json")
    args = parser.parse_args()
    extraction = json.loads(Path(args.extraction).read_text(encoding="utf-8"))
    evidence = json.loads(Path(args.evidence).read_text(encoding="utf-8"))
    report = verify(extraction, evidence)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Evidence consistency: {report['status']}; payment authorization=false; report={output}")
    # Non-consistent evidence is a reportable outcome, not a tool crash.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
