import requests
import logging
from config import GEMINI_API_KEY, GEMINI_MODEL

logger = logging.getLogger(__name__)

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

   - Verifieer of deadlines het formaat DD-MM hebben.

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

- **Formatting**: Deadlines altijd als DD-MM. Geen introductie of afsluitende tekst buiten het sjabloon.

</constraints>



<output_format>

ACTIEPUNTEN

- [Actiepunt 1 voor ons, incl. deadline, bv: Voorstel sturen voor EOD DD-MM]

- [Actiepunt 2 voor de klant, incl. deadline, bv: Klant stuurt huidige contract door voor DD-MM]



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
                "text": f"{SUMMARY_PROMPT}\n\n<transcript>\n{transcript}\n</transcript>"
            }]
        }],
        "generationConfig": {
            "thinkingConfig": {
                "thinkingLevel": "high"
            }
        }
    }

    # Try up to 2 times (1 retry on server error)
    for attempt in range(2):
        response = requests.post(
            url,
            json=payload,
            headers={"x-goog-api-key": GEMINI_API_KEY},
        )

        if response.status_code in (500, 503) and attempt == 0:
            logger.warning("Gemini returned %s, retrying...", response.status_code)
            continue

        response.raise_for_status()
        data = response.json()

        # With thinking enabled, response may contain thought parts.
        # Extract only the non-thought (answer) parts.
        parts = data["candidates"][0]["content"]["parts"]
        answer_parts = [p["text"] for p in parts if not p.get("thought")]
        text = "\n".join(answer_parts)

        logger.info("Summary generated (%d chars)", len(text))
        return text

    raise Exception("Gemini API failed after retry")


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
- "due_date": Deadline als YYYY-MM-DD (gebruik het huidige jaar tenzij anders vermeld). null als geen deadline.
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
    Returns a list of action item dicts.
    """
    import json

    url = (
        f"https://generativelanguage.googleapis.com/v1beta/models/"
        f"{GEMINI_MODEL}:generateContent"
    )

    today = __import__("datetime").date.today().isoformat()
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

    response = requests.post(
        url,
        json=payload,
        headers={"x-goog-api-key": GEMINI_API_KEY},
    )
    response.raise_for_status()
    data = response.json()

    parts = data["candidates"][0]["content"]["parts"]
    text = parts[0]["text"]

    actions = json.loads(text)
    logger.info("Extracted %d action items", len(actions))
    return actions
