import requests
import time
import logging
from config import ASSEMBLYAI_API_KEY

logger = logging.getLogger(__name__)

ASSEMBLY_URL = "https://api.assemblyai.com/v2"

UPLOAD_TIMEOUT = (10, 300)  # (connect, read) seconds — large audio uploads
REQUEST_TIMEOUT = (10, 30)
POLL_INTERVAL = 3
MIN_POLL_DEADLINE = 900  # seconds; extended to 3x audio length once known
MAX_POLL_FAILURES = 3  # consecutive transient failures before giving up


def transcribe_audio(file_path: str) -> dict:
    """
    Transcribe audio via AssemblyAI with speaker diarization and language detection.

    Returns dict with:
        - utterances: list of {speaker, timestamp, text}
        - full_text: plain text with speaker labels (for Gemini)
        - audio_duration: duration in seconds
        - language_code: detected language
    """
    headers = {"Authorization": ASSEMBLYAI_API_KEY}

    # Phase 1: Upload audio file
    logger.info("Uploading audio file: %s", file_path)
    with open(file_path, "rb") as f:
        upload_res = requests.post(
            f"{ASSEMBLY_URL}/upload",
            headers=headers,
            data=f,
            timeout=UPLOAD_TIMEOUT,
        )
    upload_res.raise_for_status()
    upload_url = upload_res.json()["upload_url"]

    # Phase 2: Start transcription with speaker labels + language detection
    logger.info("Starting transcription...")
    transcript_res = requests.post(
        f"{ASSEMBLY_URL}/transcript",
        headers={**headers, "Content-Type": "application/json"},
        json={
            "audio_url": upload_url,
            "speaker_labels": True,
            "language_detection": True,
            "language_detection_options": {
                "expected_languages": ["nl", "en"],
            },
        },
        timeout=REQUEST_TIMEOUT,
    )
    transcript_res.raise_for_status()
    transcript_id = transcript_res.json()["id"]

    # Phase 3: Poll until transcription completes (bounded by a deadline)
    start = time.monotonic()
    deadline_seconds = MIN_POLL_DEADLINE
    failures = 0
    while True:
        if time.monotonic() - start > deadline_seconds:
            raise RuntimeError(
                f"AssemblyAI transcription {transcript_id} timed out after "
                f"{int(deadline_seconds)}s"
            )

        try:
            poll_res = requests.get(
                f"{ASSEMBLY_URL}/transcript/{transcript_id}",
                headers=headers,
                timeout=REQUEST_TIMEOUT,
            )
        except (requests.ConnectionError, requests.Timeout) as e:
            failures += 1
            if failures >= MAX_POLL_FAILURES:
                raise
            logger.warning("AssemblyAI poll failed (%s), retrying (%d/%d)...", e, failures, MAX_POLL_FAILURES)
            time.sleep(POLL_INTERVAL * failures)
            continue

        if poll_res.status_code >= 500:
            failures += 1
            if failures >= MAX_POLL_FAILURES:
                poll_res.raise_for_status()
            logger.warning("AssemblyAI poll returned %s, retrying (%d/%d)...", poll_res.status_code, failures, MAX_POLL_FAILURES)
            time.sleep(POLL_INTERVAL * failures)
            continue

        poll_res.raise_for_status()
        failures = 0
        data = poll_res.json()

        if data["status"] == "completed":
            logger.info("Transcription completed (language: %s)", data.get("language_code"))
            return _format_transcript(data)
        if data["status"] == "error":
            raise RuntimeError(f"AssemblyAI error: {data.get('error', 'unknown')}")

        # Once AssemblyAI reports the audio length, allow up to 3x that.
        duration = data.get("audio_duration")
        if duration:
            deadline_seconds = max(MIN_POLL_DEADLINE, 3 * duration)

        time.sleep(POLL_INTERVAL)


def _format_transcript(data: dict) -> dict:
    """Format the AssemblyAI response into utterances and plain text."""
    utterances = []
    if data.get("utterances"):
        for u in data["utterances"]:
            start = _format_time_ms(u["start"])
            end = _format_time_ms(u["end"])
            utterances.append({
                "speaker": f"Speaker {u['speaker']}",
                "timestamp": f"{start} - {end}",
                "text": u["text"],
            })

    # Plain text with speaker labels (for Gemini summary)
    if utterances:
        full_text = "\n\n".join(
            f"[{u['timestamp']}] {u['speaker']}: {u['text']}"
            for u in utterances
        )
    else:
        full_text = data.get("text", "")

    return {
        "utterances": utterances,
        "full_text": full_text,
        "audio_duration": data.get("audio_duration", 0),
        "language_code": data.get("language_code", "unknown"),
    }


def _format_time_ms(ms: int) -> str:
    """Convert milliseconds to MM:SS format."""
    total_seconds = ms // 1000
    minutes = total_seconds // 60
    seconds = total_seconds % 60
    return f"{minutes}:{seconds:02d}"
