"""services/ledger.py unit tests: path safety, round trips, namespaces, pruning."""

import os
import stat
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

from tests.python import support

support.import_main()
from services import ledger  # noqa: E402  (after import_main installs stubs)

REF = "c0ffee00-0000-4000-8000-0000000000aa"
OLD_REF = "c0ffee00-0000-4000-8000-0000000000bb"
SHA = "a" * 64
CONTACT_ID = "003000000000001AAA"


class LedgerTestBase(unittest.TestCase):
    def setUp(self):
        self.state_dir = tempfile.mkdtemp(prefix="callbridge-ledger-unit-")
        env = {k: v for k, v in os.environ.items() if k != "CALLBRIDGE_DRY_RUN"}
        env["CALLBRIDGE_STATE_DIR"] = self.state_dir
        patcher = mock.patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)


class ClientRefValidationTest(LedgerTestBase):
    def test_rejects_traversal_and_bad_lengths(self):
        for bad in ("../x", "a/b", "short", "x" * 65, "", None):
            self.assertFalse(ledger.is_valid_client_ref(bad), bad)

    def test_accepts_uuid(self):
        self.assertTrue(ledger.is_valid_client_ref("3f2b8c1e-9d4a-4e6b-8f0a-1c2d3e4f5a6b"))

    def test_path_raises_for_traversal(self):
        with self.assertRaises(ValueError):
            ledger._path("../x")

    def test_checkpoint_rejects_invalid_ref(self):
        with self.assertRaises(ValueError):
            ledger.checkpoint("../x", status="done")


class RoundTripTest(LedgerTestBase):
    def test_checkpoint_lookup_round_trip(self):
        ledger.checkpoint(REF, kind="call", status="processing")
        entry = ledger.checkpoint(REF, call_task_id="00T000000000001AAA")
        self.assertEqual(entry, ledger.lookup(REF))
        self.assertEqual(entry["kind"], "call")
        self.assertEqual(entry["call_task_id"], "00T000000000001AAA")
        self.assertEqual(entry["schema"], 1)
        self.assertEqual(entry["client_ref"], REF)
        self.assertIn("created_at", entry)
        self.assertIn("updated_at", entry)

    def test_file_mode_is_0600_in_0700_dir(self):
        ledger.checkpoint(REF, status="processing")
        path = ledger._path(REF)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(path)).st_mode), 0o700)

    def test_missing_and_undecodable_return_none(self):
        self.assertIsNone(ledger.lookup(REF))
        with open(ledger._path(REF), "w") as f:
            f.write("{not json")
        with self.assertLogs("services.ledger", level="WARNING"):
            self.assertIsNone(ledger.lookup(REF))

    def test_transcript_cache_round_trip(self):
        ledger.save_transcript(REF, {"full_text": "hallo", "audio_duration": 3})
        self.assertEqual(ledger.load_transcript(REF), {"full_text": "hallo", "audio_duration": 3})


class NamespaceTest(LedgerTestBase):
    def test_dry_run_entries_live_apart(self):
        with mock.patch.dict(os.environ, {"CALLBRIDGE_DRY_RUN": "1"}):
            ledger.checkpoint(REF, status="done", call_task_id="DRYRUN-Task-0001")
            self.assertIn(os.sep + "ledger-dryrun" + os.sep, ledger._path(REF))
            self.assertIsNotNone(ledger.lookup(REF))
        self.assertIsNone(ledger.lookup(REF))
        self.assertTrue(os.path.isfile(os.path.join(self.state_dir, "ledger-dryrun", f"{REF}.json")))
        self.assertFalse(os.path.exists(os.path.join(self.state_dir, "ledger", f"{REF}.json")))


class HashIndexTest(LedgerTestBase):
    def test_link_and_lookup(self):
        self.assertIsNone(ledger.lookup_by_hash(SHA, CONTACT_ID))
        ledger.link_hash(SHA, CONTACT_ID, REF)
        self.assertEqual(ledger.lookup_by_hash(SHA, CONTACT_ID), REF)
        self.assertIsNone(ledger.lookup_by_hash(SHA, "003000000000002AAA"))

    def test_invalid_hash_or_target_raises(self):
        with self.assertRaises(ValueError):
            ledger.link_hash("../" + "a" * 61, CONTACT_ID, REF)
        with self.assertRaises(ValueError):
            ledger.lookup_by_hash(SHA, "../x")
        with self.assertRaises(ValueError):
            ledger.link_hash(SHA, CONTACT_ID, "../x")


class PruneTest(LedgerTestBase):
    def test_prune_removes_old_entries_and_keeps_new(self):
        ledger.checkpoint(OLD_REF, status="done")
        ledger.save_transcript(OLD_REF, {"full_text": "oud"})
        ledger.link_hash(SHA, CONTACT_ID, OLD_REF)
        ledger.checkpoint(REF, status="done")

        now = datetime.now(timezone.utc) + timedelta(days=31)
        # Keep REF fresh relative to "now".
        entry = ledger.lookup(REF)
        entry["updated_at"] = (now - timedelta(days=1)).isoformat()
        ledger._atomic_write(ledger._path(REF), entry)

        removed = ledger.prune(now=now)
        self.assertEqual(removed, 1)
        self.assertIsNone(ledger.lookup(OLD_REF))
        self.assertIsNone(ledger.load_transcript(OLD_REF))
        self.assertIsNone(ledger.lookup_by_hash(SHA, CONTACT_ID))
        self.assertIsNotNone(ledger.lookup(REF))

    def test_prune_never_raises(self):
        with mock.patch("services.ledger.os.listdir", side_effect=OSError("boom")):
            with self.assertLogs("services.ledger", level="WARNING"):
                self.assertEqual(ledger.prune(), 0)


if __name__ == "__main__":
    unittest.main()
