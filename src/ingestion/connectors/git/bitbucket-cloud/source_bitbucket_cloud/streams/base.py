"""Base stream for Bitbucket Cloud REST API v2.0.

Stock Airbyte CDK primitives only. No custom read_records overrides, no
response-swallowing, no blocking sleeps. Errors raise by default and CDK
retries via should_retry/backoff_time.
"""

import logging
from abc import ABC
from datetime import datetime, timezone
from typing import Any, Iterable, Mapping, MutableMapping, Optional

import requests
from airbyte_cdk.sources.streams.http import HttpStream

from source_bitbucket_cloud.auth import auth_headers

_logger = logging.getLogger("airbyte")


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _make_unique_key(tenant_id: str, source_id: str, *parts: str) -> str:
    return f"{tenant_id}:{source_id}:{':'.join(parts)}"


class BitbucketCloudStream(HttpStream, ABC):
    """Base for all Bitbucket Cloud streams.

    Keeps request/response handling as close to CDK defaults as possible:
    - raise_on_http_errors stays True (default) — exhausted retries fail the stream.
    - should_retry only distinguishes retryable vs terminal status codes.
    - backoff_time honours Retry-After on 429 and a fixed 30s on transient 5xx.
    """

    url_base = "https://api.bitbucket.org/2.0/"
    primary_key = "unique_key"
    page_size = 100

    def __init__(
        self,
        token: str,
        tenant_id: str,
        source_id: str,
        username: str = "",
        **kwargs: Any,
    ) -> None:
        super().__init__(**kwargs)
        self._token = token
        self._username = username
        self._tenant_id = tenant_id
        self._source_id = source_id

    # ------------------------------------------------------------------
    # Requests
    # ------------------------------------------------------------------

    @property
    def request_timeout(self) -> Optional[int]:
        return 60

    def request_headers(self, **kwargs: Any) -> Mapping[str, Any]:
        return auth_headers(self._token, self._username)

    def request_params(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        stream_slice: Optional[Mapping[str, Any]] = None,
        next_page_token: Optional[Mapping[str, Any]] = None,
    ) -> MutableMapping[str, Any]:
        # When following a next_url the URL already carries the params.
        if next_page_token:
            return {}
        return {"pagelen": str(self.page_size)}

    def next_page_token(self, response: requests.Response) -> Optional[Mapping[str, Any]]:
        try:
            data = response.json()
        except ValueError:
            return None
        nxt = data.get("next")
        return {"next_url": nxt} if nxt else None

    def path(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        stream_slice: Optional[Mapping[str, Any]] = None,
        next_page_token: Optional[Mapping[str, Any]] = None,
    ) -> str:
        if next_page_token and "next_url" in next_page_token:
            full_url = next_page_token["next_url"]
            if full_url.startswith(self.url_base):
                return full_url[len(self.url_base):]
            return full_url.replace("https://api.bitbucket.org/2.0/", "")
        return self._path(stream_slice=stream_slice)

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None) -> str:
        raise NotImplementedError

    # ------------------------------------------------------------------
    # Retry
    # ------------------------------------------------------------------

    def should_retry(self, response: requests.Response) -> bool:
        # 401/403/404 are terminal — do not retry and do not silently swallow.
        if response.status_code in (401, 403, 404):
            _logger.warning(
                f"{self.name}: terminal {response.status_code} on {response.url} "
                f"body={response.text[:200]!r}"
            )
            return False
        retry = response.status_code in (429, 500, 502, 503, 504)
        if retry:
            _logger.warning(
                f"{self.name}: retryable {response.status_code} on {response.url}"
            )
        return retry

    def backoff_time(self, response: requests.Response) -> Optional[float]:
        if response.status_code == 429:
            try:
                wait = max(float(response.headers.get("Retry-After", 60)), 1.0)
            except (TypeError, ValueError):
                wait = 60.0
            _logger.warning(
                f"{self.name}: 429 throttled, backing off {wait}s (Retry-After="
                f"{response.headers.get('Retry-After')!r})"
            )
            return wait
        if response.status_code in (500, 502, 503, 504):
            _logger.warning(f"{self.name}: {response.status_code}, backing off 30s")
            return 30.0
        return None

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _envelope(self, record: Mapping[str, Any]) -> MutableMapping[str, Any]:
        out = dict(record)
        out["tenant_id"] = self._tenant_id
        out["source_id"] = self._source_id
        out["data_source"] = "insight_bitbucket_cloud"
        out["collected_at"] = _now_iso()
        return out

    def _iter_values(self, response: requests.Response) -> Iterable[Mapping[str, Any]]:
        try:
            data = response.json()
        except ValueError:
            _logger.warning(
                f"{self.name}: non-JSON response {response.status_code} on {response.url}"
            )
            return []
        values = data.get("values", []) or []
        _logger.debug(
            f"{self.name}: {len(values)} values on page (url={response.url})"
        )
        return values
