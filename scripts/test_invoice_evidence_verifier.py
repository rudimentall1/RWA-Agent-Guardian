"""Offline tests for independent invoice evidence comparison."""
import hashlib
import unittest

import invoice_evidence_verifier as verifier


class InvoiceEvidenceVerifierTests(unittest.TestCase):
    def setUp(self):
        source_hash = hashlib.sha256(b"synthetic invoice").hexdigest()
        self.extraction = {
            "schema": "rwa-invoice-claims/v1",
            "source": {"sha256": source_hash},
            "claims": {
                "invoice_number": "INV-42", "issuer_name": "Supplier Ltd",
                "debtor_name": "Buyer Ltd", "currency": "EUR",
                "total_amount_text": "2000.00", "issue_date": "2026-10-01",
                "due_date": "2026-11-01",
            },
        }
        self.evidence = {
            "invoice_number": "INV-42", "issuer_name": "Supplier Ltd",
            "debtor_name": "Buyer Ltd", "currency": "EUR",
            "total_amount_text": "2000.00", "issue_date": "2026-10-01",
            "due_date": "2026-11-01", "accepted": True,
            "accepted_invoice_sha256": source_hash,
            "duplicate_check_clear": True, "encumbrance_check_clear": True,
        }

    def test_consistent_values_still_never_authorize_payment(self):
        report = verifier.verify(self.extraction, self.evidence)
        self.assertEqual(report["status"], "CONSISTENT")
        self.assertFalse(report["trustBoundary"]["paymentAuthorization"])

    def test_amount_mismatch_is_detected(self):
        self.evidence["total_amount_text"] = "20000.00"
        report = verifier.verify(self.extraction, self.evidence)
        self.assertEqual(report["status"], "MISMATCH")
        self.assertIn("total_amount_text", [x["field"] for x in report["comparisons"] if x["status"] == "MISMATCH"])

    def test_acceptance_for_different_document_hash_fails(self):
        self.evidence["accepted_invoice_sha256"] = "0" * 64
        report = verifier.verify(self.extraction, self.evidence)
        self.assertEqual(report["status"], "MISMATCH")
        self.assertIn("acceptance_not_bound_to_exact_source_hash", report["errors"])

    def test_missing_independent_evidence_is_incomplete(self):
        del self.evidence["due_date"]
        report = verifier.verify(self.extraction, self.evidence)
        self.assertEqual(report["status"], "INCOMPLETE")
        self.assertIn("due_date", report["missingEvidenceFields"])


    def test_missing_acceptance_is_incomplete_not_a_false_mismatch(self):
        del self.evidence["accepted"]
        report = verifier.verify(self.extraction, self.evidence)
        self.assertEqual(report["status"], "INCOMPLETE")
        self.assertIn("accepted", report["missingEvidenceFields"])
        self.assertNotIn("debtor_acceptance_not_confirmed", report["errors"])

    def test_non_hex_source_hash_is_rejected(self):
        self.extraction["source"]["sha256"] = "z" * 64
        report = verifier.verify(self.extraction, self.evidence)
        self.assertEqual(report["status"], "MISMATCH")
        self.assertIn("missing_or_invalid_source_sha256", report["errors"])

    def test_unconfirmed_acceptance_fails_closed(self):
        self.evidence["accepted"] = False
        report = verifier.verify(self.extraction, self.evidence)
        self.assertEqual(report["status"], "MISMATCH")
        self.assertIn("debtor_acceptance_not_confirmed", report["errors"])


if __name__ == "__main__":
    unittest.main()
