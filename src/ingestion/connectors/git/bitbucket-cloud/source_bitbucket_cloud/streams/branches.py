"""Bitbucket Cloud branches stream (full refresh, HttpSubStream of repositories)."""

import logging
from typing import Any, Mapping, Optional

from airbyte_cdk.sources.streams.http import HttpSubStream

from source_bitbucket_cloud.streams.base import BitbucketCloudStream, _make_unique_key

logger = logging.getLogger("airbyte")


class BranchesStream(HttpSubStream, BitbucketCloudStream):
    """Branches for each repository."""

    name = "branches"
    use_cache = True

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None) -> str:
        s = stream_slice or {}
        repo = s["parent"]
        return f"repositories/{repo['workspace']}/{repo['slug']}/refs/branches"

    def parse_response(
        self,
        response,
        stream_slice: Optional[Mapping[str, Any]] = None,
        **kwargs: Any,
    ):
        s = stream_slice or {}
        repo = s["parent"]
        workspace = repo["workspace"]
        slug = repo["slug"]
        default_branch_name = repo.get("mainbranch_name", "")
        repo_updated_on = repo.get("updated_on", "")
        emitted = 0

        for branch in self._iter_values(response):
            emitted += 1
            branch_name = branch.get("name", "")
            target = branch.get("target") or {}
            target_hash = target.get("hash", "")
            target_date = target.get("date", "")

            record = {
                "unique_key": _make_unique_key(
                    self._tenant_id, self._source_id, workspace, slug, branch_name,
                ),
                "name": branch_name,
                "target": target,
                "target_hash": target_hash,
                "target_date": target_date,
                "workspace": workspace,
                "repo_slug": slug,
                "mainbranch_name": default_branch_name,
                "default_branch_name": default_branch_name,
                "is_default": branch_name == default_branch_name,
                "updated_on": repo_updated_on,
            }
            yield self._envelope(record)

        logger.debug(
            f"branches: repo={workspace}/{slug} page_emitted={emitted}"
        )

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
                "name": {"type": ["null", "string"]},
                "target": {"type": ["null", "object"]},
                "target_hash": {"type": ["null", "string"]},
                "target_date": {"type": ["null", "string"]},
                "workspace": {"type": "string"},
                "repo_slug": {"type": "string"},
                "mainbranch_name": {"type": ["null", "string"]},
                "default_branch_name": {"type": ["null", "string"]},
                "is_default": {"type": ["null", "boolean"]},
                "updated_on": {"type": ["null", "string"]},
            },
        }
