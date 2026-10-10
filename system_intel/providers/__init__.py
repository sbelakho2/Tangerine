"""system_intel semantic providers (INTERFACES.md §5).

Export surface: the provider SPI from :mod:`system_intel.providers.base`,
the two built-in providers, and the registry helpers.
"""

from system_intel.providers.base import (
    COMPLETENESS_VERDICTS,
    ProviderCapability,
    ProviderEntity,
    ProviderEvidence,
    ProviderFact,
    ProviderRelation,
    ProviderSnapshot,
    ProviderUnresolved,
    SemanticProvider,
    normalize_verdict,
    verdict_rank,
    worst_verdict,
)
from system_intel.providers.generic_static import GenericStaticProvider
from system_intel.providers.registry import (
    all_providers,
    default_providers,
    provider_set_digest,
    register,
    select_for,
)
from system_intel.providers.tangerine_native import (
    NativeProtocolError,
    TangerineNativeProvider,
    frame_request,
    parse_response_body,
    read_frame,
)

__all__ = [
    "COMPLETENESS_VERDICTS",
    "GenericStaticProvider",
    "NativeProtocolError",
    "ProviderCapability",
    "ProviderEntity",
    "ProviderEvidence",
    "ProviderFact",
    "ProviderRelation",
    "ProviderSnapshot",
    "ProviderUnresolved",
    "SemanticProvider",
    "TangerineNativeProvider",
    "all_providers",
    "default_providers",
    "frame_request",
    "normalize_verdict",
    "parse_response_body",
    "provider_set_digest",
    "read_frame",
    "register",
    "select_for",
    "verdict_rank",
    "worst_verdict",
]
