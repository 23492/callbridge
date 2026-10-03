import hashlib
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
    create_transcript_content_note,
    link_note_to_task,
    create_action_task,
    create_nno_log,
    create_nno_task,
    create_callback_task,
    complete_due_followup_tasks,
    fetch_my_open_future_tasks,
    ALLOWED_RECORD_TYPES,
    is_valid_sf_id,
    _get_user_id,
    dry_run_enabled,
)
from services import ledger

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
    # Ledger pruning touches the disk only, but still never delays binding :8765.
    threading.Thread(target=ledger.prune, name="ledger-prune", daemon=True).start()
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


@app.get("/sessions/{client_ref}")
def session_status(client_ref: str):
    """Where a session stands, by the app's own session id (crash resume).

    stage is unknown, processing, done or failed. An entry left in processing
    by a backend that restarted mid-run reports failed with error "interrupted",
    so the app resends and the ledger resumes from the last write.
    """
    if not ledger.is_valid_client_ref(client_ref):
        raise HTTPException(status_code=400, detail="Invalid client_ref")

    entry = ledger.lookup(client_ref)
    if entry is None:
        return {"stage": "unknown", "step": None, "task_id": None, "error": None}

    if entry.get("kind") == "nno":
        task_id = entry.get("nno_task_id")
    else:
        task_id = entry.get("call_task_id")
    step = entry.get("step")
    status = entry.get("status")

    if ledger.in_flight(client_ref):
        return {"stage": "processing", "step": step, "task_id": task_id, "error": None}
    if status == "done":
        return {"stage": "done", "step": step, "task_id": task_id, "error": None}
    if status == "failed":
        return {"stage": "failed", "step": step, "task_id": task_id, "error": entry.get("error")}
    return {"stage": "failed", "step": step, "task_id": task_id, "error": "interrupted"}


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
    client_ref: str | None = Form(None),
):
    """
    Log an NNO (Niet opgenomen). Creates a completed NNO task and a
    follow-up 'Call back' task for the next day.

    client_ref is the app's session id (D-10). With it, each write is
    checkpointed in the ledger: a resend of a finished session returns the
    stored ids, and a resend after a failure creates only what is missing.

    Sync (not async) on purpose: the Salesforce calls block, and an async handler
    would stall the event loop — and with it /health and /status — for seconds.
    """
    if client_ref is not None and not ledger.is_valid_client_ref(client_ref):
        raise HTTPException(status_code=400, detail="Invalid client_ref")

    ref = client_ref
    if ref is not None:
        entry = ledger.lookup(ref)
        if entry and entry.get("kind", "nno") != "nno":
            logger.warning("Rejected /log-nno for client_ref %s: ledger entry is kind %s", ref, entry.get("kind"))
            raise HTTPException(status_code=409, detail="client_ref hoort bij een ander soort sessie")
        if entry and entry.get("status") == "done":
            logger.info("Deduplicated /log-nno for client_ref %s", ref)
            return {
                "status": "ok",
                "nno_task_id": entry.get("nno_task_id"),
                "follow_up_task_id": entry.get("follow_up_task_id"),
                "contact_name": entry.get("contact_name"),
            }
        if not ledger.claim(ref):
            logger.info("client_ref %s: NNO is already being processed", ref)
            raise HTTPException(status_code=409, detail="NNO wordt al verwerkt")

    try:
        try:
            contact = resolve_provided_record(salesforce_id, salesforce_type)
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))

        logger.info("Logging NNO for %s (%s/%s)", contact["Name"], salesforce_type, salesforce_id)
        if ref is None:
            nno_id, follow_up_id = create_nno_log(contact)
        else:
            nno_id, follow_up_id = _log_nno_checkpointed(ref, contact, salesforce_id)
    finally:
        ledger.release(ref)

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


def _log_nno_checkpointed(ref: str, contact: dict, salesforce_id: str) -> tuple[str, str]:
    """The NNO writes for one session, each checkpointed on the line after it."""
    try:
        entry = ledger.checkpoint(ref, kind="nno", status="processing", step="saving_to_salesforce",
                                  target_id=salesforce_id, contact_name=contact["Name"], error=None)

        nno_id = entry.get("nno_task_id")
        if nno_id:
            logger.info("NNO Task %s already exists for client_ref %s; not creating it again", nno_id, ref)
        else:
            nno_id = create_nno_task(contact)
            entry = ledger.checkpoint(ref, nno_task_id=nno_id)

        # This call satisfies any overdue follow-up reminder on the person.
        if not entry.get("followups_done"):
            if contact.get("Id"):
                complete_due_followup_tasks(contact["Id"])
            entry = ledger.checkpoint(ref, followups_done=True)

        follow_up_id = entry.get("follow_up_task_id")
        if not follow_up_id:
            follow_up_id = create_callback_task(contact)
            entry = ledger.checkpoint(ref, follow_up_task_id=follow_up_id)

        ledger.checkpoint(ref, status="done", step="done")
        return nno_id, follow_up_id
    except Exception as e:
        logger.error("NNO logging failed for client_ref %s: %s", ref, e, exc_info=True)
        try:
            ledger.checkpoint(ref, status="failed", error=str(e))
        except Exception as ledger_error:
            logger.error("Could not record failure for client_ref %s: %s", ref, ledger_error)
        raise HTTPException(status_code=502, detail=str(e))


@app.post("/process")
async def process_recording(
    background_tasks: BackgroundTasks,
    audio: UploadFile = File(...),
    phone_number: str = Form(...),
    direction: str = Form("Outbound"),
    salesforce_id: str | None = Form(None),
    salesforce_type: str | None = Form(None),
    client_ref: str | None = Form(None),
):
    """
    Process an audio recording. Called by CallBridge after user confirms save.
    Phone number is always provided by CallBridge.

    client_ref is the app's session id. A session that already finished returns
    {"status": "duplicate", "task_id": ...} without writing anything (D-11).
    """
    if salesforce_id or salesforce_type:
        if salesforce_type not in ALLOWED_RECORD_TYPES or not is_valid_sf_id(salesforce_id):
            raise HTTPException(status_code=400, detail="Invalid salesforce_id/salesforce_type")
    if client_ref is not None and not ledger.is_valid_client_ref(client_ref):
        raise HTTPException(status_code=400, detail="Invalid client_ref")

    content = await audio.read()
    return _start_pipeline(
        background_tasks, audio.filename, content, client_ref,
        phone_number=phone_number,
        direction=direction,
        salesforce_id=salesforce_id,
        salesforce_type=salesforce_type,
    )


@app.post("/process-manual")
async def process_manual(
    background_tasks: BackgroundTasks,
    audio: UploadFile = File(...),
    phone_number: str = Form(...),
    direction: str = Form("Outbound"),
    client_ref: str | None = Form(None),
):
    """Dashboard endpoint for manual uploads."""
    if client_ref is not None and not ledger.is_valid_client_ref(client_ref):
        raise HTTPException(status_code=400, detail="Invalid client_ref")

    content = await audio.read()
    return _start_pipeline(
        background_tasks, audio.filename, content, client_ref,
        phone_number=phone_number,
        direction=direction,
    )


def _start_pipeline(background_tasks, filename, content: bytes, client_ref: str | None, **pipeline_kwargs):
    """Ledger check, temp file and background scheduling shared by /process and /process-manual."""
    phone_number = pipeline_kwargs["phone_number"]
    audio_sha256 = hashlib.sha256(content).hexdigest()
    # Dashboard and older clients send no session id; the audio hash still guards them.
    ref = client_ref or str(uuid.uuid4())

    entry = ledger.lookup(ref)
    if entry and entry.get("kind", "call") != "call":
        logger.warning("Rejected /process for client_ref %s: ledger entry is kind %s", ref, entry.get("kind"))
        raise HTTPException(status_code=409, detail="client_ref hoort bij een ander soort sessie")
    if entry and entry.get("status") == "done":
        logger.info("Deduplicated /process for client_ref %s -> Task %s", ref, entry.get("call_task_id"))
        return {"status": "duplicate", "task_id": entry.get("call_task_id")}
    if not ledger.claim(ref):
        logger.info("client_ref %s is already being processed; not starting a second pipeline", ref)
        return {"status": "processing", "file": filename, "phone": phone_number}

    try:
        suffix = os.path.splitext(filename or ".wav")[1]
        fd, temp_path = tempfile.mkstemp(suffix=suffix, prefix="calllog_")
        with os.fdopen(fd, "wb") as f:
            f.write(content)
    except Exception:
        ledger.release(ref)
        raise

    logger.info("Received: %s, phone: %s, sf: %s/%s, client_ref: %s", filename, phone_number,
                pipeline_kwargs.get("salesforce_type"), pipeline_kwargs.get("salesforce_id"), ref)

    job_id = str(uuid.uuid4())
    _start_job(job_id)
    background_tasks.add_task(
        process_pipeline,
        job_id,
        temp_path,
        client_ref=ref,
        audio_sha256=audio_sha256,
        **pipeline_kwargs,
    )

    return {"status": "processing", "file": filename, "phone": phone_number}


def process_pipeline(
    job_id: str,
    audio_path: str,
    phone_number: str,
    direction: str = "Outbound",
    salesforce_id: str | None = None,
    salesforce_type: str | None = None,
    client_ref: str | None = None,
    audio_sha256: str | None = None,
):
    """
    Full processing pipeline. Runs as a sync background task.
    Phone number is always provided (by CallBridge or dashboard).

    With client_ref set, every step and every Salesforce write is checkpointed in
    the ledger, so a resend of the same session skips what already happened.
    Without it (direct callers) the pipeline behaves as before.
    """
    ref = client_ref
    if ref:
        logger.info("Pipeline start for client_ref %s", ref)
        ledger.checkpoint(ref, kind="call", status="processing", step="starting", audio_sha256=audio_sha256)
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
                ledger.checkpoint(ref, status="failed", error=f"no contact for {phone_number}")
                return
            resolved_type = contact.get("attributes", {}).get("type", "Contact")

        # The same recording logged to the same record from another session is a
        # duplicate (D-09). Only an entry that already wrote its call Task, or is
        # running now, blocks: a stale entry that died before any write must not
        # turn this recording into one that can never be logged.
        target_id = contact.get("Id") or contact.get("AccountId")
        if ref and audio_sha256 and is_valid_sf_id(target_id):
            ledger.checkpoint(ref, target_id=target_id)
            other = ledger.lookup_by_hash(audio_sha256, target_id)
            other_entry = ledger.lookup(other) if other and other != ref else None
            if other_entry and (other_entry.get("call_task_id") or ledger.in_flight(other)):
                other_task_id = other_entry.get("call_task_id")
                logger.info("Deduplicated recording %s for %s: same audio as client_ref %s", ref, target_id, other)
                ledger.checkpoint(ref, status="done", step="done", duplicate_of=other, call_task_id=other_task_id)
                if other_task_id:
                    _complete_job(job_id, contact["Name"], target_id, resolved_type, other_task_id)
                else:
                    _fail_job(job_id)
                return
            ledger.link_hash(audio_sha256, target_id, ref)

        _update_job(job_id, contact_name=contact["Name"], step="transcribing")
        ledger.checkpoint(ref, step="transcribing")

        # 2. Transcribe audio via AssemblyAI (a resume reuses the cached result)
        result = ledger.load_transcript(ref)
        if result is not None:
            logger.info("Using cached transcript for client_ref %s", ref)
        else:
            logger.info("Transcribing audio for %s...", contact["Name"])
            result = transcribe_audio(audio_path)
            ledger.save_transcript(ref, result)
        transcript = result["full_text"]

        if not transcript.strip():
            logger.warning("Empty transcript for %s. Skipping.", contact["Name"])
            _notify_error(f"Leeg transcript voor {contact['Name']}")
            _fail_job(job_id)
            ledger.checkpoint(ref, status="failed", error="empty transcript")
            return

        _update_job(job_id, step="summarizing")
        ledger.checkpoint(ref, step="summarizing")

        entry = ledger.lookup(ref) or {}
        if "summary" in entry:
            # A resume reuses summary and actions, so an existing call Task never
            # gets a different Description and Gemini is not paid twice.
            logger.info("Using cached summary and actions for client_ref %s", ref)
            summary = entry["summary"]
            summary_ok = entry.get("summary_ok", True)
            duration = entry.get("duration")
            actions = entry.get("actions") or []
            follow_up_date = entry.get("follow_up_date")
            _update_job(job_id, step="extracting_actions")
            ledger.checkpoint(ref, step="extracting_actions")
        else:
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
            ledger.checkpoint(ref, step="extracting_actions")

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

            ledger.checkpoint(ref, summary=summary, summary_ok=summary_ok, duration=duration,
                              actions=actions, follow_up_date=follow_up_date)

        _update_job(job_id, step="saving_to_salesforce")
        ledger.checkpoint(ref, step="saving_to_salesforce")

        # 6. Create Call Log in Salesforce (with follow-up date if found)
        entry = ledger.lookup(ref) or {}
        if entry.get("call_task_id"):
            task_id = entry["call_task_id"]
            logger.info("Call Task %s already exists for client_ref %s; not creating it again", task_id, ref)
        else:
            task_id = create_call_log(contact, summary, duration, direction, follow_up_date)
            entry = ledger.checkpoint(ref, call_task_id=task_id)

        # The logged call satisfies any overdue follow-up reminder on the person.
        # Only now — after the call Task exists — so a failed transcription/summary
        # never silently closes a reminder without leaving a call record.
        if contact.get("Id") and not entry.get("followups_done"):
            complete_due_followup_tasks(contact["Id"])
            entry = ledger.checkpoint(ref, followups_done=True)

        # 7. Create transcript note and link to Task (two checkpointed writes)
        note_id = entry.get("note_id")
        if not note_id:
            note_id = create_transcript_content_note(transcript)
            entry = ledger.checkpoint(ref, note_id=note_id)
        if not entry.get("note_linked"):
            link_note_to_task(note_id, task_id)
            entry = ledger.checkpoint(ref, note_linked=True)
            logger.info("Created ContentNote %s linked to Task %s", note_id, task_id)

        # 8. Create separate tasks for non-follow-up action items. A failed one
        # stays non-fatal and is not recorded, so a resume retries only it.
        action_task_ids = dict(entry.get("action_task_ids") or {})
        for index, action in enumerate(actions):
            if action.get("is_follow_up_call"):
                continue
            key = str(index)
            if key in action_task_ids:
                continue
            try:
                action_task_ids[key] = create_action_task(contact, action["description"], action.get("due_date"))
                ledger.checkpoint(ref, action_task_ids=action_task_ids)
            except Exception as e:
                logger.warning("Failed to create action task: %s", e)

        logger.info("Pipeline complete: %s (%s) -> Task %s", contact["Name"], phone_number, task_id)
        ledger.checkpoint(ref, status="done", step="done")
        # Account-only associations have no person Id; the menu links to the Account.
        record_id = contact.get("Id") or contact.get("AccountId") or ""
        _complete_job(job_id, contact["Name"], record_id, resolved_type, task_id)
        _notify_success(contact["Name"])

    except Exception as e:
        logger.error("Pipeline error: %s", e, exc_info=True)
        _fail_job(job_id)
        try:
            ledger.checkpoint(ref, status="failed", error=str(e))
        except Exception as ledger_error:
            logger.error("Could not record failure for client_ref %s: %s", ref, ledger_error)
        _notify_error(str(e))
    finally:
        ledger.release(ref)
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
