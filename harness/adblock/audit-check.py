#!/usr/bin/env python3
"""Exercise coverage decisions with independent Objective-C metadata fixtures."""
import importlib.util
import sys
import unittest
from pathlib import Path

# build.sh names the script it checks, so the harness plan sees it as a dependency.
ROOT = Path(__file__).resolve().parents[2]
SCRIPT = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else ROOT / "scripts/audit-ad-services.py"
spec = importlib.util.spec_from_file_location("audit", SCRIPT)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

AD = "_TtC28AdsPlatform_AdsBaseSwiftImpl23AdsBaseSwiftServiceImpl"
UPSELL = "_TtC28Jam_FreeHostedJamsUpsellImpl31FreeHostedJamsUpsellServiceImpl"
CTA = "_TtC32AdsEmbedded_EmbeddedCTACardsImpl23EmbeddedCTACardsService"


def coverage(name, selector, encoding, gate):
    return audit.audit({name: ("NSObject", {selector: encoding})}, {name: (selector, gate)})


class CoverageTests(unittest.TestCase):
    def test_void_load_is_covered(self):
        covered, _, errors = coverage(AD, "load", "v16@0:8", "ads")
        self.assertEqual(covered, [AD + " -load"])
        self.assertEqual(errors, [])

    def test_incompatible_return_is_not_covered(self):
        covered, _, errors = coverage(AD, "load", "i16@0:8", "ads")
        self.assertEqual(covered, [])
        self.assertIn("Incompatible or unproven hook ABI: " + AD + " -load: i16@0:8", errors)

    def test_load_rejects_completion_and_unknown_abi(self):
        for encoding in ("v24@0:8@?16", None):
            with self.subTest(encoding=encoding):
                covered, _, errors = coverage(AD, "load", encoding, "ads")
                self.assertEqual(covered, [])
                self.assertTrue(errors)

    def test_scroll_provider_accepts_only_one_object(self):
        for encoding, expected in (("v24@0:8@16", True), ("v24@0:8q16", False), ("v32@0:8@16@?24", False)):
            with self.subTest(encoding=encoding):
                covered, _, errors = coverage(CTA, "registerScrollProviderIn:", encoding, "ads")
                self.assertEqual(bool(covered), expected)
                self.assertEqual(bool(errors), not expected)

    def test_ads_and_upsells_have_independent_switches(self):
        for name, right, wrong in ((AD, "ads", "upsells"), (UPSELL, "upsells", "ads")):
            with self.subTest(name=name):
                covered, _, errors = coverage(name, "load", "v16@0:8", right)
                self.assertEqual(covered, [name + " -load"])
                self.assertEqual(errors, [])
                covered, _, errors = coverage(name, "load", "v16@0:8", wrong)
                self.assertEqual(covered, [])
                self.assertIn(f"Incorrect or unspecified gate: {name}: {wrong}; expected {right}", errors)


if __name__ == "__main__":
    unittest.main()
