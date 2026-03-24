import requests
import time
import logging
from config import ASSEMBLYAI_API_KEY

logger = logging.getLogger(__name__)

ASSEMBLY_URL = "https://api.assemblyai.com/v2"


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
        },
    )
    transcript_res.raise_for_status()
    transcript_id = transcript_res.json()["id"]

    # Phase 3: Poll until transcription completes
    while True:
        poll_res = requests.get(
            f"{ASSEMBLY_URL}/transcript/{transcript_id}",
            headers=headers,
        )
        poll_res.raise_for_status()
        data = poll_res.json()

        if data["status"] == "completed":
            logger.info("Transcription completed (language: %s)", data.get("language_code"))
            return _format_transcript(data)
        if data["status"] == "error":
            raise Exception(f"AssemblyAI error: {data.get('error', 'unknown')}")

        time.sleep(3)


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
