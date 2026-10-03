"""FakeSalesforce: records every call and never touches the network."""


class _SObject:
    def __init__(self, name, owner):
        self.name = name
        self._owner = owner
        self.n = 0

    def create(self, payload):
        self._owner._maybe_fail(self.name, "create")
        self.n += 1
        self._owner.calls.append(("create", self.name, dict(payload)))
        return {"id": f"FAKE{self.name[:3]}{self.n:012d}"}

    def update(self, record_id, payload):
        self._owner._maybe_fail(self.name, "update")
        self._owner.calls.append(("update", self.name, record_id, dict(payload)))
        return 204


class FakeSalesforce:
    """Records ("create", name, payload), ("update", name, id, payload),
    ("query", soql) and ("search", sosl) in self.calls.

    query_results maps a SOQL substring to the result returned for the first
    query containing it; unmatched queries return no records.
    """

    SOBJECTS = ("Task", "ContentNote", "ContentDocumentLink")

    def __init__(self, query_results=None, search_results=None):
        self.calls = []
        self.query_results = query_results or {}
        self.search_results = search_results or {"searchRecords": []}
        self._failures = []
        for name in self.SOBJECTS:
            setattr(self, name, _SObject(name, self))

    def query(self, soql):
        self.calls.append(("query", soql))
        for key, value in self.query_results.items():
            if key in soql:
                return value
        return {"records": []}

    def search(self, sosl):
        self.calls.append(("search", sosl))
        return self.search_results

    def writes(self):
        """Only the create/update entries."""
        return [c for c in self.calls if c[0] in ("create", "update")]

    def queries(self):
        return [c[1] for c in self.calls if c[0] == "query"]

    def fail_next(self, sobject_name, op):
        """Make the next matching call raise RuntimeError, once."""
        self._failures.append((sobject_name, op))

    def _maybe_fail(self, sobject_name, op):
        if (sobject_name, op) in self._failures:
            self._failures.remove((sobject_name, op))
            raise RuntimeError(f"FakeSalesforce: injected failure on {op} {sobject_name}")
