"""Bitbucket Cloud PR commits stream (incremental, per-PR, HttpSubStream of pull_requests)."""

import logging
import re
from typing import Any, Iterable, Mapping, MutableMapping, Optional

from airbyte_cdk.models import SyncMode
from airbyte_cdk.sources.streams.http import HttpSubStream

from source_bitbucket_cloud.streams.base import BitbucketCloudStream, _make_unique_key
from source_bitbucket_cloud.streams.pr_comments import _translate_to_pr_state


logger = logging.getLogger("airbyte")

_AUTHOR_RAW_RE = re.compile(r"^(.*?)\s*<([^>]+)>\s*$")


class PRCommitsStream(HttpSubStream, BitbucketCloudStream):
    """Commits per PR. Per-PR incremental state keyed by ``pull_request_updated_on``.

    ``HttpSubStream`` re-iterates parent PRs to build slices; our own state
    skips PRs whose ``updated_on`` hasn't moved since last sync.
    """

    name = "pull_request_commits"
    cursor_field = "pull_request_updated_on"
    state_checkpoint_interval = 500

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None) -> str:
        s = stream_slice or {}
        pr = s["parent"]
        return (
            f"repositories/{pr['workspace']}/{pr['repo_slug']}/"
            f"pullrequests/{pr['id']}/commits"
        )

    def stream_slices(
        self,
        sync_mode: SyncMode,
        cursor_field: Optional[list] = None,
        stream_state: Optional[Mapping[str, Any]] = None,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or {}
        translated = _translate_to_pr_state(state, self.cursor_field)
        total = 0
        skipped_unchanged = 0

        for parent_slice in super().stream_slices(
            sync_mode=sync_mode, cursor_field=cursor_field, stream_state=translated,
        ):
            pr = parent_slice["parent"]
            total += 1
            workspace = pr["workspace"]
            slug = pr["repo_slug"]
            pr_id = pr["id"]
            pr_updated_on = pr.get("updated_on", "") or ""
            partition_key = f"{workspace}/{slug}/{pr_id}"

            synced_at = (state.get(partition_key, {}) or {}).get(self.cursor_field, "") or ""
            if pr_updated_on and synced_at and pr_updated_on <= synced_at:
                skipped_unchanged += 1
                continue

            yield {"parent": pr}

        logger.info(
            f"pull_request_commits: {total - skipped_unchanged} PRs to fetch "
            f"({skipped_unchanged} unchanged, state_entries={len(state)})"
        )

    def parse_response(
        self,
        response,
        stream_slice: Optional[Mapping[str, Any]] = None,
        **kwargs: Any,
    ):
        s = stream_slice or {}
        pr = s["parent"]
        workspace = pr["workspace"]
        slug = pr["repo_slug"]
        pr_id = pr["id"]
        pr_updated_on = pr.get("updated_on", "")

        emitted = 0
        for commit in self._iter_values(response):
            commit_hash = commit.get("hash", "") or ""
            if not commit_hash:
                continue
            emitted += 1
            author = commit.get("author") or {}
            author_raw = author.get("raw", "") or ""
            author_user = author.get("user") or {}
            author_name = author_raw
            author_email = None
            m = _AUTHOR_RAW_RE.match(author_raw)
            if m:
                author_name = m.group(1).strip()
                author_email = m.group(2).strip()

            record = {
                "unique_key": _make_unique_key(
                    self._tenant_id, self._source_id,
                    workspace, slug, str(pr_id), commit_hash,
                ),
                "pr_id": pr_id,
                "hash": commit_hash,
                "message": commit.get("message"),
                "date": commit.get("date"),
                "author_raw": author_raw,
                "author_name": author_name,
                "author_email": author_email,
                "author_display_name": author_user.get("display_name"),
                "author_uuid": author_user.get("uuid"),
                "author_nickname": author_user.get("nickname"),
                "pull_request_updated_on": pr_updated_on,
                "workspace": workspace,
                "repo_slug": slug,
            }
            yield self._envelope(record)

        logger.debug(
            f"pull_request_commits: {workspace}/{slug}/pr={pr_id} page emitted={emitted}"
        )

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        workspace = latest_record.get("workspace", "")
        slug = latest_record.get("repo_slug", "")
        pr_id = latest_record.get("pr_id")
        if not (workspace and slug and pr_id):
            return current_stream_state
        partition_key = f"{workspace}/{slug}/{pr_id}"
        pr_updated_on = latest_record.get(self.cursor_field, "") or ""
        if pr_updated_on:
            current_stream_state[partition_key] = {self.cursor_field: pr_updated_on}
        return current_stream_state

    def get_json_schema(self) -> Mapping[str, Any]:
        return {
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
            "additionalProperties": True,
            "properties": {
                "tenant_id": {"type": "string"},
                "source_id": {"type": "string"},
                "unique_key": {"type": "string"},
                "data_source": {"type": "string"},
                "collected_at": {"type": "string"},
                "pr_id": {"type": ["null", "integer"]},
                "hash": {"type": ["null", "string"]},
                "message": {"type": ["null", "string"]},
                "date": {"type": ["null", "string"]},
                "author_raw": {"type": ["null", "string"]},
                "author_name": {"type": ["null", "string"]},
                "author_email": {"type": ["null", "string"]},
                "author_display_name": {"type": ["null", "string"]},
                "author_uuid": {"type": ["null", "string"]},
                "author_nickname": {"type": ["null", "string"]},
                "pull_request_updated_on": {"type": ["null", "string"]},
                "workspace": {"type": "string"},
                "repo_slug": {"type": "string"},
            },
        }
