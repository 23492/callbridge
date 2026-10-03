"""Dry-run mode (FND-06): the real pipeline runs, nothing is written to Salesforce."""

import os
import tempfile
import unittest
from unittest import mock

from tests.python import support
from tests.python.fake_sf import FakeSalesforce

main = support.import_main()
import services.salesforce as sfsvc  # noqa: E402  (after import_main installs stubs)

CONTACT_ID = "003000000000001AAA"
ACCOUNT_ID = "001000000000001AAA"

CONTACT_QUERY = {
    "FROM Contact WHERE Id": {
        "records": [{"Id": CONTACT_ID, "Name": "Jan Jansen", "AccountId": ACCOUNT_ID}],
    },
}

ACTIONS = [
    {"description": "Offerte sturen", "due_date": "2026-10-09", "is_follow_up_call": False},
    {"description": "Terugbellen", "due_date": "2026-10-12", "is_follow_up_call": True},
]

DRY_ON = {"CALLBRIDGE_DRY_RUN": "1"}


def _temp_audio() -> str:
    fd, path = tempfile.mkstemp(suffix=".wav", prefix="test_calllog_")
    with os.fdopen(fd, "wb") as f:
        f.write(b"RIFF0000WAVE")
    return path


def _dry_lines(cm, prefix):
    return [r.getMessage() for r in cm.records if r.getMessage().startswith(prefix)]


class PipelineDryRunTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeSalesforce(query_results=CONTACT_QUERY)
        support.patch_backend(self, self.fake, actions=ACTIONS)

    def _run_pipeline(self):
        main.process_pipeline(
            "job-dry-1",
            _temp_audio(),
            "+31612345678",
            direction="Outbound",
            salesforce_id=CONTACT_ID,
            salesforce_type="Contact",
        )

    def test_pipeline_makes_no_writes(self):
        with mock.patch.dict(os.environ, DRY_ON):
            self._run_pipeline()
        self.assertEqual(self.fake.writes(), [])

    def test_pipeline_logs_every_would_be_write(self):
        with mock.patch.dict(os.environ, DRY_ON):
            with self.assertLogs("services.salesforce", level="INFO") as cm:
                self._run_pipeline()
        task_lines = _dry_lines(cm, "DRY-RUN create Task ")
        self.assertEqual(len([m for m in task_lines if "Sales Call" in m]), 1, task_lines)
        self.assertEqual(len([m for m in task_lines if "Not Started" in m]), 1, task_lines)
        self.assertEqual(len(_dry_lines(cm, "DRY-RUN create ContentNote ")), 1)
        self.assertEqual(len(_dry_lines(cm, "DRY-RUN create ContentDocumentLink ")), 1)

    def test_reads_stay_real(self):
        with mock.patch.dict(os.environ, DRY_ON):
            self._run_pipeline()
        self.assertTrue(
            any("FROM Contact WHERE Id" in q and CONTACT_ID in q for q in self.fake.queries()),
            self.fake.calls,
        )


class ReadOnlyProxyTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeSalesforce()
        support.patch_backend(self, self.fake)

    def test_direct_write_raises_in_dry_run(self):
        with mock.patch.dict(os.environ, DRY_ON):
            client = sfsvc._get_sf()
            with self.assertRaises(sfsvc.DryRunWriteBlocked):
                client.Task.create({})
            with self.assertRaises(sfsvc.DryRunWriteBlocked):
                client.Task.update("00T000000000001AAA", {})
        self.assertEqual(self.fake.writes(), [])

    def test_query_passes_through_in_dry_run(self):
        with mock.patch.dict(os.environ, DRY_ON):
            result = sfsvc._get_sf().query("SELECT Id FROM Task")
        self.assertEqual(result, {"records": []})
        self.assertIn(("query", "SELECT Id FROM Task"), self.fake.calls)


class RealModeTest(unittest.TestCase):
    CONTACT = {"Id": CONTACT_ID, "Name": "Jan Jansen", "AccountId": ACCOUNT_ID}

    def setUp(self):
        self.fake = FakeSalesforce()
        support.patch_backend(self, self.fake)

    def _assert_one_task_create(self):
        sfsvc.create_call_log(self.CONTACT, "summary", 60)
        writes = self.fake.writes()
        self.assertEqual(len(writes), 1, writes)
        self.assertEqual(writes[0][:2], ("create", "Task"))

    def test_env_unset_writes(self):
        env = {k: v for k, v in os.environ.items() if k != "CALLBRIDGE_DRY_RUN"}
        with mock.patch.dict(os.environ, env, clear=True):
            self.assertFalse(sfsvc.dry_run_enabled())
            self._assert_one_task_create()

    def test_env_zero_writes(self):
        with mock.patch.dict(os.environ, {"CALLBRIDGE_DRY_RUN": "0"}):
            self.assertFalse(sfsvc.dry_run_enabled())
            self._assert_one_task_create()


class SupportSelfTest(unittest.TestCase):
    def test_form_default_is_not_none(self):
        import fastapi
        self.assertIsNotNone(fastapi.Form(None))

    def test_assert_no_param_defaults(self):
        import fastapi
        with self.assertRaises(AssertionError):
            support.assert_no_param_defaults(self, {"client_ref": fastapi.Form(None)})
        support.assert_no_param_defaults(self, {"client_ref": None})


if __name__ == "__main__":
    unittest.main()
