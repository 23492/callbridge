import logging
import os
import subprocess
import sys
import tempfile
import threading
import uuid
from collections import deque
from pathlib import Path

from fastapi import FastAPI, UploadFile, File, BackgroundTasks, Form, Query, HTTPException, Request
from fastapi.responses import JSONResponse
from starlette.middleware.trustedhost import TrustedHostMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from services.transcription import transcribe_audio
from services.summarizer import generate_summary, extract_action_items
from services.salesforce import (
    find_contact_by_phone,
    resolve_provided_record,
    search_contacts,
    create_call_log,
    create_transcript_note,
    create_action_task,
    create_nno_log,
    complete_due_followup_tasks,
    fetch_my_open_future_tasks,
    ALLOWED_RECORD_TYPES,
    is_valid_sf_id,
    _get_user_id,
    dry_run_enabled,
)

# Ensure log directory exists before opening FileHandler (D-12)
_log_dir = Path.home() / "Library" / "Logs" / "CallBridge"
_log_dir.mkdir(parents=True, exist_ok=True)

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[
        logging.FileHandler(os.path.join(Path.home(), "Library", "Logs", "CallBridge", "call_logger.log")),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger(__name__)

# PyInstaller bundle detection: use sys._MEIPASS when frozen, __file__ dir otherwise
if getattr(sys, 'frozen', False):
    _base_dir = sys._MEIPASS
else:
    _base_dir = os.path.dirname(os.path.abspath(__file__))

app = FastAPI(title="Call Logger", version="2.0.0")

# Browsers let any web page send "simple" cross-origin form POSTs to localhost
# (CORS only blocks reading the response), so an arbitrary site could otherwise
# create Tasks in the production org via /log-nno or /process. CallBridge's
# URLSession sends no Origin header; the dashboard's origin is this server.
_ALLOWED_ORIGINS = {"http://localhost:8765", "http://127.0.0.1:8765"}


# DNS rebinding: a hostile domain resolving to 127.0.0.1 would pass the Origin
# check's absence and could read /contact-search. Only accept our own host names.
app.add_middleware(TrustedHostMiddleware, allowed_hosts=["localhost", "127.0.0.1"])


@app.middleware("http")
async def reject_foreign_origins(request: Request, call_next):
    origin = request.headers.get("origin")
    if origin and origin not in _ALLOWED_ORIGINS:
        logger.warning("Rejected %s %s from foreign origin %s", request.method, request.url.path, origin)
        return JSONResponse(status_code=403, content={"detail": "Forbidden origin"})
    return await call_next(request)

# Job tracking for /status endpoint
_jobs_lock = threading.Lock()
_processing_jobs: dict[str, dict] = {}
_completed_jobs: deque = deque(maxlen=3)


def _start_job(job_id: str):
    with _jobs_lock:
        _processing_jobs[job_id] = {"job_id": job_id, "contact_name": "Onbekend", "step": "starting"}


def _update_job(job_id: str, **kwargs):
    with _jobs_lock:
        if job_id in _processing_jobs:
            _processing_jobs[job_id].update(kwargs)


def _display_name(name: str) -> str:
    """Menu label: in dry-run the entry carries fake DRYRUN ids, so mark it."""
    if dry_run_enabled():
        return "[DRY-RUN] " + name
    return name


def _complete_job(job_id: str, contact_name: str, contact_id: str, contact_type: str, task_id: str):
    future_tasks = _fetch_future_tasks(contact_id)
    with _jobs_lock:
        _processing_jobs.pop(job_id, None)
        _completed_jobs.appendleft({
            "contact_name": _display_name(contact_name),
            "contact_id": contact_id,
            "contact_type": contact_type,
            "task_id": task_id,
            "future_tasks": future_tasks,
        })


def _fetch_future_tasks(record_id: str | None) -> list[dict]:
    """Open future tasks on the record (Who or What) owned by the API user."""
    return fetch_my_open_future_tasks(record_id)


def _fail_job(job_id: str):
    with _jobs_lock:
        _processing_jobs.pop(job_id, None)


# Serve dashboard static files
app.mount("/dashboard", StaticFiles(directory=os.path.join(_base_dir, "dashboard"), html=True), name="dashboard")


def log_dry_run_state() -> None:
    """Make dry-run visible in the backend log at startup (checked before prod dry-runs)."""
    if dry_run_enabled():
        logger.warning("DRY-RUN active: no Salesforce writes")


@app.on_event("startup")
def start_seed_recent_calls():
    log_dry_run_state()
    # In the background: a Salesforce login + queries here used to delay binding
    # :8765 by seconds, which the app's health checks read as a dead backend.
    threading.Thread(target=seed_recent_calls, name="seed-recent-calls", daemon=True).start()


def seed_recent_calls():
    """Load last 3 Auto Logger call tasks from Salesforce on startup."""
    try:
        from services.salesforce import _get_sf
        sf = _get_sf()
        # Shared org: only the API user's own calls, never colleagues'.
        results = sf.query(
            "SELECT Id, WhoId, Who.Name, Who.Type, WhatId, What.Name, What.Type "
            "FROM Task WHERE (Log_Type__c = 'Sales Call' OR Subject = 'NNO') "
            f"AND OwnerId = '{_get_user_id()}' "
            "ORDER BY CreatedDate DESC LIMIT 3"
        )
        for record in results["records"]:
            # Prefer the person (Contact/Lead) the call was logged on; fall back to the Account.
            if record.get("WhoId"):
                rel, contact_id = record.get("Who") or {}, record["WhoId"]
            else:
                rel, contact_id = record.get("What") or {}, record.get("WhatId") or ""
            contact_name = rel.get("Name") or "Onbekend"
            contact_type = rel.get("Type") or "Account"
            task_id = record["Id"]
            future_tasks = _fetch_future_tasks(contact_id)
            with _jobs_lock:
                _completed_jobs.append({
                    "contact_name": contact_name,
                    "contact_id": contact_id,
                    "contact_type": contact_type,
                    "task_id": task_id,
                    "future_tasks": future_tasks,
                })
        logger.info("Seeded %d recent calls from Salesforce", len(results["records"]))
    except Exception as e:
        logger.warning("Failed to seed recent calls: %s", e)


@app.get("/health")
def health():
    # pid/ppid let the app tell its own backend apart from an orphan holding :8765.
    # dry_run lets a caller confirm the mode before any step that could write.
    return {"status": "ok", "pid": os.getpid(), "ppid": os.getppid(), "dry_run": dry_run_enabled()}


class CredentialValidationRequest(BaseModel):
    SF_USERNAME: str
    SF_PASSWORD: str
    SF_SECURITY_TOKEN: str
    SF_DOMAIN: str


@app.post("/validate-credentials")
def validate_credentials(body: CredentialValidationRequest):
    """Read-only Salesforce credential check — calls limits() only, no record creation."""
    try:
        from simple_salesforce import Salesforce
        sf = Salesforce(
            username=body.SF_USERNAME,
            password=body.SF_PASSWORD,
            security_token=body.SF_SECURITY_TOKEN,
            domain=body.SF_DOMAIN,
        )
        sf.limits()
        return {"status": "ok"}
    except Exception as e:
        from fastapi import HTTPException
        raise HTTPException(status_code=400, detail={"error": str(e)})


@app.get("/status")
def status():
    with _jobs_lock:
        processing = list(_processing_jobs.values())
        completed = list(_completed_jobs)
    return {"processing": processing, "completed": completed}


@app.get("/contact-search")
def contact_search(
    phone: str | None = Query(None),
    q: str | None = Query(None),
):
    """
    Search Salesforce by phone number or name.
    Used by CallBridge to show contact info before saving.
    """
    if phone:
        result = find_contact_by_phone(phone)
        if result:
            from services.salesforce import _normalize_record
            # find_contact_by_phone returns raw or semi-normalized records
            # Normalize for the API
            obj_type = result.get("attributes", {}).get("type")
            if obj_type:
                return {"results": [_normalize_record(result)]}
            # Already a dict without attributes (Account/Lead fallback format)
            return {"results": [{
                "id": result.get("Id"),
                "name": result.get("Name"),
                "type": obj_type or "Unknown",
                "phone": phone,
                "account_name": result.get("AccountId") and result.get("Name"),
                "account_id": result.get("AccountId"),
            }]}
        return {"results": []}
    elif q:
        results = search_contacts(q)
        return {"results": results}
    return {"results": []}


@app.post("/log-nno")
def log_nno(
    salesforce_id: str = Form(...),
    salesforce_type: str = Form(...),
):
    """
    Log an NNO (Niet opgenomen). Creates a completed NNO task and a
    follow-up 'Call back' task for the next day.

    Sync (not async) on purpose: the Salesforce calls block, and an async handler
    would stall the event loop — and with it /health and /status — for seconds.
    """
    try:
        contact = resolve_provided_record(salesforce_id, salesforce_type)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    logger.info("Logging NNO for %s (%s/%s)", contact["Name"], salesforce_type, salesforce_id)
    nno_id, follow_up_id = create_nno_log(contact)

    # NNO creates a follow-up task for tomorrow, so fetch future tasks
    future_tasks = _fetch_future_tasks(salesforce_id)
    with _jobs_lock:
        _completed_jobs.appendleft({
            "contact_name": _display_name(contact["Name"]),
            "contact_id": salesforce_id,
            "contact_type": salesforce_type,
            "task_id": nno_id,
            "future_tasks": future_tasks,
        })

    return {
        "status": "ok",
        "nno_task_id": nno_id,
        "follow_up_task_id": follow_up_id,
        "contact_name": contact["Name"],
    }


@app.post("/process")
async def process_recording(
    background_tasks: BackgroundTasks,
    audio: UploadFile = File(...),
    phone_number: str = Form(...),
    direction: str = Form("Outbound"),
    salesforce_id: str | None = Form(None),
    salesforce_type: str | None = Form(None),
):
    """
    Process an audio recording. Called by CallBridge after user confirms save.
    Phone number is always provided by CallBridge.
    """
    if salesforce_id or salesforce_type:
        if salesforce_type not in ALLOWED_RECORD_TYPES or not is_valid_sf_id(salesforce_id):
            raise HTTPException(status_code=400, detail="Invalid salesforce_id/salesforce_type")
    suffix = os.path.splitext(audio.filename or ".wav")[1]
    fd, temp_path = tempfile.mkstemp(suffix=suffix, prefix="calllog_")
    with os.fdopen(fd, "wb") as f:
        content = await audio.read()
        f.write(content)

    logger.info("Received: %s, phone: %s, sf: %s/%s", audio.filename, phone_number, salesforce_type, salesforce_id)

    job_id = str(uuid.uuid4())
    _start_job(job_id)
    background_tasks.add_task(
        process_pipeline,
        job_id,
        temp_path,
        phone_number=phone_number,
        direction=direction,
        salesforce_id=salesforce_id,
        salesforce_type=salesforce_type,
    )

    return {"status": "processing", "file": audio.filename, "phone": phone_number}


@app.post("/process-manual")
async def process_manual(
    background_tasks: BackgroundTasks,
    audio: UploadFile = File(...),
    phone_number: str = Form(...),
    direction: str = Form("Outbound"),
):
    """Dashboard endpoint for manual uploads."""
    suffix = os.path.splitext(audio.filename or ".wav")[1]
    fd, temp_path = tempfile.mkstemp(suffix=suffix, prefix="calllog_")
    with os.fdopen(fd, "wb") as f:
        content = await audio.read()
        f.write(content)

    logger.info("Manual upload: %s, phone: %s", audio.filename, phone_number)

    job_id = str(uuid.uuid4())
    _start_job(job_id)
    background_tasks.add_task(
        process_pipeline, job_id, temp_path, phone_number=phone_number, direction=direction
    )

    return {"status": "processing", "file": audio.filename, "phone": phone_number}


def process_pipeline(
    job_id: str,
    audio_path: str,
    phone_number: str,
    direction: str = "Outbound",
    salesforce_id: str | None = None,
    salesforce_type: str | None = None,
):
    """
    Full processing pipeline. Runs as a sync background task.
    Phone number is always provided (by CallBridge or dashboard).
    """
    try:
        # 1. Find contact in Salesforce (or use provided ID)
        resolved_type = salesforce_type or "Contact"
        if salesforce_id and salesforce_type:
            contact = resolve_provided_record(salesforce_id, salesforce_type)
            resolved_type = salesforce_type
            logger.info("Using provided Salesforce record: %s (%s)", contact["Name"], salesforce_type)
        else:
            contact = find_contact_by_phone(phone_number)
            if contact is None:
                logger.error("No Salesforce contact found for %s. Skipping.", phone_number)
                _notify_error(f"Geen contact gevonden voor {phone_number}")
                _fail_job(job_id)
                return
            resolved_type = contact.get("attributes", {}).get("type", "Contact")

        _update_job(job_id, contact_name=contact["Name"], step="transcribing")

        # 2. Transcribe audio via AssemblyAI
        logger.info("Transcribing audio for %s...", contact["Name"])
        result = transcribe_audio(audio_path)
        transcript = result["full_text"]

        if not transcript.strip():
            logger.warning("Empty transcript for %s. Skipping.", contact["Name"])
            _notify_error(f"Leeg transcript voor {contact['Name']}")
            _fail_job(job_id)
            return

        _update_job(job_id, step="summarizing")

        # 3. Generate summary via Gemini. A failure here must not throw away a paid-for
        # transcript: log the call anyway, with the transcript attached as usual.
        logger.info("Generating summary...")
        summary_ok = True
        try:
            summary = generate_summary(transcript)
        except Exception as e:
            logger.error("Summary generation failed (logging call without summary): %s", e, exc_info=True)
            summary = f"Samenvatting mislukt ({e}). Zie het transcript in de bijlage."
            summary_ok = False

        # 4. Get call duration from AssemblyAI response
        duration = result["audio_duration"]

        _update_job(job_id, step="extracting_actions")

        # 5. Extract action items from summary
        follow_up_date = None
        actions = []
        try:
            actions = extract_action_items(summary) if summary_ok else []
            for action in actions:
                if action.get("is_follow_up_call") and action.get("due_date"):
                    follow_up_date = action["due_date"]
            logger.info("Extracted %d action items (follow-up: %s)", len(actions), follow_up_date)
        except Exception as e:
            logger.warning("Action item extraction failed (non-fatal): %s", e)

        _update_job(job_id, step="saving_to_salesforce")

        # 6. Create Call Log in Salesforce (with follow-up date if found)
        task_id = create_call_log(contact, summary, duration, direction, follow_up_date)

        # The logged call satisfies any overdue follow-up reminder on the person.
        # Only now — after the call Task exists — so a failed transcription/summary
        # never silently closes a reminder without leaving a call record.
        if contact.get("Id"):
            complete_due_followup_tasks(contact["Id"])

        # 7. Create transcript note and link to Task
        create_transcript_note(task_id, transcript)

        # 8. Create separate tasks for non-follow-up action items
        for action in actions:
            if not action.get("is_follow_up_call"):
                try:
                    create_action_task(contact, action["description"], action.get("due_date"))
                except Exception as e:
                    logger.warning("Failed to create action task: %s", e)

        logger.info("Pipeline complete: %s (%s) -> Task %s", contact["Name"], phone_number, task_id)
        # Account-only associations have no person Id; the menu links to the Account.
        record_id = contact.get("Id") or contact.get("AccountId") or ""
        _complete_job(job_id, contact["Name"], record_id, resolved_type, task_id)
        _notify_success(contact["Name"])

    except Exception as e:
        logger.error("Pipeline error: %s", e, exc_info=True)
        _fail_job(job_id)
        _notify_error(str(e))
    finally:
        # 9. Clean up temp file — also on failure (the app keeps the original).
        try:
            os.remove(audio_path)
        except OSError:
            pass


def _osa_str(value: str) -> str:
    """Quote a value as an AppleScript string literal."""
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def _notify(message: str, sound: str | None = None):
    # No shell: Salesforce names and exception text routinely contain quotes,
    # which broke (or could inject into) the old os.system() command line.
    script = f"display notification {_osa_str(message[:200])} with title \"Call Logger\""
    if sound:
        script += f" sound name {_osa_str(sound)}"
    try:
        subprocess.run(["/usr/bin/osascript", "-e", script], check=False, timeout=10)
    except Exception:
        pass


def _notify_success(contact_name: str):
    _notify(f"Call log aangemaakt voor {contact_name}")


def _notify_error(message: str):
    _notify(f"Fout: {message}", sound="Basso")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8765)
