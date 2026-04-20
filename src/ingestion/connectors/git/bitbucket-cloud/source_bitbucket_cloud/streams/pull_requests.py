"""Bitbucket Cloud pull_requests stream (incremental, per-repo cursor)."""

import logging
from typing import Any, Iterable, Mapping, MutableMapping, Optional

from airbyte_cdk.models import SyncMode
from airbyte_cdk.sources.streams.http import HttpSubStream

from source_bitbucket_cloud.streams.base import BitbucketCloudStream, _make_unique_key


logger = logging.getLogger("airbyte")


class PullRequestsStream(HttpSubStream, BitbucketCloudStream):
    """PRs for each repo; incremental by `updated_on`.

    Child streams (pr_comments, pr_commits) use this stream as their parent
    and re-iterate via HttpSubStream; the PRs HTTP responses are served from
    requests-cache (``use_cache=True``) on the re-iteration.
    """

    name = "pull_requests"
    cursor_field = "updated_on"
    use_cache = True
    state_checkpoint_interval = 500

    # PRs API doesn't accept a generic ``pagelen`` for big pages — keep 50.
    page_size = 50

    def __init__(
        self,
        parent,  # RepositoriesStream
        start_date: Optional[str] = None,
        **kwargs: Any,
    ) -> None:
        super().__init__(parent=parent, **kwargs)
        self._start_date = start_date
        self._stop_pagination: bool = False

    # ------------------------------------------------------------------
    # Path / params
    # ------------------------------------------------------------------

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None) -> str:
        repo = (stream_slice or {}).get("parent") or {}
        workspace = repo.get("workspace")
        slug = repo.get("slug")
        if not workspace or not slug:
            raise ValueError("pull_requests stream_slice requires parent.workspace and parent.slug")
        return f"repositories/{workspace}/{slug}/pullrequests"

    def request_params(
        self,
        stream_state: Optional[Mapping[str, Any]] = None,
        stream_slice: Optional[Mapping[str, Any]] = None,
        next_page_token: Optional[Mapping[str, Any]] = None,
    ) -> Mapping[str, Any]:
        if next_page_token:
            return {}
        return {
            "pagelen": str(self.page_size),
            "state": ["OPEN", "MERGED", "DECLINED", "SUPERSEDED"],
            "sort": "-updated_on",
        }

    def next_page_token(self, response):
        if self._stop_pagination:
            self._stop_pagination = False
            return None
        return super().next_page_token(response)

    # ------------------------------------------------------------------
    # Slices — attach cursor_value
    # ------------------------------------------------------------------

    def stream_slices(
        self,
        sync_mode: SyncMode,
        cursor_field: Optional[list] = None,
        stream_state: Optional[Mapping[str, Any]] = None,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        state = stream_state or {}
        slice_count = 0
        for parent_slice in super().stream_slices(
            sync_mode=sync_mode, cursor_field=cursor_field, stream_state=stream_state,
        ):
            repo = (parent_slice or {}).get("parent") or {}
            workspace = repo.get("workspace")
            slug = repo.get("slug")
            if not workspace or not slug:
                logger.warning(
                    f"pull_requests: skipping parent_slice missing workspace/slug: {parent_slice!r}"
                )
                continue
            partition_key = f"{workspace}/{slug}"
            cursor = (state.get(partition_key, {}) or {}).get(self.cursor_field, "") or ""
            # Reset per-slice so a prior early-exit doesn't leak into this repo.
            self._stop_pagination = False
            slice_count += 1
            logger.info(
                f"pull_requests: slice={partition_key} cursor={cursor or '<none>'} "
                f"start_date={self._start_date or '<none>'}"
            )
            yield {
                "parent": repo,
                "cursor_value": cursor,
                "partition_key": partition_key,
            }
        logger.info(f"pull_requests: iterated {slice_count} repo slices")

    # ------------------------------------------------------------------
    # Parse
    # ------------------------------------------------------------------

    def parse_response(
        self,
        response,
        stream_slice: Optional[Mapping[str, Any]] = None,
        **kwargs: Any,
    ):
        s = stream_slice or {}
        repo = s.get("parent") or {}
        workspace = repo.get("workspace", "")
        slug = repo.get("slug", "")
        cursor_value = s.get("cursor_value", "") or ""

        emitted = 0
        for pr in self._iter_values(response):
            pr_id = pr.get("id")
            updated_on = pr.get("updated_on", "") or ""

            # Incremental early exit (PRs are sorted -updated_on).
            if cursor_value and updated_on and updated_on <= cursor_value:
                self._stop_pagination = True
                logger.info(
                    f"pull_requests: {workspace}/{slug} cursor early-exit "
                    f"at pr={pr_id} updated_on={updated_on} cursor={cursor_value} "
                    f"(emitted {emitted} this page)"
                )
                return
            if self._start_date and updated_on and updated_on[:10] < self._start_date:
                self._stop_pagination = True
                logger.info(
                    f"pull_requests: {workspace}/{slug} start_date cutoff "
                    f"at pr={pr_id} updated_on={updated_on} (emitted {emitted} this page)"
                )
                return
            emitted += 1

            author = pr.get("author") or {}
            src_branch = (pr.get("source") or {}).get("branch") or {}
            dst_branch = (pr.get("destination") or {}).get("branch") or {}
            merge_commit = pr.get("merge_commit") or {}
            closed_by = pr.get("closed_by") or {}

            participants = []
            for p in pr.get("participants") or []:
                user = p.get("user") or {}
                participants.append({
                    "display_name": user.get("display_name"),
                    "uuid": user.get("uuid"),
                    "nickname": user.get("nickname"),
                    "role": p.get("role"),
                    "approved": p.get("approved", False),
                    "state": p.get("state"),
                })
            requested_reviewers = [
                {
                    "display_name": r.get("display_name"),
                    "uuid": r.get("uuid"),
                    "nickname": r.get("nickname"),
                }
                for r in (pr.get("reviewers") or [])
            ]

            record = {
                "unique_key": _make_unique_key(
                    self._tenant_id, self._source_id, workspace, slug, str(pr_id),
                ),
                "id": pr_id,
                "title": pr.get("title"),
                "description": pr.get("description"),
                "state": pr.get("state"),
                "created_on": pr.get("created_on"),
                "updated_on": updated_on,
                "author_display_name": author.get("display_name"),
                "author_uuid": author.get("uuid"),
                "author_nickname": author.get("nickname"),
                "source_branch": src_branch.get("name"),
                "destination_branch": dst_branch.get("name"),
                "merge_commit_hash": merge_commit.get("hash"),
                "close_source_branch": pr.get("close_source_branch"),
                "closed_by_display_name": closed_by.get("display_name"),
                "closed_by_uuid": closed_by.get("uuid"),
                "comment_count": pr.get("comment_count", 0),
                "task_count": pr.get("task_count", 0),
                "participants": participants,
                "requested_reviewers": requested_reviewers,
                "workspace": workspace,
                "repo_slug": slug,
            }
            yield self._envelope(record)

        logger.debug(f"pull_requests: {workspace}/{slug} page emitted={emitted}")

    # ------------------------------------------------------------------
    # State — per-repo cursor
    # ------------------------------------------------------------------

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        partition_key = f"{latest_record.get('workspace', '')}/{latest_record.get('repo_slug', '')}"
        record_cursor = latest_record.get(self.cursor_field, "") or ""
        entry = dict(current_stream_state.get(partition_key, {}) or {})
        prev = entry.get(self.cursor_field, "") or ""
        if record_cursor and record_cursor > prev:
            entry[self.cursor_field] = record_cursor
            current_stream_state[partition_key] = entry
        return current_stream_state

    # ------------------------------------------------------------------
    # Schema
    # ------------------------------------------------------------------

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
                "id": {"type": ["null", "integer"]},
                "title": {"type": ["null", "string"]},
                "description": {"type": ["null", "string"]},
                "state": {"type": ["null", "string"]},
                "created_on": {"type": ["null", "string"]},
                "updated_on": {"type": ["null", "string"]},
                "author_display_name": {"type": ["null", "string"]},
                "author_uuid": {"type": ["null", "string"]},
                "author_nickname": {"type": ["null", "string"]},
                "source_branch": {"type": ["null", "string"]},
                "destination_branch": {"type": ["null", "string"]},
                "merge_commit_hash": {"type": ["null", "string"]},
                "close_source_branch": {"type": ["null", "boolean"]},
                "closed_by_display_name": {"type": ["null", "string"]},
                "closed_by_uuid": {"type": ["null", "string"]},
                "comment_count": {"type": ["null", "integer"]},
                "task_count": {"type": ["null", "integer"]},
                "participants": {"type": ["null", "array"]},
                "requested_reviewers": {"type": ["null", "array"]},
                "workspace": {"type": "string"},
                "repo_slug": {"type": "string"},
            },
        }
