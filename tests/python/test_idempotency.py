"""FND-05: the call pipeline never creates a second call Task for the same session.

Every test runs against FakeSalesforce with a fresh CALLBRIDGE_STATE_DIR, so the
ledger starts empty and no real org or real state directory is touched.
"""

import asyncio
import os
import tempfile
import unittest
from unittest import mock

from tests.python import support
from tests.python.fake_sf import FakeSalesforce

main = support.import_main()
from services import ledger  # noqa: E402  (after import_main installs stubs)

PHONE = "+31612345678"
CONTACT_ID = "003000000000001AAA"
CONTACT2_ID = "003000000000002AAA"
ACCOUNT_ID = "001000000000001AAA"

REF1 = "c0ffee00-0000-4000-8000-000000000001"
REF2 = "c0ffee00-0000-4000-8000-000000000002"
REF3 = "c0ffee00-0000-4000-8000-000000000003"

QUERIES = {
    f"WHERE Id = '{CONTACT_ID}'": {
        "records": [{"Id": CONTACT_ID, "Name": "Jan Jansen", "AccountId": ACCOUNT_ID}],
    },
    f"WHERE Id = '{CONTACT2_ID}'": {
        "records": [{"Id": CONTACT2_ID, "Name": "Piet Pietersen", "AccountId": ACCOUNT_ID}],
    },
}


def _call_task_creates(fake):
    return [w for w in fake.writes()
            if w[:2] == ("create", "Task") and w[2].get("Log_Type__c") == "Sales Call"]


def _creates(fake, sobject):
    return [w for w in fake.writes() if w[:2] == ("create", sobject)]


def _action_task_creates(fake):
    return [w for w in fake.writes()
            if w[:2] == ("create", "Task") and w[2].get("Status") == "Not Started"]


class LedgerTestCase(unittest.TestCase):
    """Fresh state dir, real mode, FakeSalesforce; helpers to call /process."""

    actions = None

    def setUp(self):
        self.state_dir = tempfile.mkdtemp(prefix="callbridge-ledger-test-")
        env = {k: v for k, v in os.environ.items() if k != "CALLBRIDGE_DRY_RUN"}
        env["CALLBRIDGE_STATE_DIR"] = self.state_dir
        patcher = mock.patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        ledger._inflight.clear()
        self.addCleanup(ledger._inflight.clear)
        self.fake = FakeSalesforce(query_results=QUERIES)
        self.mocks = support.patch_backend(self, self.fake, actions=self.actions)

    def post(self, data=b"audio-1", ref=REF1, sf_id=CONTACT_ID, sf_type="Contact"):
        bg = main.BackgroundTasks()
        kwargs = {
            "background_tasks": bg,
            "audio": support.FakeUpload("call.m4a", data),
            "phone_number": PHONE,
            "direction": "Outbound",
            "salesforce_id": sf_id,
            "salesforce_type": sf_type,
            "client_ref": ref,
        }
        support.assert_no_param_defaults(self, kwargs)
        response = asyncio.run(main.process_recording(**kwargs))
        return response, bg

    def post_and_run(self, **kwargs):
        response, bg = self.post(**kwargs)
        support.run_background(bg)
        return response, bg


class SameSessionTwiceTest(LedgerTestCase):
    def test_first_post_creates_one_call_task(self):
        response, bg = self.post_and_run()
        self.assertEqual(response["status"], "processing")
        self.assertEqual(len(_call_task_creates(self.fake)), 1, self.fake.writes())

    def test_second_post_returns_duplicate_and_writes_nothing(self):
        self.post_and_run()
        writes_before = list(self.fake.writes())
        task_id = ledger.lookup(REF1)["call_task_id"]
        response, bg = self.post()
        self.assertEqual(response, {"status": "duplicate", "task_id": task_id})
        self.assertEqual(getattr(bg, "tasks", []), [])
        self.assertEqual(self.fake.writes(), writes_before)

    def test_two_real_recordings_stay_two_tasks(self):
        self.post_and_run(data=b"audio-1", ref=REF1)
        self.post_and_run(data=b"audio-2", ref=REF2)
        self.assertEqual(len(_call_task_creates(self.fake)), 2, self.fake.writes())

    def test_step_tracks_update_job(self):
        self.post_and_run()
        entry = ledger.lookup(REF1)
        self.assertEqual((entry["status"], entry["step"]), ("done", "done"))
        self.assertEqual(entry["kind"], "call")
        self.assertEqual(entry["schema"], 1)

    def test_failure_in_summarizing_step_leaves_step_summarizing(self):
        # A generate_summary failure is non-fatal in the pipeline by design (the
        # call is logged with a fallback summary), so the failure is injected in
        # the same step: a transcription result without audio_duration.
        self.mocks["summary"].side_effect = RuntimeError("Gemini down")
        self.mocks["transcribe"].return_value = {"full_text": "Speaker A: hallo."}
        self.post_and_run()
        entry = ledger.lookup(REF1)
        self.assertEqual((entry["status"], entry["step"]), ("failed", "summarizing"))
        self.assertEqual(_call_task_creates(self.fake), [])

    def test_other_kind_is_rejected_with_409(self):
        ledger.checkpoint(REF1, kind="nno", status="done", step="done")
        with self.assertRaises(main.HTTPException) as cm:
            self.post()
        self.assertEqual(cm.exception.status_code, 409)
        self.assertEqual(self.fake.writes(), [])

    def test_state_dir_defaults_to_application_support(self):
        env = {k: v for k, v in os.environ.items() if k != "CALLBRIDGE_STATE_DIR"}
        cwd = os.getcwd()
        elsewhere = tempfile.mkdtemp(prefix="callbridge-cwd-")
        with mock.patch.dict(os.environ, env, clear=True):
            os.chdir(elsewhere)
            try:
                result = ledger.state_dir()
            finally:
                os.chdir(cwd)
        expected = os.path.join(os.environ["HOME"], "Library", "Application Support",
                                "com.welisa.CallBridge")
        self.assertEqual(result, expected)


if __name__ == "__main__":
    unittest.main()
