"""Authentication header builders for Bitbucket Cloud API."""

import base64


def rest_headers(email: str, token: str) -> dict:
    """Build request headers for Bitbucket Cloud REST API v2.0.

    Uses Basic Auth with email + API token (the current Bitbucket auth method).
    App passwords were deprecated September 2025.
    """
    creds = base64.b64encode(f"{email}:{token}".encode()).decode()
    return {
        "Authorization": f"Basic {creds}",
        "Accept": "application/json",
        "User-Agent": "insight-bitbucket-cloud-connector/1.0",
    }
