"""Provider SPI for system_intel v2 (INTERFACES.md §5).

The semantic-federation contract: ``system_intel`` is not the analyzer; it
federates interchangeable providers.  A provider answers, in order:

    identity -> capabilities -> snapshot -> query -> delta -> completeness

Semantics:

* ``identity(root)``          — the §1 identity fields the provider can read
                               (native revision, semantic configuration,
                               surface hashes); missing fields are ``""``.
* ``capabilities()``         — one :class:`ProviderCapability` per family;
                               verdicts are the §0 completeness vocabulary.
* ``snapshot(root, ...)``    — a :class:`ProviderSnapshot`; NEVER raises for
                               an expected unavailable state (missing binary,
                               no artifact, protocol mismatch) — it degrades
                               to empty data plus ``unavailable`` verdicts, a
                               note and a recorded evidence entry.
* ``query(snapshot, op)``    — ``{"kind", "records"/"keys", "completeness",
                               "note"}`` over the materialized snapshot.
* ``delta(old, new)``        — ``{"added", "removed", "changed",
                               "unresolved_added"}`` of stable keys.  A
                               provider MAY add ``source`` ('native' |
                               'generic') and ``note`` keys to record which
                               delta engine produced the sets; consumers must
                               treat the four key sets as the stable core.
* ``completeness(family)``   — the verdict for one family from the last
                               snapshot; ``unknown`` before the first one.

Completeness verdicts MIRROR the producing provider and are never upgraded:
a native family marked ``Unknown`` can never read back ``complete``.

Contract canonicalization convention (§5 ``Contract``): a provider that
declares or references contracts emits provider facts with
``predicate='contract_ref'`` and ``object='contract:<kind>:<name>'`` where
``<kind>`` is the provider's contract-kind word (e.g. the Tangerine native
``Pre``/``Post``/``Invariant``) and ``<name>`` is the provider's canonical,
stable contract name (for the native provider the canonical contract row key
``<fn key>|<kind>|<clause>``).  This is the machine-readable pair consumers
feed to ``Graph.add_contract(kind, name, ...)``; the human ``Contract``
entity/relation projection rides beside it.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable

COMPLETENESS_VERDICTS = ("complete", "partial", "unavailable", "unknown")

_VERDICT_RANK = {"complete": 3, "partial": 2, "unknown": 1, "unavailable": 0}


def normalize_verdict(word: Any, *, default: str = "unknown") -> str:
    """Map a word onto the completeness vocabulary WITHOUT upgrading it.

    Recognized verdicts are returned verbatim; anything else (including a
    native ``"Unknown"``, an empty string or a future word) fails closed to
    ``default``.  Callers must never turn an upstream ``partial``/``unknown``
    into ``complete``.
    """
    text = str(word if word is not None else "").strip().lower()
    if text in COMPLETENESS_VERDICTS:
        return text
    return default


def verdict_rank(verdict: Any) -> int:
    """Rank a verdict (higher is stronger); unrecognized words rank as 0."""
    return _VERDICT_RANK.get(str(verdict), 0)


def worst_verdict(*verdicts: Any) -> str:
    """The weakest verdict of the arguments (never stronger than any input)."""
    worst: str | None = None
    for verdict in verdicts:
        norm = normalize_verdict(verdict)
        if worst is None or verdict_rank(norm) < verdict_rank(worst):
            worst = norm
    return worst or "unknown"


@dataclass(frozen=True)
class ProviderCapability:
    """One family verdict; ``note`` carries the honest derivation/limits."""

    family: str
    verdict: str
    note: str = ""


@dataclass
class ProviderEntity:
    kind: str
    name: str
    qualified_name: str
    stable_id: str
    file: str | None = None
    line: int | None = None
    tier: int = 1
    provenance: str = "observed"
    confidence: float = 1.0
    derived_from: tuple[str, ...] = ()
    attrs: dict = field(default_factory=dict)
    epistemic_state: str = "observed"
    analysis_depth: int = 1
    completeness: str = "partial"
    provider: str = ""
    provider_revision: str = ""


@dataclass
class ProviderRelation:
    src_key: str
    dst_key: str
    kind: str
    src_kind: str | None = None
    dst_kind: str | None = None
    tier: int = 1
    provenance: str = "inferred"
    confidence: float = 1.0
    derived_from: tuple[str, ...] = ()
    attrs: dict = field(default_factory=dict)
    epistemic_state: str = "inferred"
    analysis_depth: int = 1
    completeness: str = "partial"
    provider: str = ""
    provider_revision: str = ""


@dataclass
class ProviderFact:
    subject: str
    predicate: str
    object: str
    stable_subject: str = ""
    tier: int = 1
    provenance: str = "observed"
    confidence: float = 1.0
    derived_from: tuple[str, ...] = ()
    uncertainty: str | None = None
    attrs: dict = field(default_factory=dict)
    epistemic_state: str = "observed"
    analysis_depth: int = 1
    completeness: str = "partial"
    provider: str = ""
    provider_revision: str = ""


@dataclass
class ProviderUnresolved:
    """A typed-but-unresolved edge claim (§2 ``unresolved_edge``)."""

    src_key: str
    dst_raw: str
    kind: str
    candidates: tuple[str, ...] = ()
    confidence: float = 0.3
    completeness: str = "unknown"
    evidence: tuple[str, ...] = ()
    attrs: dict = field(default_factory=dict)
    provider: str = ""
    provider_revision: str = ""


@dataclass
class ProviderEvidence:
    kind: str
    ref: str
    digest: str | None = None
    summary: str = ""
    payload: Any = None
    provider: str = ""


@dataclass
class ProviderSnapshot:
    """The universal materialized answer of one provider invocation."""

    entities: list[ProviderEntity] = field(default_factory=list)
    relations: list[ProviderRelation] = field(default_factory=list)
    facts: list[ProviderFact] = field(default_factory=list)
    unresolved: list[ProviderUnresolved] = field(default_factory=list)
    evidence: list[ProviderEvidence] = field(default_factory=list)
    providers: list[dict] = field(default_factory=list)
    semantic_configuration: dict = field(default_factory=dict)
    provider_id: str = ""
    provider_version: str = ""
    capabilities: list[ProviderCapability] = field(default_factory=list)
    # The SEMANTIC SCOPE this observation speaks about (what the
    # completeness verdicts are relative to): target/features, languages,
    # module sets, test globs, platform/horizon for runtime observations.
    # A completeness verdict without scope is meaningless, so this travels
    # with the snapshot into the immutable ProviderObservation.
    scope: dict = field(default_factory=dict)

    def completeness(self, family: str) -> str:
        """Snapshot-level family verdict (mirrors the capability list)."""
        for cap in self.capabilities:
            if cap.family == str(family):
                return cap.verdict
        return "unknown"

    def capability_record(self) -> dict:
        """The ``provider_record.capabilities`` JSON shape (family->verdict)."""
        return {cap.family: cap.verdict for cap in self.capabilities}


@runtime_checkable
class SemanticProvider(Protocol):
    """The §5 provider SPI.  Identity -> capabilities -> snapshot -> query."""

    provider_id: str
    provider_version: str

    def identity(self, root) -> dict:
        """§1 identity fields readable by this provider (missing -> '')."""
        ...

    def capabilities(self) -> list[ProviderCapability]:
        """One verdict per family this provider can speak about."""
        ...

    def snapshot(self, root, *, commit_sha: str | None = None) -> ProviderSnapshot:
        """Materialize the provider's view; never raises for unavailable."""
        ...

    def query(self, snapshot: ProviderSnapshot, operation: str, **kwargs) -> dict:
        """Query a materialized snapshot; the documented dict shape."""
        ...

    def delta(self, old_snapshot: ProviderSnapshot,
              new_snapshot: ProviderSnapshot) -> dict:
        """Stable-key set diff of two snapshots; the documented dict shape."""
        ...

    def completeness(self, family: str) -> str:
        """The family verdict from the last snapshot; 'unknown' before one."""
        ...
