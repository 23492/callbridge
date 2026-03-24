import base64
import re
import logging
from datetime import datetime, timedelta
from simple_salesforce import Salesforce
from config import SF_USERNAME, SF_PASSWORD, SF_SECURITY_TOKEN, SF_DOMAIN

logger = logging.getLogger(__name__)

# Lazy-initialized Salesforce connection
_sf = None


def _get_sf() -> Salesforce:
    """Get or create the Salesforce connection."""
    global _sf
    if _sf is None:
        _sf = Salesforce(
            username=SF_USERNAME,
            password=SF_PASSWORD,
            security_token=SF_SECURITY_TOKEN,
            domain=SF_DOMAIN,
        )
        logger.info("Connected to Salesforce (domain: %s)", SF_DOMAIN)
    return _sf


def _sanitize_phone(phone: str) -> str:
    """Strip a phone number down to digits and leading +."""
    return re.sub(r"[^\d+]", "", phone)


def find_contact_by_phone(phone_number: str) -> dict | None:
    """
    Find a Salesforce Contact or Account by phone number using SOSL.
    Searches Contact first, then Account as fallback.
    """
    sf = _get_sf()
    clean = _sanitize_phone(phone_number)

    if not clean:
        logger.warning("Empty phone number, cannot search")
        return None

    # Strip leading + for SOSL (causes bind variable error)
    search_term = clean.lstrip("+")

    # Search in priority order: Contact -> Account -> Lead
    searches = [
        ("Contact", f"FIND {{{search_term}}} IN Phone FIELDS RETURNING Contact(Id, Name, AccountId, Account.Name, Phone, MobilePhone LIMIT 1)"),
        ("Account", f"FIND {{{search_term}}} IN Phone FIELDS RETURNING Account(Id, Name, Phone LIMIT 1)"),
        ("Lead", f"FIND {{{search_term}}} IN Phone FIELDS RETURNING Lead(Id, Name, Company, Phone, MobilePhone LIMIT 1)"),
    ]

    for obj_type, query in searches:
        logger.info("SOSL search (%s): %s", obj_type, query)
        results = sf.search(query)

        if not results or not results.get("searchRecords"):
            continue

        record = results["searchRecords"][0]

        if obj_type == "Contact":
            logger.info("Found contact: %s (Account: %s)", record["Name"], record.get("Account", {}).get("Name"))
            return record
        elif obj_type == "Account":
            logger.info("Found account (no contact): %s", record["Name"])
            return {
                "Id": None,
                "Name": record["Name"],
                "AccountId": record["Id"],
                "attributes": record["attributes"],
            }
        elif obj_type == "Lead":
            logger.info("Found lead: %s (%s)", record["Name"], record.get("Company"))
            return {
                "Id": record["Id"],
                "Name": record["Name"],
                "AccountId": None,
                "attributes": record["attributes"],
            }

    logger.warning("No Salesforce contact, account or lead found for phone: %s", clean)
    return None


def _normalize_record(record: dict) -> dict:
    """Normalize a Salesforce record to a common format for the API."""
    obj_type = record["attributes"]["type"]
    base = {
        "id": record["Id"],
        "name": record.get("Name", ""),
        "type": obj_type,
        "phone": record.get("Phone") or record.get("MobilePhone"),
    }
    if obj_type == "Contact":
        base["account_name"] = (record.get("Account") or {}).get("Name")
        base["account_id"] = record.get("AccountId")
    elif obj_type == "Account":
        base["account_name"] = record.get("Name")
        base["account_id"] = record["Id"]
    elif obj_type == "Lead":
        base["account_name"] = record.get("Company")
        base["account_id"] = None
    return base


def search_contacts(query: str) -> list[dict]:
    """
    Search Salesforce Contacts, Accounts, and Leads by name.
    Returns normalized list of results.
    """
    sf = _get_sf()

    if not query or len(query) < 2:
        return []

    # Escape SOSL special characters
    safe_query = query.replace("\\", "\\\\").replace("'", "\\'")

    sosl = (
        f"FIND {{{safe_query}}} IN NAME FIELDS "
        f"RETURNING Contact(Id, Name, AccountId, Account.Name, Phone, MobilePhone LIMIT 5), "
        f"Account(Id, Name, Phone LIMIT 5), "
        f"Lead(Id, Name, Company, Phone, MobilePhone LIMIT 5)"
    )

    logger.info("SOSL name search: %s", sosl)
    results = sf.search(sosl)

    normalized = []
    for record in results.get("searchRecords", []):
        normalized.append(_normalize_record(record))

    logger.info("Name search returned %d results for '%s'", len(normalized), query)
    return normalized


def create_call_log(
    contact: dict,
    summary: str,
    duration_seconds: int,
    call_direction: str = "Outbound",
    follow_up_date: str | None = None,
) -> str:
    """
    Create a Task (Call Log) in Salesforce.
    If follow_up_date is set (YYYY-MM-DD), it triggers the Salesforce Flow
    to auto-create a Follow Up task.

    Returns the Task ID.
    """
    sf = _get_sf()

    task_data = {
        "Subject": "Call",
        "Type": "Call",
        "TaskSubtype": "Call",
        "Status": "Completed",
        "Priority": "Normal",
        "Log_Type__c": "Sales Call",
        "CallType": call_direction,
        "CallDurationInSeconds": duration_seconds,
        "ActivityDate": datetime.now().strftime("%Y-%m-%d"),
        "Description": summary,
    }

    # Set WhoId (Contact) if available
    contact_id = contact.get("Id")
    if contact_id:
        task_data["WhoId"] = contact_id

    if follow_up_date:
        task_data["Auto_Generate_Follow_Up_Task__c"] = follow_up_date

    # Only set WhatId (Account) if available
    account_id = contact.get("AccountId")
    if account_id:
        task_data["WhatId"] = account_id

    result = sf.Task.create(task_data)
    task_id = result["id"]
    logger.info("Created Task %s for contact %s (follow-up: %s)", task_id, contact["Name"], follow_up_date)
    return task_id


def create_transcript_note(task_id: str, transcript: str) -> str:
    """
    Create a ContentNote with the full transcript and link it to the Task.

    Returns the ContentNote ID.
    """
    sf = _get_sf()
    today = datetime.now().strftime("%d %B %Y")

    # ContentNote content must be base64-encoded HTML
    html_content = f"<p>{transcript.replace(chr(10), '</p><p>')}</p>"
    encoded = base64.b64encode(html_content.encode("utf-8")).decode("utf-8")

    note = sf.ContentNote.create({
        "Title": today,
        "Content": encoded,
    })
    note_id = note["id"]

    # ContentNote ID is also the ContentDocumentId for linking
    # Link the note to the Task
    sf.ContentDocumentLink.create({
        "ContentDocumentId": note_id,
        "LinkedEntityId": task_id,
        "ShareType": "V",
        "Visibility": "AllUsers",
    })

    logger.info("Created ContentNote %s linked to Task %s", note_id, task_id)
    return note_id


def set_follow_up_date(task_id: str, follow_up_date: str):
    """
    Set the Auto Generate Follow Up Task date on an existing Task.
    This triggers Salesforce automation to create a follow-up task.
    follow_up_date should be YYYY-MM-DD format.
    """
    sf = _get_sf()
    sf.Task.update(task_id, {
        "Auto_Generate_Follow_Up_Task__c": follow_up_date,
    })
    logger.info("Set follow-up date on Task %s for %s", task_id, follow_up_date)


def create_action_task(
    contact: dict,
    description: str,
    due_date: str | None = None,
) -> str:
    """
    Create a standalone action item Task in Salesforce.
    Returns the Task ID.
    """
    sf = _get_sf()

    task_data = {
        "Subject": description[:255],
        "Status": "Not Started",
        "Priority": "Normal",
        "WhoId": contact["Id"],
        "Description": description,
    }

    if due_date:
        task_data["ActivityDate"] = due_date

    account_id = contact.get("AccountId")
    if account_id:
        task_data["WhatId"] = account_id

    result = sf.Task.create(task_data)
    task_id = result["id"]
    logger.info("Created action Task %s: %s (due: %s)", task_id, description, due_date)
    return task_id


def create_nno_log(contact: dict) -> tuple[str, str]:
    """
    Create a completed NNO call task and a follow-up 'Call back' task for the next day.
    Returns (nno_task_id, follow_up_task_id).
    """
    sf = _get_sf()
    today = datetime.now().strftime("%Y-%m-%d")
    tomorrow = (datetime.now() + timedelta(days=1)).strftime("%Y-%m-%d")

    # Completed NNO task
    nno_data = {
        "Subject": "NNO",
        "Type": "Call",
        "TaskSubtype": "Call",
        "Status": "Completed",
        "Priority": "Normal",
        "ActivityDate": today,
    }

    contact_id = contact.get("Id")
    if contact_id:
        nno_data["WhoId"] = contact_id

    account_id = contact.get("AccountId")
    if account_id:
        nno_data["WhatId"] = account_id

    result = sf.Task.create(nno_data)
    nno_task_id = result["id"]
    logger.info("Created NNO Task %s for %s", nno_task_id, contact.get("Name"))

    # Follow-up task for next day
    follow_up_data = {
        "Subject": "Call back",
        "Type": "Call",
        "Status": "Open",
        "Priority": "Normal",
        "ActivityDate": tomorrow,
    }

    if contact_id:
        follow_up_data["WhoId"] = contact_id
    if account_id:
        follow_up_data["WhatId"] = account_id

    result = sf.Task.create(follow_up_data)
    follow_up_id = result["id"]
    logger.info("Created follow-up Task %s for %s (due: %s)", follow_up_id, contact.get("Name"), tomorrow)

    return nno_task_id, follow_up_id
