"""Shared helpers for the backend tests.

The backend imports fastapi, starlette, pydantic, simple_salesforce and requests.
Those packages are installed in CI and on the Mac, but not on every dev box.
install_fallback_stubs() registers minimal stand-ins in sys.modules, and only for
modules that importlib cannot find, so the same tests run against the real
packages where they exist and against the stand-ins elsewhere.

Safety: import_main() strips the Salesforce and API credentials from the
environment before importing the backend, and the stand-in Salesforce class
raises when instantiated. Tests patch services.salesforce._raw_sf with a
FakeSalesforce, so no test can reach a real org.

RULE: tests call endpoint functions (process_recording, process_manual, log_nno, session_status) with every parameter passed explicitly, including optional ones such as client_ref=None; never rely on a Form/File/Query default.
With the real fastapi an omitted argument receives a FieldInfo object as its
default (not None); with the stand-ins it receives a _ParamDefault sentinel.
assert_no_param_defaults() catches both.
"""

import importlib
import importlib.util
import os
import sys
import tempfile
import types
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]

_CREDENTIAL_VARS = (
    "SF_USERNAME",
    "SF_PASSWORD",
    "SF_SECURITY_TOKEN",
    "ASSEMBLYAI_API_KEY",
    "GEMINI_API_KEY",
)

API_USER_ID = "005000000000001AAA"


class _ParamDefault:
    """Stand-in for the object fastapi's Form/File/Query return as a default.

    Never None and never the bare default, so an endpoint parameter a test forgot
    to pass is visible instead of silently behaving like None.
    """

    def __init__(self, default):
        self.default = default

    def __repr__(self):
        return f"_ParamDefault(default={self.default!r})"


def _is_missing(name: str) -> bool:
    if name in sys.modules:
        return False
    try:
        return importlib.util.find_spec(name) is None
    except (ModuleNotFoundError, ValueError):
        # Parent is missing or is one of our stand-ins (no __path__).
        return True


def _module(name: str, **attrs) -> types.ModuleType:
    mod = types.ModuleType(name)
    mod.__dict__.update(attrs)
    return mod


def _install(name: str, **attrs) -> None:
    if not _is_missing(name):
        return
    mod = _module(name, **attrs)
    sys.modules[name] = mod
    parent, _, child = name.rpartition(".")
    if parent and parent in sys.modules:
        setattr(sys.modules[parent], child, mod)


def _identity_decorator(*_args, **_kwargs):
    def wrap(func):
        return func
    return wrap


def _build_fastapi_attrs() -> dict:
    class FastAPI:
        def __init__(self, *args, **kwargs):
            pass

        get = staticmethod(_identity_decorator)
        post = staticmethod(_identity_decorator)
        middleware = staticmethod(_identity_decorator)
        on_event = staticmethod(_identity_decorator)

        def add_middleware(self, *args, **kwargs):
            pass

        def mount(self, *args, **kwargs):
            pass

    class _QueuedTask:
        # Same attribute names as starlette's BackgroundTask.
        def __init__(self, func, args, kwargs):
            self.func = func
            self.args = args
            self.kwargs = kwargs

    class BackgroundTasks:
        def __init__(self):
            self.tasks = []

        def add_task(self, func, *args, **kwargs):
            self.tasks.append(_QueuedTask(func, args, kwargs))

    class UploadFile:
        pass

    class Request:
        pass

    class HTTPException(Exception):
        def __init__(self, status_code, detail=None):
            super().__init__(status_code, detail)
            self.status_code = status_code
            self.detail = detail

    def File(default=..., **_kwargs):
        return _ParamDefault(default)

    def Form(default=..., **_kwargs):
        return _ParamDefault(default)

    def Query(default=..., **_kwargs):
        return _ParamDefault(default)

    return {
        "FastAPI": FastAPI,
        "BackgroundTasks": BackgroundTasks,
        "UploadFile": UploadFile,
        "Request": Request,
        "HTTPException": HTTPException,
        "File": File,
        "Form": Form,
        "Query": Query,
    }


def install_fallback_stubs() -> None:
    """Register stand-ins for backend dependencies that are not installed."""

    class Salesforce:
        def __init__(self, *args, **kwargs):
            raise RuntimeError("stand-in Salesforce: tests must never open a real connection")

    _install("simple_salesforce", Salesforce=Salesforce)

    def _no_network(*_args, **_kwargs):
        raise RuntimeError("stand-in requests: tests must never reach the network")

    class _ConnectionError(Exception):
        pass

    class _Timeout(Exception):
        pass

    _install("requests", post=_no_network, get=_no_network,
             ConnectionError=_ConnectionError, Timeout=_Timeout)

    _install("fastapi", **_build_fastapi_attrs())

    class JSONResponse:
        def __init__(self, content=None, status_code=200, **_kwargs):
            self.content = content
            self.status_code = status_code

    _install("fastapi.responses", JSONResponse=JSONResponse)

    class StaticFiles:
        def __init__(self, *args, **kwargs):
            pass

    _install("fastapi.staticfiles", StaticFiles=StaticFiles)

    class TrustedHostMiddleware:
        def __init__(self, *args, **kwargs):
            pass

    _install("starlette")
    _install("starlette.middleware")
    _install("starlette.middleware.trustedhost", TrustedHostMiddleware=TrustedHostMiddleware)

    class BaseModel:
        def __init__(self, **kwargs):
            self.__dict__.update(kwargs)

    _install("pydantic", BaseModel=BaseModel)


def import_main():
    """Import the backend's main module safely (no credentials, temp HOME)."""
    install_fallback_stubs()
    os.environ["HOME"] = tempfile.mkdtemp(prefix="callbridge-home-")
    for var in _CREDENTIAL_VARS:
        os.environ.pop(var, None)
    os.environ["CALLBRIDGE_STATE_DIR"] = tempfile.mkdtemp(prefix="callbridge-state-")
    if str(REPO_ROOT) not in sys.path:
        sys.path.insert(0, str(REPO_ROOT))
    main = importlib.import_module("main")
    # Belt and braces: if config was imported earlier with credentials present,
    # blank the copies the backend modules hold.
    for mod_name in ("config", "services.salesforce", "services.transcription", "services.summarizer"):
        mod = sys.modules.get(mod_name)
        if mod is None:
            continue
        for var in _CREDENTIAL_VARS:
            if hasattr(mod, var):
                setattr(mod, var, None)
    return main


DEFAULT_TRANSCRIPTION = {"full_text": "Speaker A: hallo, met Kiran.", "audio_duration": 120}
DEFAULT_SUMMARY = "Samenvatting van het gesprek."


def patch_backend(test_case, fake, transcription=None, summary=None, actions=None):
    """Patch Salesforce and the AI services with fakes for one test.

    Returns a dict of the started mocks (keys: transcribe, summary, extract, notify).
    """
    transcription = DEFAULT_TRANSCRIPTION if transcription is None else transcription
    summary = DEFAULT_SUMMARY if summary is None else summary
    actions = [] if actions is None else actions

    targets = {
        "raw_sf": mock.patch("services.salesforce._raw_sf", return_value=fake),
        "user_id": mock.patch("services.salesforce._get_user_id", return_value=API_USER_ID),
        "transcribe": mock.patch("main.transcribe_audio", return_value=transcription),
        "summary": mock.patch("main.generate_summary", return_value=summary),
        "extract": mock.patch("main.extract_action_items", return_value=actions),
        "notify": mock.patch("main._notify"),
    }
    started = {}
    for key, patcher in targets.items():
        started[key] = patcher.start()
        test_case.addCleanup(patcher.stop)
    return started


def run_background(tasks) -> None:
    """Run queued background tasks (a BackgroundTasks instance or its list) in order."""
    queued = getattr(tasks, "tasks", tasks)
    for task in queued:
        task.func(*task.args, **task.kwargs)


class FakeUpload:
    """Minimal UploadFile stand-in for calling /process directly."""

    def __init__(self, filename, data: bytes):
        self.filename = filename
        self._data = data

    async def read(self):
        return self._data


def _is_param_default(value) -> bool:
    if isinstance(value, _ParamDefault):
        return True
    return any(cls.__name__ == "FieldInfo" for cls in type(value).__mro__)


def assert_no_param_defaults(test_case, kwargs: dict) -> None:
    """Fail when any endpoint argument is an unresolved Form/File/Query default."""
    offenders = sorted(k for k, v in kwargs.items() if _is_param_default(v))
    if offenders:
        test_case.fail(f"endpoint arguments left as Form/File/Query defaults: {offenders}")
