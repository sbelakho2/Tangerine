"""Provider registry (INTERFACES.md §5).

:func:`default_providers` returns the two built-ins ordered by authority
(the native Tangerine provider first — it is authoritative for Tangerine
code; the stdlib-only scanner is the zero-install fallback).  ``register``
adds additional providers; :func:`select_for` returns every applicable
provider for a root, authority-ordered.  ``provider_set_digest`` is the §1
``sha256 over sorted (provider_id, provider_version)``.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from system_intel.providers.generic_static import GenericStaticProvider
from system_intel.providers.tangerine_native import TangerineNativeProvider

_REGISTERED: list = []

_DEFAULT_AUTHORITY = 100


def _authority(provider) -> int:
    try:
        return int(getattr(provider, "authority", _DEFAULT_AUTHORITY))
    except (TypeError, ValueError):
        return _DEFAULT_AUTHORITY


def register(provider) -> None:
    """Register a provider instance; replaces a same-id registration."""
    provider_id = str(getattr(provider, "provider_id", "") or "")
    provider_version = str(getattr(provider, "provider_version", "") or "")
    if not provider_id:
        raise ValueError("provider must declare a non-empty provider_id")
    if not provider_version:
        raise ValueError("provider must declare a non-empty provider_version")
    for index, existing in enumerate(_REGISTERED):
        if getattr(existing, "provider_id", "") == provider_id:
            _REGISTERED[index] = provider
            return
    _REGISTERED.append(provider)


def default_providers() -> list:
    """The two built-in providers, authority-ordered (native first)."""
    providers = [TangerineNativeProvider(), GenericStaticProvider()]
    return sorted(providers, key=lambda p: (_authority(p), p.provider_id))


def all_providers() -> list:
    """Every known provider: defaults plus registrations, authority-ordered."""
    providers = default_providers() + list(_REGISTERED)
    return sorted(providers, key=lambda p: (_authority(p), p.provider_id))


def select_for(root) -> list:
    """All applicable providers for ``root``, ordered by authority."""
    applicable = []
    for provider in all_providers():
        applies_to = getattr(provider, "applies_to", None)
        try:
            if applies_to is None or applies_to(root):
                applicable.append(provider)
        except Exception:  # noqa: BLE001 - applicability probes never crash selection
            continue
    return applicable


def provider_set_digest(providers) -> str:
    """§1: sha256 over the canonical sorted (provider_id, version) pairs."""
    pairs = sorted(
        (str(getattr(p, "provider_id", "") or ""),
         str(getattr(p, "provider_version", "") or ""))
        for p in providers
    )
    canonical = json.dumps(pairs, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()
