"""Bitbucket Cloud PR comments stream (incremental, per-PR, HttpSubStream of pull_requests)."""

import logging
from typing import Any, Dict, Iterable, Mapping, MutableMapping, Optional

from airbyte_cdk.models import SyncMode
from airbyte_cdk.sources.streams.http import HttpSubStream

from source_bitbucket_cloud.streams.base import BitbucketCloudStream, _make_unique_key


logger = logging.getLogger("airbyte")


def _translate_to_pr_state(
    state: Optional[Mapping[str, Any]],
    cursor_field: str,
) -> Dict[str, Dict[str, str]]:
    """Translate per-PR child state → per-repo PR-stream state.

    Child state: ``{ws/slug/pr_id: {pull_request_updated_on}}``.
    PR state:    ``{ws/slug:       {updated_on}}``.

    Per-repo cursor = ``min(pull_request_updated_on)`` across all PR entries
    in that repo. Using ``min`` (oldest successfully synced PR) ensures the
    PR stream re-yields any mid-age PR that was unprocessed when the child
    stream died last run. The child's own per-PR skip filters the rest.
    """
    per_repo_min: Dict[str, str] = {}
    for pk, entry in (state or {}).items():
        if not isinstance(entry, dict):
            continue
        parts = pk.rsplit("/", 1)
        if len(parts) != 2:
            continue
        repo_pk = parts[0]
        updated_on = entry.get(cursor_field, "") or ""
        if not updated_on:
            continue
        cur = per_repo_min.get(repo_pk, "")
        if not cur or updated_on < cur:
            per_repo_min[repo_pk] = updated_on
    return {repo: {"updated_on": v} for repo, v in per_repo_min.items()}


class PRCommentsStream(HttpSubStream, BitbucketCloudStream):
    """Comments per PR. Per-PR incremental state keyed by ``pull_request_updated_on``.

    - ``HttpSubStream`` re-iterates the parent PRs stream in full_refresh to build
      slices. Each PR slice is then gated by our own state so unchanged PRs are
      skipped.
    - PRs with ``comment_count == 0`` are skipped entirely (no API call).
    """

    name = "pull_request_comments"
    cursor_field = "pull_request_updated_on"
    state_checkpoint_interval = 500

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None) -> str:
        s = stream_slice or {}
        pr = s["parent"]
        return (
            f"repositories/{pr['workspace']}/{pr['repo_slug']}/"
            f"pullrequests/{pr['id']}/comments"
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
        skipped_no_comments = 0

        for parent_slice in super().stream_slices(
            sync_mode=sync_mode, cursor_field=cursor_field, stream_state=translated,
        ):
            pr = parent_slice["parent"]
            if not pr.get("comment_count"):
                skipped_no_comments += 1
                continue
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
            f"pull_request_comments: {total - skipped_unchanged} PRs to fetch "
            f"({skipped_unchanged} unchanged, {skipped_no_comments} zero-comment, "
            f"state_entries={len(state)})"
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
        for comment in self._iter_values(response):
            comment_id = comment.get("id")
            if comment_id is None:
                continue
            emitted += 1
            user = comment.get("user") or {}
            content = comment.get("content") or {}
            inline = comment.get("inline")
            parent_comment = comment.get("parent")

            record = {
                "unique_key": _make_unique_key(
                    self._tenant_id, self._source_id,
                    workspace, slug, str(pr_id), str(comment_id),
                ),
                "comment_id": comment_id,
                "pr_id": pr_id,
                "body": content.get("raw"),
                "body_html": content.get("html"),
                "created_on": comment.get("created_on"),
                "updated_on": comment.get("updated_on"),
                "author_display_name": user.get("display_name"),
                "author_uuid": user.get("uuid"),
                "author_nickname": user.get("nickname"),
                "is_inline": inline is not None,
                "inline_path": (inline or {}).get("path"),
                "inline_from": (inline or {}).get("from"),
                "inline_to": (inline or {}).get("to"),
                "parent_comment_id": parent_comment.get("id") if parent_comment else None,
                "is_deleted": comment.get("deleted", False),
                "pull_request_updated_on": pr_updated_on,
                "workspace": workspace,
                "repo_slug": slug,
            }
            yield self._envelope(record)

        logger.debug(
            f"pull_request_comments: {workspace}/{slug}/pr={pr_id} page emitted={emitted}"
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
                "comment_id": {"type": ["null", "integer"]},
                "pr_id": {"type": ["null", "integer"]},
                "body": {"type": ["null", "string"]},
                "body_html": {"type": ["null", "string"]},
                "created_on": {"type": ["null", "string"]},
                "updated_on": {"type": ["null", "string"]},
                "author_display_name": {"type": ["null", "string"]},
                "author_uuid": {"type": ["null", "string"]},
                "author_nickname": {"type": ["null", "string"]},
                "is_inline": {"type": ["null", "boolean"]},
                "inline_path": {"type": ["null", "string"]},
                "inline_from": {"type": ["null", "integer"]},
                "inline_to": {"type": ["null", "integer"]},
                "parent_comment_id": {"type": ["null", "integer"]},
                "is_deleted": {"type": ["null", "boolean"]},
                "pull_request_updated_on": {"type": ["null", "string"]},
                "workspace": {"type": "string"},
                "repo_slug": {"type": "string"},
            },
        }
