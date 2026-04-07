"""Authentication header builders for Bitbucket Cloud API."""


def rest_headers(token: str) -> dict:
    """Build request headers for Bitbucket Cloud REST API v2.0.

    Uses Bearer token authentication (API tokens with scopes).
    App passwords were deprecated September 2025 and disabled June 2026.
    """
    return {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "User-Agent": "insight-bitbucket-cloud-connector/1.0",
    }
