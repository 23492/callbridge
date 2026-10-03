import json
import logging
import os
import re
import tempfile
import threading
from datetime import datetime, timezone

from services.salesforce import dry_run_enabled

logger = logging.getLogger(__name__)

# One JSON file per session (client_ref) records which Salesforce writes already
# happened, so a retry or resume never creates a second call Task, note or action
# Task (FND-05). The format carries "schema": 1; entries expire after 30 days.

# client_ref becomes a filename: validate before any path is built (Pitfall 9).
_CLIENT_REF_RE = re.compile(r"^[A-Za-z0-9-]{8,64}$")

SCHEMA_VERSION = 1

_ledger_lock = threading.Lock()
# Sessions whose pipeline is running in this process (uvicorn runs sync
# background tasks in a threadpool, so two pipelines can run at once).
_inflight: set[str] = set()


def is_valid_client_ref(value: str | None) -> bool:
    return bool(value) and bool(_CLIENT_REF_RE.match(value))


def state_dir() -> str:
    """Root of the backend state. Never the cwd: a backend started from the repo
    must not write a ledger into the working tree. CALLBRIDGE_STATE_DIR is the
    test override."""
    return os.getenv("CALLBRIDGE_STATE_DIR") or os.path.expanduser(
        "~/Library/Application Support/com.welisa.CallBridge"
    )


def _ledger_dir() -> str:
    """Dry-run results live in their own namespace, so a later real run is never
    deduplicated against fake DRYRUN ids."""
    name = "ledger-dryrun" if dry_run_enabled() else "ledger"
    path = os.path.join(state_dir(), name)
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


def _path(ref: str) -> str:
    if not is_valid_client_ref(ref):
        raise ValueError(f"Invalid client_ref: {ref!r}")
    return os.path.join(_ledger_dir(), f"{ref}.json")


def _atomic_write(path: str, obj) -> None:
    directory = os.path.dirname(path)
    with tempfile.NamedTemporaryFile("w", dir=directory, delete=False, encoding="utf-8") as tmp:
        json.dump(obj, tmp, ensure_ascii=False, sort_keys=True)
        tmp.flush()
        os.fsync(tmp.fileno())
        tmp_name = tmp.name
    os.replace(tmp_name, path)
    os.chmod(path, 0o600)


def _read_json(path: str):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        logger.warning("Unreadable ledger file %s: %s", path, e)
        return None


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def lookup(ref: str | None) -> dict | None:
    """The ledger entry for ref, or None when missing or undecodable.

    ref None means the caller has no session (direct pipeline callers): None.
    """
    if ref is None:
        return None
    entry = _read_json(_path(ref))
    return entry if isinstance(entry, dict) else None


def _transcript_path(ref: str) -> str:
    if not is_valid_client_ref(ref):
        raise ValueError(f"Invalid client_ref: {ref!r}")
    return os.path.join(_ledger_dir(), f"{ref}.transcript.json")


def save_transcript(ref: str | None, result: dict) -> None:
    """Cache the transcription result, so a resume never pays AssemblyAI twice."""
    if ref is None:
        return
    _atomic_write(_transcript_path(ref), result)


def load_transcript(ref: str | None) -> dict | None:
    if ref is None:
        return None
    result = _read_json(_transcript_path(ref))
    return result if isinstance(result, dict) else None


def checkpoint(ref: str | None, **fields) -> dict:
    """Merge fields into the entry for ref and write it atomically. Returns the entry.

    ref None (no session) records nothing and returns {}, so the pipeline can
    checkpoint on the line right after each create without a branch in between.
    """
    if ref is None:
        return {}
    path = _path(ref)
    with _ledger_lock:
        entry = _read_json(path)
        if not isinstance(entry, dict):
            entry = {"schema": SCHEMA_VERSION, "client_ref": ref, "created_at": _now_iso()}
        entry.update(fields)
        entry["updated_at"] = _now_iso()
        _atomic_write(path, entry)
        return entry


def claim(ref: str) -> bool:
    """Mark ref as in flight. False when a pipeline for ref already runs."""
    with _ledger_lock:
        if ref in _inflight:
            return False
        _inflight.add(ref)
        return True


def release(ref: str | None) -> None:
    if ref is None:
        return
    with _ledger_lock:
        _inflight.discard(ref)


def in_flight(ref: str) -> bool:
    with _ledger_lock:
        return ref in _inflight
