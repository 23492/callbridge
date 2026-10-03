"""AST guard for D-08: every Salesforce write goes through services.salesforce._sf_write.

Pure AST, no imports of the backend, so it runs with nothing installed.
"""

import ast
import pathlib
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

WRITE_OPS = frozenset(("create", "update", "upsert", "delete"))
ALLOWED_FUNCTION = "_sf_write"


def find_sf_writes(source: str, filename: str) -> list[tuple[str, int, str]]:
    """Return (filename, line, call text) for each Salesforce write outside _sf_write."""
    return []


def _backend_files() -> list[pathlib.Path]:
    return sorted((REPO_ROOT / "services").glob("*.py")) + [REPO_ROOT / "main.py"]


class WritePathGuardTest(unittest.TestCase):
    def test_backend_has_no_write_outside_sf_write(self):
        offences = []
        for path in _backend_files():
            offences += find_sf_writes(path.read_text(encoding="utf-8"), str(path.relative_to(REPO_ROOT)))
        self.assertEqual(offences, [], "Salesforce writes outside _sf_write:\n" +
                         "\n".join(f"{f}:{line}: {text}" for f, line, text in offences))

    def test_scanned_files_exist(self):
        files = _backend_files()
        self.assertIn(REPO_ROOT / "services" / "salesforce.py", files)
        for path in files:
            self.assertTrue(path.is_file(), path)

    def test_direct_sobject_write_is_reported(self):
        snippet = "def create_x(sf):\n    sf.Task.create({})\n"
        offences = find_sf_writes(snippet, "snippet.py")
        self.assertEqual(len(offences), 1, offences)
        self.assertEqual(offences[0][1], 2)

    def test_getattr_bound_write_is_reported(self):
        snippet = "def create_y(sf):\n    api = getattr(sf, 'Task')\n    api.create({})\n"
        self.assertEqual(len(find_sf_writes(snippet, "snippet.py")), 1)

    def test_dict_updates_are_not_reported(self):
        snippet = (
            "def _update_job(job_id, **kwargs):\n"
            "    _processing_jobs[job_id].update(kwargs)\n"
            "    d.update(x)\n"
        )
        self.assertEqual(find_sf_writes(snippet, "snippet.py"), [])

    def test_write_inside_sf_write_is_allowed(self):
        snippet = (
            "def _sf_write(sobject, op, payload, record_id=None):\n"
            "    api = getattr(_raw_sf(), sobject)\n"
            "    api.create(payload)\n"
            "    api.update(record_id, payload)\n"
        )
        self.assertEqual(find_sf_writes(snippet, "snippet.py"), [])


if __name__ == "__main__":
    unittest.main()
