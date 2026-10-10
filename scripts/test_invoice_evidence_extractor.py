"""Offline tests for the untrusted invoice extraction boundary."""
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import invoice_evidence_extractor as extractor


class InvoiceEvidenceExtractorTests(unittest.TestCase):
    def test_extraction_schema_requires_claims_not_authorization(self):
        required = set(extractor.SCHEMA["required"])
        self.assertIn("issuer_name", required)
        self.assertIn("total_amount_text", required)
        self.assertIn("uncertainties", required)
        self.assertNotIn("decision", required)
        self.assertNotIn("authorized", required)

    def test_main_hashes_source_and_marks_all_claims_unverified(self):
        claims = {
            "invoice_number": "INV-42", "issuer_name": "Supplier Ltd", "debtor_name": "Buyer Ltd",
            "currency": "EUR", "total_amount_text": "2,000.00", "issue_date": "2026-10-01",
            "due_date": "2026-11-01", "line_items": [], "payment_terms_text": "Net 30",
            "uncertainties": [],
        }
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "invoice.txt"
            source.write_text("Invoice INV-42\nSupplier Ltd -> Buyer Ltd\nEUR 2,000.00", encoding="utf-8")
            output = Path(tmp) / "result.json"
            argv = ["invoice_evidence_extractor.py", "--input", str(source), "--output", str(output)]
            with patch.object(sys, "argv", argv), patch.object(extractor, "extract_claims", return_value=claims):
                self.assertEqual(extractor.main(), 0)
            result = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(result["source"]["sha256"], hashlib.sha256(source.read_bytes()).hexdigest())
            self.assertEqual(result["trustBoundary"]["status"], "UNVERIFIED_CLAIMS")
            self.assertFalse(result["trustBoundary"]["paymentAuthorization"])
            self.assertEqual(result["claims"]["invoice_number"], "INV-42")

    def test_rejects_non_string_scalar_claims(self):
        claims = {
            "invoice_number": 42, "issuer_name": "Supplier Ltd", "debtor_name": "Buyer Ltd",
            "currency": "EUR", "total_amount_text": "2000.00", "issue_date": "2026-10-01",
            "due_date": "2026-11-01", "line_items": [], "payment_terms_text": None,
            "uncertainties": [],
        }
        with self.assertRaisesRegex(RuntimeError, "invoice_number"):
            extractor.validate_claims(claims)

    def test_rejects_malformed_line_item(self):
        claims = {
            "invoice_number": "INV-42", "issuer_name": "Supplier Ltd", "debtor_name": "Buyer Ltd",
            "currency": "EUR", "total_amount_text": "2000.00", "issue_date": "2026-10-01",
            "due_date": "2026-11-01", "line_items": [{"description": "Service"}],
            "payment_terms_text": None, "uncertainties": [],
        }
        with self.assertRaisesRegex(RuntimeError, r"line_items\\[0\\]"):
            extractor.validate_claims(claims)

    def test_rejects_non_string_uncertainty(self):
        claims = {
            "invoice_number": None, "issuer_name": None, "debtor_name": None, "currency": None,
            "total_amount_text": None, "issue_date": None, "due_date": None, "line_items": [],
            "payment_terms_text": None, "uncertainties": [False],
        }
        with self.assertRaisesRegex(RuntimeError, "uncertainties"):
            extractor.validate_claims(claims)

    def test_empty_source_fails_before_network_request(self):
        with self.assertRaisesRegex(ValueError, "empty"):
            extractor.extract_claims("  ", "qwen2.5:3b", "http://127.0.0.1:11434/api/chat")


if __name__ == "__main__":
    unittest.main()
