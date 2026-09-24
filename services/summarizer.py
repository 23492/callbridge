import datetime
import json
import time
import requests
import logging
from config import GEMINI_API_KEY, GEMINI_MODEL

logger = logging.getLogger(__name__)

GEMINI_TIMEOUT = (10, 180)  # (connect, read) seconds — thinking mode can be slow
MAX_RETRIES = 5
RETRY_STATUS_CODES = (500, 502, 503, 504)
MAX_RETRY_AFTER = 120  # seconds; cap on a server-supplied Retry-After

SUMMARY_PROMPT = """<role>

Je bent een Salesforce-notitie samenvattingsspecialist bij Welisa. Je bent analytisch, beknopt en actiegericht. Je hebt een uitzonderlijk oog voor commerciële details en vertaalt ruwe gesprekstranscripten naar gestructureerde zakelijke inzichten.

</role>



<instructions>

1. **Plan**:

   - Analyseer het transcript op sprekers (Naam/Rol) en taal.

   - Identificeer de kernonderdelen: Doel, Bevindingen, Oplossingen, Budget/Tijdlijn, Acties.

   - Scan expliciet op de 'Deep Analysis' triggers (zie Context Handling).



2. **Execute**:

   - Vertaal de inhoud naar professioneel Nederlands.

   - Wijs specifieke standpunten toe aan de juiste spreker via sub-bullets.

   - Integreer de 'Deep Analysis' punten contextueel in de secties 'Belangrijkste Bevindingen' of 'Overige Opmerkingen'.



3. **Validate**:

   - Controleer of alle data feitelijk is (geen hallucinaties of meningen).

   - Verifieer of deadlines het formaat DD-MM-YYYY hebben.

   - Check of lege secties de tekst "Niet besproken" bevatten.



4. **Format**:

   - Genereer de output strikt volgens het <output_format> markdown sjabloon.

</instructions>



<context_handling>

**Deep Analysis Scan:**

Zoek tijdens stap 1 & 2 actief naar:

1. Twijfels, risico's of bezwaren.

2. Genoemde concurrenten.

3. Expliciete/impliciete beslissingscriteria.

4. Interne beïnvloeders/stakeholders.

5. Eerdere ervaringen (positief/negatief).

6. De zakelijke 'trigger' voor het gesprek.

7. Technische/operationele beperkingen.

8. Lange-termijn doelen.

</context_handling>



<constraints>

- **Language**: Input kan elke taal zijn. Output is ALTIJD perfect Nederlands.

- **Verbosity**: Beknopt en 'to the point'. Gebruik actieve zinsbouw.

- **Tone**: Professioneel, objectief en zakelijk.

- **Speaker Attribution**: Bij meerdere sprekers, gebruik sub-bullets met naam/rol (bijv: "- Mieke (CFO): Maakt zich zorgen over...").

- **Handling Blanks**: Als informatie voor een sectie ontbreekt, noteer exact: "Niet besproken".

- **Formatting**: Deadlines altijd als DD-MM-YYYY (inclusief jaar). Geen introductie of afsluitende tekst buiten het sjabloon.

</constraints>



<output_format>

ACTIEPUNTEN

- [Actiepunt 1 voor ons, incl. deadline, bv: Voorstel sturen voor EOD DD-MM-YYYY]

- [Actiepunt 2 voor de klant, incl. deadline, bv: Klant stuurt huidige contract door voor DD-MM-YYYY]



---



SAMENVATTING GESPREK



* DOEL VAN HET GESPREK

    - [Wat was de aanleiding of het hoofddoel van dit contactmoment?]



* BELANGRIJKSTE BEVINDINGEN & PIJNPUNTEN

    - [Hoofdpijnpunt of bevinding A]

        - [Detail/perspectief Spreker 1]

        - [Detail/perspectief Spreker 2]

    - [Hoofdpijnpunt of bevinding B]



* BESPROKEN OPLOSSINGEN

    - [Oplossing X: Korte toelichting value case]

    - [Oplossing Y: Korte toelichting value case]



* BUDGET & TIMELINE

    - [Besproken budget, beslissingscriteria of planning]



* VOLGENDE STAPPEN

    - [Concreet afgesproken vervolgstap]



* OVERIGE OPMERKINGEN

    - [Relevante details uit de Deep Analysis Scan: concurrenten, stakeholders, eerdere ervaringen, etc.]

</output_format>



<self_critique>

Voordat je antwoordt, controleer:

1. Zijn alle secties ingevuld of gemarkeerd als "Niet besproken"?

2. Zijn de 'Deep Analysis' punten (indien aanwezig) logisch verwerkt in de tekst?

3. Is het onderscheid tussen sprekers duidelijk bij conflicterende of specifieke punten?

4. Is de output volledig in het Nederlands?

</self_critique>"""


def generate_summary(transcript: str) -> str:
    """
    Generate a call summary using Google Gemini.

    Args:
        transcript: Full transcript text with speaker labels.

    Returns:
        Summary text formatted for Salesforce Task Description.
    """
    url = (
        f"https://generativelanguage.googleapis.com/v1beta/models/"
        f"{GEMINI_MODEL}:generateContent"
    )

    payload = {
        "contents": [{
            "parts": [{
                "text": f"{SUMMARY_PROMPT}\n\nDe datum van vandaag is: {datetime.date.today().isoformat()}\n\n<transcript>\n{transcript}\n</transcript>"
            }]
        }],
        "generationConfig": {
            "thinkingConfig": {
                "thinkingLevel": "high"
            }
        }
    }

    data = _post_gemini(url, payload, "summary")
    text = _extract_text(data)

    logger.info("Summary generated (%d chars)", len(text))
    return text


ACTION_EXTRACT_PROMPT = """<instructions>
Analyseer de volgende samenvatting van een telefoongesprek.
Extraheer ALLEEN actiepunten die een echte handeling vereisen richting de klant of een externe partij.

WEL een actiepunt:
- Iets sturen naar de klant (voorstel, link, document, offerte)
- Een afspraak/meeting inplannen
- Een follow-up gesprek voeren
- Iets opleveren aan de klant

GEEN actiepunt (negeer deze volledig):
- Interne administratie (CRM bijwerken, leadstatus wijzigen, notities maken)
- Interne processen (pipeline updaten, collega informeren)
- Dingen die de klant zelf moet doen
- Vage of impliciete acties zonder concrete deliverable

Voor elk actiepunt:
- "description": Korte, concrete beschrijving van wat er gedaan moet worden
- "due_date": Deadline als YYYY-MM-DD. Ontbreekt het jaar, kies dan de eerstvolgende datum op of na vandaag (bijv. "15-01" genoemd in december = januari volgend jaar). null als geen deadline.
- "is_follow_up_call": true als het een follow-up call/gesprek betreft, anders false

Geef ALLEEN valide JSON terug, geen andere tekst. Voorbeeld:
[
  {"description": "Offerte sturen voor product X", "due_date": "2026-03-27", "is_follow_up_call": false},
  {"description": "Follow-up call Q3", "due_date": "2026-09-01", "is_follow_up_call": true}
]

Bij twijfel: NIET opnemen. Liever te weinig dan te veel taken. Lege array als er niets concreets is: []
</instructions>"""


def extract_action_items(summary: str) -> list[dict]:
    """
    Extract structured action items from a summary using Gemini.
    Returns a list of validated action item dicts:
    {description: str, due_date: "YYYY-MM-DD" | None, is_follow_up_call: bool}
    """
    url = (
        f"https://generativelanguage.googleapis.com/v1beta/models/"
        f"{GEMINI_MODEL}:generateContent"
    )

    today = datetime.date.today().isoformat()
    payload = {
        "contents": [{
            "parts": [{
                "text": f"{ACTION_EXTRACT_PROMPT}\n\nDe datum van vandaag is: {today}\n\n<samenvatting>\n{summary}\n</samenvatting>"
            }]
        }],
        "generationConfig": {
            "responseMimeType": "application/json",
        }
    }

    data = _post_gemini(url, payload, "action extraction")
    text = _extract_text(data)

    parsed = json.loads(text)
    # Tolerate a wrapper object such as {"actions": [...]}
    if isinstance(parsed, dict):
        parsed = next((v for v in parsed.values() if isinstance(v, list)), None)
    if not isinstance(parsed, list):
        logger.warning("Action extraction returned no list, ignoring: %.200s", text)
        return []

    actions = []
    for item in parsed:
        if not isinstance(item, dict):
            continue
        description = item.get("description")
        if not isinstance(description, str) or not description.strip():
            continue
        actions.append({
            "description": description.strip(),
            "due_date": _normalize_due_date(item.get("due_date")),
            "is_follow_up_call": item.get("is_follow_up_call") is True,
        })

    logger.info("Extracted %d action items", len(actions))
    return actions


def _normalize_due_date(value) -> str | None:
    """
    Validate a YYYY-MM-DD due date. Invalid → None.
    Past dates: more than 30 days ago is treated as a missed year rollover
    (e.g. "15-01" mentioned in December) and moved to the first matching
    date on or after today; up to 30 days ago → None.
    """
    if not isinstance(value, str):
        return None
    try:
        due = datetime.date.fromisoformat(value.strip())
    except ValueError:
        logger.warning("Ignoring invalid due_date: %r", value)
        return None

    today = datetime.date.today()
    if due >= today:
        return due.isoformat()

    if (today - due).days <= 30:
        logger.warning("Ignoring due_date in the recent past: %s", due)
        return None

    try:
        bumped = due.replace(year=today.year)
        if bumped < today:
            bumped = due.replace(year=today.year + 1)
    except ValueError:  # 29-02 in a non-leap year
        logger.warning("Ignoring due_date that cannot roll over: %s", due)
        return None
    logger.info("Rolled past due_date %s forward to %s", due, bumped)
    return bumped.isoformat()


def _post_gemini(url: str, payload: dict, label: str) -> dict:
    """
    POST to Gemini with retries on transient failures (5xx, connection
    errors, timeouts, per-minute 429). Stops immediately on a daily quota
    429. Returns the parsed JSON response.
    """
    for attempt in range(MAX_RETRIES):
        last_attempt = attempt == MAX_RETRIES - 1
        wait = 2 ** attempt * 5  # 5s, 10s, 20s, 40s

        try:
            response = requests.post(
                url,
                json=payload,
                headers={"x-goog-api-key": GEMINI_API_KEY},
                timeout=GEMINI_TIMEOUT,
            )
        except (requests.ConnectionError, requests.Timeout) as e:
            if last_attempt:
                raise
            logger.warning("Gemini %s request failed (%s), retrying in %ds (attempt %d/%d)...", label, e, wait, attempt + 1, MAX_RETRIES)
            time.sleep(wait)
            continue

        if response.status_code == 429:
            body = response.text or ""
            lowered = body.lower()
            if "resource_exhausted" in lowered and ("per day" in lowered or "perday" in lowered):
                logger.error("Gemini daily quota exhausted during %s: %.300s", label, body)
                raise RuntimeError("Gemini dagelijkse quota is op — probeer het morgen opnieuw.")
            retry_after = response.headers.get("Retry-After", "")
            if retry_after.strip().isdigit():
                wait = min(int(retry_after.strip()), MAX_RETRY_AFTER)

        if (response.status_code == 429 or response.status_code in RETRY_STATUS_CODES) and not last_attempt:
            logger.warning("Gemini returned %s on %s, retrying in %ds (attempt %d/%d)...", response.status_code, label, wait, attempt + 1, MAX_RETRIES)
            time.sleep(wait)
            continue

        # On the final attempt a retryable status falls through to here and
        # raise_for_status() raises, so the loop never exits without a result.
        response.raise_for_status()
        return response.json()


def _extract_text(data: dict) -> str:
    """
    Join the non-thought text parts of the first candidate.
    Raises RuntimeError if Gemini returned no usable text (e.g. blocked).
    """
    candidates = data.get("candidates") or []
    if not candidates:
        block_reason = (data.get("promptFeedback") or {}).get("blockReason", "unknown")
        raise RuntimeError(f"Gemini gaf geen antwoord (geen candidates, blockReason: {block_reason})")

    candidate = candidates[0]
    parts = (candidate.get("content") or {}).get("parts") or []
    # With thinking enabled, response may contain thought parts; skip them.
    text = "\n".join(
        p.get("text", "") for p in parts
        if isinstance(p, dict) and not p.get("thought") and p.get("text")
    )
    if not text.strip():
        finish_reason = candidate.get("finishReason", "unknown")
        raise RuntimeError(f"Gemini gaf een leeg antwoord (finishReason: {finish_reason})")
    return text
