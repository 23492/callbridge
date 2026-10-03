"""AST guard for D-08: every Salesforce write goes through services.salesforce._sf_write.

Pure AST, no imports of the backend, so it runs with nothing installed.
"""

import ast
import pathlib
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]

WRITE_OPS = frozenset(("create", "update", "upsert", "delete"))
ALLOWED_FUNCTION = "_sf_write"


def _is_getattr_call(node: ast.AST) -> bool:
    return (
        isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == "getattr"
    )


class _WriteFinder(ast.NodeVisitor):
    """Reports <client>.<SObject>.<op>(...) calls and <name>.<op>(...) calls where
    <name> was bound by getattr(...), unless inside _sf_write.

    Dict updates (d.update(x), jobs[k].update(x)) do not match either shape."""

    def __init__(self, source: str, filename: str):
        self.source = source
        self.filename = filename
        self.function_stack: list[str] = []
        self.getattr_names: list[set[str]] = [set()]
        self.offences: list[tuple[str, int, str]] = []

    def _visit_function(self, node):
        self.function_stack.append(node.name)
        self.getattr_names.append(set())
        self.generic_visit(node)
        self.getattr_names.pop()
        self.function_stack.pop()

    visit_FunctionDef = _visit_function
    visit_AsyncFunctionDef = _visit_function

    def visit_Assign(self, node):
        if _is_getattr_call(node.value):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    self.getattr_names[-1].add(target.id)
        self.generic_visit(node)

    def _bound_by_getattr(self, name: str) -> bool:
        return any(name in scope for scope in self.getattr_names)

    def visit_Call(self, node):
        func = node.func
        if isinstance(func, ast.Attribute) and func.attr in WRITE_OPS:
            receiver = func.value
            is_sobject = isinstance(receiver, ast.Attribute) and receiver.attr[:1].isupper()
            is_getattr_bound = (
                (isinstance(receiver, ast.Name) and self._bound_by_getattr(receiver.id))
                or _is_getattr_call(receiver)
            )
            inside_guard = ALLOWED_FUNCTION in self.function_stack
            if (is_sobject or is_getattr_bound) and not inside_guard:
                text = ast.get_source_segment(self.source, node) or ast.dump(func)
                self.offences.append((self.filename, node.lineno, text))
        self.generic_visit(node)


def find_sf_writes(source: str, filename: str) -> list[tuple[str, int, str]]:
    """Return (filename, line, call text) for each Salesforce write outside _sf_write."""
    finder = _WriteFinder(source, filename)
    finder.visit(ast.parse(source, filename=filename))
    return finder.offences


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
