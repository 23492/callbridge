"""GET /sessions/{client_ref}: where a session stands, by the app's own id.

The app polls this after a crash to decide whether to resend (FND-04 resume).
Ledger entries are written through ledger.checkpoint/claim in a fresh
CALLBRIDGE_STATE_DIR; no Salesforce client is involved.
"""

import os
import tempfile
import unittest
from unittest import mock

from tests.python import support

main = support.import_main()
from services import ledger  # noqa: E402  (after import_main installs stubs)

REF = "c0ffee00-0000-4000-8000-0000000000aa"


class SessionStatusTest(unittest.TestCase):
    def setUp(self):
        self.state_dir = tempfile.mkdtemp(prefix="callbridge-sessions-test-")
        env = {k: v for k, v in os.environ.items() if k != "CALLBRIDGE_DRY_RUN"}
        env["CALLBRIDGE_STATE_DIR"] = self.state_dir
        patcher = mock.patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        ledger._inflight.clear()
        self.addCleanup(ledger._inflight.clear)

    def status(self, ref=REF):
        kwargs = {"client_ref": ref}
        support.assert_no_param_defaults(self, kwargs)
        return main.session_status(**kwargs)

    def test_unknown_ref(self):
        self.assertEqual(self.status(),
                         {"stage": "unknown", "step": None, "task_id": None, "error": None})

    def test_in_flight_ref_is_processing_with_step(self):
        ledger.checkpoint(REF, kind="call", status="processing", step="transcribing")
        self.assertTrue(ledger.claim(REF))
        self.assertEqual(self.status(),
                         {"stage": "processing", "step": "transcribing", "task_id": None, "error": None})

    def test_done_call_reports_call_task_id(self):
        ledger.checkpoint(REF, kind="call", status="done", step="done", call_task_id="FAKETas000000000001")
        self.assertEqual(self.status(),
                         {"stage": "done", "step": "done", "task_id": "FAKETas000000000001", "error": None})

    def test_done_nno_reports_nno_task_id(self):
        ledger.checkpoint(REF, kind="nno", status="done", step="done",
                          nno_task_id="FAKETas000000000002", follow_up_task_id="FAKETas000000000003")
        result = self.status()
        self.assertEqual(result["stage"], "done")
        self.assertEqual(result["task_id"], "FAKETas000000000002")

    def test_failed_entry_reports_error(self):
        ledger.checkpoint(REF, kind="call", status="failed", step="summarizing", error="Gemini down")
        self.assertEqual(self.status(),
                         {"stage": "failed", "step": "summarizing", "task_id": None, "error": "Gemini down"})

    def test_processing_but_not_in_flight_is_interrupted(self):
        ledger.checkpoint(REF, kind="call", status="processing", step="saving_to_salesforce",
                          call_task_id="FAKETas000000000004")
        self.assertFalse(ledger.in_flight(REF))
        result = self.status()
        self.assertEqual((result["stage"], result["error"]), ("failed", "interrupted"))
        self.assertEqual(result["step"], "saving_to_salesforce")

    def test_invalid_ref_is_rejected_with_400(self):
        with self.assertRaises(main.HTTPException) as cm:
            self.status(ref="../x")
        self.assertEqual(cm.exception.status_code, 400)
        self.assertEqual(os.listdir(self.state_dir), [])


if __name__ == "__main__":
    unittest.main()
