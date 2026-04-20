"""Bitbucket Cloud commits stream (incremental, per-branch cursor).

Per-branch state: ``{ws/slug/branch: {date, head_sha}}``.

Three load-bearing optimizations (paired, not independent):

1. **HEAD-unchanged skip**: when stored head_sha == current HEAD, the branch
   is fully in sync — skip entirely (no API call).
2. **Force-push detection**: when stored head_sha != current HEAD, reset that
   branch's cursor to ``start_date`` and re-fetch. Catches rebases that
   preserve author_date (cursor alone would silently miss rewritten commits).
3. **Bloom filter cross-branch pagination-stop**: once a feature branch
   re-enters main's shared history, stop paginating. Bounded to ~17MB
   (10M shas × 0.1% FP). A false positive only stops pagination one page
   early; destination dedupes by unique_key so no correctness risk.

Default branch is iterated first within each repo so the bloom fills with
main's history before feature branches iterate.
"""

import logging
import re
from typing import Any, Iterable, List, Mapping, MutableMapping, Optional

from airbyte_cdk.models import SyncMode
from airbyte_cdk.sources.streams.http import HttpSubStream
from pybloom_live import BloomFilter

from source_bitbucket_cloud.streams.base import BitbucketCloudStream, _make_unique_key


logger = logging.getLogger("airbyte")

_AUTHOR_RAW_RE = re.compile(r"^(.*?)\s*<([^>]+)>\s*$")

_BLOOM_CAPACITY = 10_000_000
_BLOOM_ERROR_RATE = 0.001


class CommitsStream(HttpSubStream, BitbucketCloudStream):

    name = "commits"
    cursor_field = "date"
    use_cache = True
    state_checkpoint_interval = 1000

    def __init__(
        self,
        parent,
        start_date: Optional[str] = None,
        **kwargs: Any,
    ) -> None:
        super().__init__(parent=parent, **kwargs)
        self._start_date = start_date
        self._bloom: Optional[BloomFilter] = None
        self._current_repo_key: Optional[tuple] = None
        self._stop_pagination: bool = False

    # ------------------------------------------------------------------
    # Path
    # ------------------------------------------------------------------

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None) -> str:
        s = stream_slice or {}
        branch = s["parent"]
        return f"repositories/{branch['workspace']}/{branch['repo_slug']}/commits/{branch['name']}"

    def next_page_token(self, response):
        if self._stop_pagination:
            self._stop_pagination = False
            return None
        return super().next_page_token(response)

    # ------------------------------------------------------------------
    # Slices — reset at start of invocation, sort default-first per repo,
    #          apply HEAD-unchanged skip and force-push reset
    # ------------------------------------------------------------------

    def stream_slices(
        self,
        sync_mode: SyncMode,
        cursor_field: Optional[List[str]] = None,
        stream_state: Optional[Mapping[str, Any]] = None,
    ) -> Iterable[Optional[Mapping[str, Any]]]:
        # Reset per-invocation state. Critical when this stream is re-invoked
        # as a parent (file_changes) — otherwise the bloom is still populated
        # from the prior run and every SHA hits immediately.
        self._bloom = None
        self._current_repo_key = None
        self._stop_pagination = False
        logger.info(
            f"commits: stream_slices start sync_mode={sync_mode} "
            f"start_date={self._start_date or '<none>'} "
            f"state_entries={len(stream_state or {})}"
        )

        state = stream_state or {}

        buffer: List[Mapping[str, Any]] = []
        current_repo: Optional[tuple] = None

        for parent_slice in super().stream_slices(
            sync_mode=sync_mode, cursor_field=cursor_field, stream_state=stream_state,
        ):
            branch = parent_slice["parent"]
            repo_key = (branch["workspace"], branch["repo_slug"])
            if current_repo is not None and repo_key != current_repo:
                yield from self._emit_repo(buffer, state)
                buffer = []
            current_repo = repo_key
            buffer.append(parent_slice)

        if buffer:
            yield from self._emit_repo(buffer, state)

    def _emit_repo(
        self,
        branches: List[Mapping[str, Any]],
        state: Mapping[str, Any],
    ) -> Iterable[Mapping[str, Any]]:
        # Sort: default branch first so the bloom fills with main's history
        # before feature branches iterate.
        def sort_key(ps: Mapping[str, Any]) -> int:
            return 0 if ps["parent"].get("is_default") else 1

        branches = sorted(branches, key=sort_key)

        skipped_unchanged = 0
        for parent_slice in branches:
            branch = parent_slice["parent"]
            partition_key = f"{branch['workspace']}/{branch['repo_slug']}/{branch['name']}"
            stored = state.get(partition_key, {}) or {}
            stored_cursor = stored.get(self.cursor_field, "") or ""
            stored_head = stored.get("head_sha", "") or ""
            current_head = branch.get("target_hash", "") or ""
            current_head_date = branch.get("target_date", "") or ""

            # HEAD-unchanged skip — safe only when cursor has also reached HEAD's
            # commit date. A partial run stores head_sha per-record (optimistic),
            # so head-match alone isn't proof the branch is fully processed.
            if (
                stored_head
                and current_head
                and stored_head == current_head
                and current_head_date
                and stored_cursor
                and stored_cursor >= current_head_date
            ):
                skipped_unchanged += 1
                continue

            # Force-push detection — HEAD moved AND new HEAD's commit_date is
            # not newer than the stored cursor, which means normal pagination
            # from HEAD down to cursor won't reach the rewritten commits
            # (rebase preserved author_date). Reset cursor to re-fetch.
            # Normal push case: new HEAD's commit_date > stored_cursor →
            # pagination naturally walks from HEAD down to cursor, picking
            # up the new commits — no reset needed.
            if (
                stored_head
                and current_head
                and current_head != stored_head
                and current_head_date
                and stored_cursor
                and current_head_date <= stored_cursor
            ):
                logger.info(
                    f"Force-push detected on {partition_key} "
                    f"({stored_head[:8]}->{current_head[:8]}, "
                    f"head_date={current_head_date} ≤ cursor={stored_cursor}): "
                    f"resetting cursor"
                )
                stored_cursor = ""

            logger.info(
                f"commits: slice={partition_key} cursor={stored_cursor or '<none>'} "
                f"head={current_head[:8] if current_head else '<none>'} "
                f"is_default={branch.get('is_default', False)}"
            )
            yield {
                "parent": branch,
                "cursor_value": stored_cursor,
                "head_sha": current_head,
                "partition_key": partition_key,
            }

        if skipped_unchanged:
            logger.info(
                f"commits: {skipped_unchanged} branches skipped (HEAD unchanged) "
                f"in repo {branches[0]['parent']['workspace']}/"
                f"{branches[0]['parent']['repo_slug']}"
            )

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
        branch = s["parent"]
        workspace = branch["workspace"]
        slug = branch["repo_slug"]
        branch_name = branch["name"]
        default_branch = branch.get("default_branch_name", "") or ""
        head_sha = s.get("head_sha", "")
        cursor_value = s.get("cursor_value", "")

        repo_key = (workspace, slug)
        if repo_key != self._current_repo_key:
            logger.info(
                f"commits: new repo {workspace}/{slug} — resetting bloom filter"
            )
            self._bloom = BloomFilter(
                capacity=_BLOOM_CAPACITY, error_rate=_BLOOM_ERROR_RATE,
            )
            self._current_repo_key = repo_key

        hit_seen = False
        emitted = 0
        bloom_hits = 0
        for commit in self._iter_values(response):
            commit_hash = commit.get("hash", "") or ""
            commit_date = commit.get("date", "") or ""

            if cursor_value and commit_date and commit_date <= cursor_value:
                self._stop_pagination = True
                logger.info(
                    f"commits: {workspace}/{slug}/{branch_name} cursor early-exit "
                    f"at {commit_date} cursor={cursor_value} "
                    f"(page emitted={emitted} bloom_hits={bloom_hits})"
                )
                return

            if self._start_date and commit_date and commit_date[:10] < self._start_date:
                self._stop_pagination = True
                logger.info(
                    f"commits: {workspace}/{slug}/{branch_name} start_date cutoff "
                    f"at {commit_date} (page emitted={emitted} bloom_hits={bloom_hits})"
                )
                return

            if commit_hash and commit_hash in self._bloom:
                hit_seen = True
                bloom_hits += 1
                continue
            if commit_hash:
                self._bloom.add(commit_hash)
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

            parents = commit.get("parents") or []
            parent_hashes = [p.get("hash", "") for p in parents if p.get("hash")]

            record = {
                "unique_key": _make_unique_key(
                    self._tenant_id, self._source_id, workspace, slug, commit_hash,
                ),
                "hash": commit_hash,
                "message": commit.get("message"),
                "date": commit_date,
                "author_raw": author_raw,
                "author_name": author_name,
                "author_email": author_email,
                "author_display_name": author_user.get("display_name"),
                "author_uuid": author_user.get("uuid"),
                "author_nickname": author_user.get("nickname"),
                "parent_hashes": parent_hashes,
                "workspace": workspace,
                "repo_slug": slug,
                "branch_name": branch_name,
                "default_branch_name": default_branch,
                "head_sha": head_sha,
            }
            yield self._envelope(record)

        logger.debug(
            f"commits: {workspace}/{slug}/{branch_name} page emitted={emitted} "
            f"bloom_hits={bloom_hits}"
        )
        if hit_seen:
            self._stop_pagination = True
            logger.info(
                f"commits: {workspace}/{slug}/{branch_name} bloom hit — "
                f"stopping pagination (branch merged into already-seen history)"
            )

    # ------------------------------------------------------------------
    # State
    # ------------------------------------------------------------------

    def get_updated_state(
        self,
        current_stream_state: MutableMapping[str, Any],
        latest_record: Mapping[str, Any],
    ) -> MutableMapping[str, Any]:
        partition_key = (
            f"{latest_record.get('workspace', '')}/"
            f"{latest_record.get('repo_slug', '')}/"
            f"{latest_record.get('branch_name', '')}"
        )
        record_date = latest_record.get(self.cursor_field, "") or ""
        head_sha = latest_record.get("head_sha", "") or ""
        entry = dict(current_stream_state.get(partition_key, {}) or {})
        prev_date = entry.get(self.cursor_field, "") or ""
        if record_date and record_date > prev_date:
            entry[self.cursor_field] = record_date
        if head_sha:
            entry["head_sha"] = head_sha
        if entry:
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
                "hash": {"type": "string"},
                "message": {"type": ["null", "string"]},
                "date": {"type": ["null", "string"]},
                "author_raw": {"type": ["null", "string"]},
                "author_name": {"type": ["null", "string"]},
                "author_email": {"type": ["null", "string"]},
                "author_display_name": {"type": ["null", "string"]},
                "author_uuid": {"type": ["null", "string"]},
                "author_nickname": {"type": ["null", "string"]},
                "parent_hashes": {"type": ["null", "array"], "items": {"type": "string"}},
                "workspace": {"type": "string"},
                "repo_slug": {"type": "string"},
                "branch_name": {"type": "string"},
                "default_branch_name": {"type": ["null", "string"]},
                "head_sha": {"type": ["null", "string"]},
            },
        }
