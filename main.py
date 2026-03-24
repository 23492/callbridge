import logging
import os
import tempfile

from fastapi import FastAPI, UploadFile, File, BackgroundTasks, Form, Query
from fastapi.staticfiles import StaticFiles

from services.transcription import transcribe_audio
from services.summarizer import generate_summary, extract_action_items
from services.salesforce import (
    find_contact_by_phone,
    search_contacts,
    create_call_log,
    create_transcript_note,
    create_action_task,
)

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[
        logging.FileHandler("call_logger.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger(__name__)

app = FastAPI(title="Call Logger", version="2.0.0")

# Serve dashboard static files
app.mount("/dashboard", StaticFiles(directory="dashboard", html=True), name="dashboard")


@app.get("/health")
def health():
    return {"status": "ok"}


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
    suffix = os.path.splitext(audio.filename or ".wav")[1]
    fd, temp_path = tempfile.mkstemp(suffix=suffix, prefix="calllog_")
    with os.fdopen(fd, "wb") as f:
        content = await audio.read()
        f.write(content)

    logger.info("Received: %s, phone: %s, sf: %s/%s", audio.filename, phone_number, salesforce_type, salesforce_id)

    background_tasks.add_task(
        process_pipeline,
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

    background_tasks.add_task(
        process_pipeline, temp_path, phone_number=phone_number, direction=direction
    )

    return {"status": "processing", "file": audio.filename, "phone": phone_number}


def process_pipeline(
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
        if salesforce_id and salesforce_type:
            from simple_salesforce import Salesforce
            from services.salesforce import _get_sf
            sf = _get_sf()
            record = sf.query(
                f"SELECT Id, Name, AccountId FROM {salesforce_type} WHERE Id = '{salesforce_id}'"
            )["records"][0]
            contact = {
                "Id": record["Id"],
                "Name": record["Name"],
                "AccountId": record.get("AccountId"),
            }
            logger.info("Using provided Salesforce record: %s (%s)", contact["Name"], salesforce_type)
        else:
            contact = find_contact_by_phone(phone_number)
            if contact is None:
                logger.error("No Salesforce contact found for %s. Skipping.", phone_number)
                _notify_error(f"Geen contact gevonden voor {phone_number}")
                return

        # 2. Transcribe audio via AssemblyAI
        logger.info("Transcribing audio for %s...", contact["Name"])
        result = transcribe_audio(audio_path)
        transcript = result["full_text"]

        if not transcript.strip():
            logger.warning("Empty transcript for %s. Skipping.", contact["Name"])
            _notify_error(f"Leeg transcript voor {contact['Name']}")
            return

        # 3. Generate summary via Gemini
        logger.info("Generating summary...")
        summary = generate_summary(transcript)

        # 4. Get call duration from AssemblyAI response
        duration = result["audio_duration"]

        # 5. Extract action items from summary
        follow_up_date = None
        actions = []
        try:
            actions = extract_action_items(summary)
            for action in actions:
                if action.get("is_follow_up_call") and action.get("due_date"):
                    follow_up_date = action["due_date"]
            logger.info("Extracted %d action items (follow-up: %s)", len(actions), follow_up_date)
        except Exception as e:
            logger.warning("Action item extraction failed (non-fatal): %s", e)

        # 6. Create Call Log in Salesforce (with follow-up date if found)
        task_id = create_call_log(contact, summary, duration, direction, follow_up_date)

        # 7. Create transcript note and link to Task
        create_transcript_note(task_id, transcript)

        # 8. Create separate tasks for non-follow-up action items
        for action in actions:
            if not action.get("is_follow_up_call"):
                try:
                    create_action_task(contact, action["description"], action.get("due_date"))
                except Exception as e:
                    logger.warning("Failed to create action task: %s", e)

        # 9. Clean up temp file
        os.remove(audio_path)

        logger.info("Pipeline complete: %s (%s) -> Task %s", contact["Name"], phone_number, task_id)
        _notify_success(contact["Name"])

    except Exception as e:
        logger.error("Pipeline error: %s", e, exc_info=True)
        _notify_error(str(e))


def _notify_success(contact_name: str):
    try:
        os.system(
            f'osascript -e \'display notification "Call log aangemaakt voor {contact_name}" '
            f'with title "Call Logger"\''
        )
    except Exception:
        pass


def _notify_error(message: str):
    try:
        os.system(
            f'osascript -e \'display notification "Fout: {message}" '
            f'with title "Call Logger" sound name "Basso"\''
        )
    except Exception:
        pass
