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


class FollowUpDryRunTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeSalesforce(query_results={
            "FROM Task WHERE WhoId": {
                "records": [{"Id": "00T000000000009AAA", "Subject": "Call back"}],
            },
        })
        support.patch_backend(self, self.fake)

    def test_set_follow_up_date_logs_and_does_not_write(self):
        with mock.patch.dict(os.environ, DRY_ON):
            with self.assertLogs("services.salesforce", level="INFO") as cm:
                sfsvc.set_follow_up_date("00T000000000001AAA", "2026-10-09")
        lines = _dry_lines(cm, "DRY-RUN update Task 00T000000000001AAA")
        self.assertEqual(len(lines), 1, cm.output)
        self.assertIn("Auto_Generate_Follow_Up_Task__c", lines[0])
        self.assertEqual(self.fake.writes(), [])

    def test_complete_due_followups_logs_and_keeps_query(self):
        with mock.patch.dict(os.environ, DRY_ON):
            with self.assertLogs("services.salesforce", level="INFO") as cm:
                done = sfsvc.complete_due_followup_tasks(CONTACT_ID)
        self.assertEqual(done, 1)
        lines = _dry_lines(cm, "DRY-RUN update Task ")
        self.assertEqual(len(lines), 1, cm.output)
        self.assertIn("Completed", lines[0])
        self.assertEqual(self.fake.writes(), [])
        self.assertTrue(any("FROM Task WHERE WhoId" in q for q in self.fake.queries()))


class NnoDryRunTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeSalesforce(query_results=CONTACT_QUERY)
        support.patch_backend(self, self.fake)

    def _log_nno(self):
        kwargs = {"salesforce_id": CONTACT_ID, "salesforce_type": "Contact", "client_ref": None}
        support.assert_no_param_defaults(self, kwargs)
        return main.log_nno(**kwargs)

    def test_nno_dry_run_makes_no_writes_and_logs_two_tasks(self):
        with mock.patch.dict(os.environ, DRY_ON):
            with self.assertLogs("services.salesforce", level="INFO") as cm:
                self._log_nno()
        self.assertEqual(self.fake.writes(), [])
        lines = _dry_lines(cm, "DRY-RUN create Task ")
        self.assertEqual(len(lines), 2, cm.output)
        self.assertTrue(any('"NNO"' in m for m in lines), lines)
        self.assertTrue(any('"Call back"' in m for m in lines), lines)

    def test_nno_dry_run_marks_menu_entry(self):
        with mock.patch.dict(os.environ, DRY_ON):
            self._log_nno()
        self.assertTrue(main._completed_jobs[0]["contact_name"].startswith("[DRY-RUN] "))

    def test_nno_real_mode_creates_two_tasks(self):
        with mock.patch.dict(os.environ, {"CALLBRIDGE_DRY_RUN": "0"}):
            self._log_nno()
        writes = self.fake.writes()
        self.assertEqual([w[:2] for w in writes], [("create", "Task"), ("create", "Task")], writes)
        self.assertFalse(main._completed_jobs[0]["contact_name"].startswith("[DRY-RUN]"))


class PipelineMenuMarkingTest(unittest.TestCase):
    def setUp(self):
        self.fake = FakeSalesforce(query_results=CONTACT_QUERY)
        support.patch_backend(self, self.fake, actions=ACTIONS)

    def test_pipeline_dry_run_marks_menu_entry(self):
        with mock.patch.dict(os.environ, DRY_ON):
            main.process_pipeline(
                "job-dry-2", _temp_audio(), "+31612345678", direction="Outbound",
                salesforce_id=CONTACT_ID, salesforce_type="Contact",
            )
        self.assertEqual(main._completed_jobs[0]["contact_name"], "[DRY-RUN] Jan Jansen")


class DryRunVisibilityTest(unittest.TestCase):
    def _env_without_flag(self):
        return {k: v for k, v in os.environ.items() if k != "CALLBRIDGE_DRY_RUN"}

    def test_health_reports_dry_run_true(self):
        with mock.patch.dict(os.environ, DRY_ON):
            body = main.health()
        self.assertIs(body["dry_run"], True)
        for key in ("status", "pid", "ppid"):
            self.assertIn(key, body)

    def test_health_reports_dry_run_false(self):
        with mock.patch.dict(os.environ, self._env_without_flag(), clear=True):
            self.assertIs(main.health()["dry_run"], False)
        with mock.patch.dict(os.environ, {"CALLBRIDGE_DRY_RUN": "0"}):
            body = main.health()
        self.assertIs(body["dry_run"], False)
        for key in ("status", "pid", "ppid"):
            self.assertIn(key, body)

    def test_startup_line_when_dry_run(self):
        with mock.patch.dict(os.environ, DRY_ON):
            with self.assertLogs("main", level="WARNING") as cm:
                main.log_dry_run_state()
        self.assertEqual([r.getMessage() for r in cm.records], ["DRY-RUN active: no Salesforce writes"])
        self.assertEqual(cm.records[0].levelname, "WARNING")

    def test_no_startup_line_when_real(self):
        with mock.patch.dict(os.environ, self._env_without_flag(), clear=True):
            with self.assertNoLogs("main", level="DEBUG"):
                main.log_dry_run_state()


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
