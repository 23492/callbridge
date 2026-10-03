import base64
import html
import itertools
import json
import os
import re
import logging
import threading
import time
from datetime import datetime, timedelta
from simple_salesforce import Salesforce
from config import SF_USERNAME, SF_PASSWORD, SF_SECURITY_TOKEN, SF_DOMAIN

logger = logging.getLogger(__name__)

# Lazy-initialized Salesforce connection
_sf = None
_sf_last_used = 0.0
_sf_lock = threading.Lock()

# Re-login after this much idle time. simple_salesforce never refreshes an expired
# session itself, so a backend left running overnight would otherwise fail every
# call with INVALID_SESSION_ID until restarted. Kept well under the org's timeout.
_SF_IDLE_RELOGIN_SECONDS = 30 * 60

# Object types the UI may pass in, and the shape of a Salesforce Id. Both are
# interpolated into SOQL, so they must be validated first.
ALLOWED_RECORD_TYPES = ("Contact", "Account", "Lead")
_SF_ID_RE = re.compile(r"^[a-zA-Z0-9]{15}(?:[a-zA-Z0-9]{3})?$")

# Lazy-initialized Id of the API user (SF_USERNAME). Cached to avoid a query per call.
_user_id = None

# Subjects of open follow-up tasks that a call to the person satisfies. Matched
# exactly on the whole subject (case-insensitive, whitespace-trimmed) — never as
# a substring, so real tasks like "send follow up email" are left untouched.
# Extend this list to cover more reminder subjects.
FOLLOWUP_SUBJECTS = ("Call back", "Follow up", "Check in")
_FOLLOWUP_SUBJECTS_NORM = frozenset(s.strip().casefold() for s in FOLLOWUP_SUBJECTS)


def dry_run_enabled() -> bool:
    """True when the backend runs in dry-run mode (FND-06).

    Read on every call so tests can toggle it. Only the backend environment
    variable switches it (D-05): no request parameter and no app setting.
    """
    return os.getenv("CALLBRIDGE_DRY_RUN") == "1"


class DryRunWriteBlocked(RuntimeError):
    """Raised when code tries to write to Salesforce in dry-run without _sf_write."""


class _ReadOnlySObject:
    """Wraps an SObject handle (sf.Task etc.) and refuses every write."""

    _WRITE_OPS = frozenset(("create", "update", "upsert", "delete"))

    def __init__(self, inner, name: str):
        self._inner = inner
        self._name = name

    def __getattr__(self, attr):
        if attr in self._WRITE_OPS:
            raise DryRunWriteBlocked(
                f"dry-run: direct {attr} on {self._name} blocked; writes must go through _sf_write"
            )
        return getattr(self._inner, attr)


class _ReadOnlySalesforce:
    """Second barrier in dry-run: reads (query, search, limits) pass through,
    SObject handles (capitalised attributes such as Task) refuse writes."""

    def __init__(self, inner):
        self._inner = inner

    def __getattr__(self, name):
        value = getattr(self._inner, name)
        if name[:1].isupper():
            return _ReadOnlySObject(value, name)
        return value


def _get_sf():
    """Salesforce client for reads. In dry-run it is a read-only proxy."""
    client = _raw_sf()
    if dry_run_enabled():
        return _ReadOnlySalesforce(client)
    return client


_dry_counter = itertools.count(1)


def _sf_write(sobject: str, op: str, payload: dict, record_id: str | None = None) -> str:
    """The only function that writes to Salesforce (D-08).

    In dry-run it writes nothing and logs one line per would-be write with the
    full payload (D-07), returning record_id for updates or a fake
    DRYRUN-<sobject>-<n> id for creates. Otherwise it performs the create or
    update on the real client and returns the record id.
    """
    if op not in ("create", "update"):
        raise ValueError(f"unsupported Salesforce write op {op!r}")
    if dry_run_enabled():
        fake = record_id if op == "update" else f"DRYRUN-{sobject}-{next(_dry_counter):04d}"
        logger.info("DRY-RUN %s %s %s %s", op, sobject, fake,
                    json.dumps(payload, ensure_ascii=False, default=str))
        return fake
    api = getattr(_raw_sf(), sobject)
    if op == "create":
        return api.create(payload)["id"]
    api.update(record_id, payload)
    return record_id


def _raw_sf() -> Salesforce:
    """Get or create the Salesforce connection (re-logs in after long idle)."""
    global _sf, _sf_last_used
    with _sf_lock:
        now = time.monotonic()
        if _sf is not None and now - _sf_last_used > _SF_IDLE_RELOGIN_SECONDS:
            logger.info("Salesforce connection idle for >%ds — re-logging in", _SF_IDLE_RELOGIN_SECONDS)
            _sf = None
        if _sf is None:
            _sf = Salesforce(
                username=SF_USERNAME,
                password=SF_PASSWORD,
                security_token=SF_SECURITY_TOKEN,
                domain=SF_DOMAIN,
            )
            logger.info("Connected to Salesforce (domain: %s)", SF_DOMAIN)
        _sf_last_used = now
        return _sf


def _soql_str(value: str) -> str:
    """Escape a value for use inside a single-quoted SOQL string literal."""
    return value.replace("\\", "\\\\").replace("'", "\\'")


def is_valid_sf_id(value: str | None) -> bool:
    return bool(value) and bool(_SF_ID_RE.match(value))


def _get_user_id() -> str:
    """Get (and cache) the Id of the API user (SF_USERNAME)."""
    global _user_id
    if _user_id is None:
        sf = _get_sf()
        record = sf.query(f"SELECT Id FROM User WHERE Username = '{_soql_str(SF_USERNAME or '')}'")["records"][0]
        _user_id = record["Id"]
        logger.info("Resolved API user Id: %s", _user_id)
    return _user_id


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
                "Company": record.get("Company"),
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
        # find_contact_by_phone's Account result keeps the Id in AccountId (Id=None,
        # since WhoId can't take an Account) — fall back to it so the UI gets an id.
        account_id = record.get("Id") or record.get("AccountId")
        base["id"] = account_id
        base["account_name"] = record.get("Name")
        base["account_id"] = account_id
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


def resolve_provided_record(salesforce_id: str, salesforce_type: str) -> dict:
    """
    Build the internal contact dict from a Salesforce record the user picked in
    the CallBridge UI (Contact, Account, or Lead).

    A Task's WhoId only accepts a Contact or Lead; an Account belongs in WhatId.
    So for an Account we leave "Id" (-> WhoId) empty and put the Account Id in
    "AccountId" (-> WhatId), mirroring find_contact_by_phone's Account branch.
    Putting an Account Id in "Id" is what makes Salesforce reject the Task with
    FIELD_INTEGRITY_EXCEPTION on WhoId.
    """
    if salesforce_type not in ALLOWED_RECORD_TYPES:
        raise ValueError(f"Unsupported Salesforce type: {salesforce_type!r}")
    if not is_valid_sf_id(salesforce_id):
        raise ValueError(f"Invalid Salesforce Id: {salesforce_id!r}")

    sf = _get_sf()
    is_contact = salesforce_type == "Contact"
    records = sf.query(
        f"SELECT Id, Name{', AccountId' if is_contact else ''} "
        f"FROM {salesforce_type} WHERE Id = '{salesforce_id}'"
    )["records"]
    if not records:
        raise ValueError(f"{salesforce_type} {salesforce_id} not found")
    record = records[0]

    if salesforce_type == "Account":
        # Account -> WhatId only; there is no person for WhoId.
        return {"Id": None, "Name": record["Name"], "AccountId": record["Id"]}
    # Contact carries its own AccountId; Lead has none (WhoId-only).
    return {"Id": record["Id"], "Name": record["Name"], "AccountId": record.get("AccountId")}


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

    task_id = _sf_write("Task", "create", task_data)
    logger.info("Created Task %s for contact %s (follow-up: %s)", task_id, contact["Name"], follow_up_date)
    return task_id


def create_transcript_content_note(transcript: str) -> str:
    """
    Create a ContentNote with the full transcript. Returns the ContentNote ID,
    which is also the ContentDocumentId used to link it.
    """
    today = datetime.now().strftime("%d %B %Y")

    # ContentNote content must be base64-encoded HTML
    # Escape first: a transcript containing & or < made the note invalid HTML.
    html_content = "<p>" + html.escape(transcript, quote=False).replace("\n", "</p><p>") + "</p>"
    encoded = base64.b64encode(html_content.encode("utf-8")).decode("utf-8")

    return _sf_write("ContentNote", "create", {
        "Title": today,
        "Content": encoded,
    })


def link_note_to_task(note_id: str, task_id: str) -> None:
    """Link a ContentNote (by its ContentDocumentId) to the Task."""
    _sf_write("ContentDocumentLink", "create", {
        "ContentDocumentId": note_id,
        "LinkedEntityId": task_id,
        "ShareType": "V",
        "Visibility": "AllUsers",
    })


def create_transcript_note(task_id: str, transcript: str) -> str:
    """
    Create a ContentNote with the full transcript and link it to the Task.

    Two writes; the pipeline calls the halves separately so the ledger can
    record the note before the link. Returns the ContentNote ID.
    """
    note_id = create_transcript_content_note(transcript)
    link_note_to_task(note_id, task_id)
    logger.info("Created ContentNote %s linked to Task %s", note_id, task_id)
    return note_id


def set_follow_up_date(task_id: str, follow_up_date: str):
    """
    Set the Auto Generate Follow Up Task date on an existing Task.
    This triggers Salesforce automation to create a follow-up task.
    follow_up_date should be YYYY-MM-DD format.
    """
    _sf_write("Task", "update", {
        "Auto_Generate_Follow_Up_Task__c": follow_up_date,
    }, record_id=task_id)
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
    task_data = {
        "Subject": description[:255],
        "Status": "Not Started",
        "Priority": "Normal",
        "Description": description,
    }

    # WhoId only accepts a Contact/Lead; skip it for Account-only associations.
    contact_id = contact.get("Id")
    if contact_id:
        task_data["WhoId"] = contact_id

    if due_date:
        task_data["ActivityDate"] = due_date

    account_id = contact.get("AccountId")
    if account_id:
        task_data["WhatId"] = account_id

    task_id = _sf_write("Task", "create", task_data)
    logger.info("Created action Task %s: %s (due: %s)", task_id, description, due_date)
    return task_id


def fetch_my_open_future_tasks(record_id: str | None) -> list[dict]:
    """
    Open tasks due today or later that are related to the record (as WhoId for a
    Contact/Lead, or WhatId for an Account) AND owned by the API user. The org is
    shared, so colleagues' tasks are never shown in the menu.
    """
    if not is_valid_sf_id(record_id):
        return []
    # 001 = Account (only valid as WhatId); Contact (003) / Lead (00Q) are WhoIds.
    relation = "WhatId" if record_id.startswith("001") else "WhoId"
    try:
        sf = _get_sf()
        owner_id = _get_user_id()
        results = sf.query(
            "SELECT Id, Subject, ActivityDate FROM Task "
            f"WHERE {relation} = '{record_id}' "
            f"AND OwnerId = '{owner_id}' "
            "AND IsClosed = false AND ActivityDate >= TODAY "
            "ORDER BY ActivityDate ASC LIMIT 10"
        )
        return [
            {"task_id": r["Id"], "subject": r.get("Subject") or "", "activity_date": r.get("ActivityDate") or ""}
            for r in results["records"]
        ]
    except Exception as e:
        logger.warning("Failed to fetch future tasks for %s: %s", record_id, e)
        return []


def complete_due_followup_tasks(who_id: str) -> int:
    """
    Mark the API user's own open follow-up tasks on a person (Contact or Lead)
    that are due today or earlier as Completed. Calling the person satisfies any
    overdue follow-up reminder whose subject is in FOLLOWUP_SUBJECTS
    ('Call back', 'Follow up', 'Check in').

    The subject must match a whitelist entry exactly (case-insensitive,
    whitespace-trimmed) — never as a substring — so tasks like "send follow up
    email" or "check in mbt servicecloud" are never touched. The SOQL IN filter
    narrows candidates efficiently; a Python-side normalized check then guards
    against SOQL's looser matching before anything is completed.

    Only touches tasks owned by the API user (SF_USERNAME) — this is a shared
    production org, so colleagues' tasks are never changed.

    Never raises: any failure is logged as a warning and 0 is returned, so
    cleanup can never break call logging.

    Returns the number of tasks completed.
    """
    if not who_id:
        return 0

    try:
        sf = _get_sf()
        owner_id = _get_user_id()
        subjects_in = ", ".join(f"'{s}'" for s in FOLLOWUP_SUBJECTS)
        result = sf.query(
            "SELECT Id, Subject FROM Task "
            f"WHERE WhoId = '{who_id}' "
            f"AND Subject IN ({subjects_in}) "
            "AND IsClosed = false "
            "AND ActivityDate <= TODAY "
            f"AND OwnerId = '{owner_id}'"
        )
        completed = 0
        for record in result["records"]:
            # Guard: exact whitelist match on the trimmed, case-folded subject.
            if (record.get("Subject") or "").strip().casefold() not in _FOLLOWUP_SUBJECTS_NORM:
                continue
            _sf_write("Task", "update", {"Status": "Completed"}, record_id=record["Id"])
            logger.info("Completed due follow-up Task %s ('%s') on %s", record["Id"], record.get("Subject"), who_id)
            completed += 1
        return completed
    except Exception as e:
        logger.warning("Failed to complete due follow-up tasks for %s (non-fatal): %s", who_id, e)
        return 0


def create_nno_log(contact: dict) -> tuple[str, str]:
    """
    Create a completed NNO call task and a follow-up 'Call back' task for the next day.
    Returns (nno_task_id, follow_up_task_id).
    """
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

    nno_task_id = _sf_write("Task", "create", nno_data)
    logger.info("Created NNO Task %s for %s", nno_task_id, contact.get("Name"))

    # This call satisfies any overdue follow-up reminder on the person.
    if contact_id:
        complete_due_followup_tasks(contact_id)

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

    follow_up_id = _sf_write("Task", "create", follow_up_data)
    logger.info("Created follow-up Task %s for %s (due: %s)", follow_up_id, contact.get("Name"), tomorrow)

    return nno_task_id, follow_up_id
