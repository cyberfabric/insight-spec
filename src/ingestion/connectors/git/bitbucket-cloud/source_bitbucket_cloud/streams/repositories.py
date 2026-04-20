"""Bitbucket Cloud repositories stream (full refresh, per workspace)."""

import logging
from typing import Any, Iterable, Mapping, Optional

from source_bitbucket_cloud.streams.base import BitbucketCloudStream, _make_unique_key

logger = logging.getLogger("airbyte")


class RepositoriesStream(BitbucketCloudStream):
    """All repositories for each configured workspace."""

    name = "repositories"
    use_cache = True

    def __init__(
        self,
        workspaces: list[str],
        skip_forks: bool = True,
        **kwargs: Any,
    ) -> None:
        super().__init__(**kwargs)
        self._workspaces = workspaces
        self._skip_forks = skip_forks

    def stream_slices(self, **kwargs: Any) -> Iterable[Optional[Mapping[str, Any]]]:
        logger.info(
            f"repositories: {len(self._workspaces)} workspaces to fetch "
            f"(skip_forks={self._skip_forks})"
        )
        for workspace in self._workspaces:
            logger.info(f"repositories: starting workspace '{workspace}'")
            yield {"workspace": workspace}

    def _path(self, stream_slice: Optional[Mapping[str, Any]] = None) -> str:
        workspace = (stream_slice or {}).get("workspace")
        if not workspace:
            raise ValueError("repositories stream_slice requires 'workspace'")
        return f"repositories/{workspace}"

    def parse_response(
        self,
        response,
        stream_slice: Optional[Mapping[str, Any]] = None,
        **kwargs: Any,
    ):
        workspace = (stream_slice or {}).get("workspace", "")
        skipped = 0
        emitted = 0
        for repo in self._iter_values(response):
            if self._skip_forks and repo.get("parent"):
                skipped += 1
                continue
            emitted += 1

            slug = repo.get("slug", "")
            project = repo.get("project") or {}
            mainbranch = (repo.get("mainbranch") or {}).get("name", "")

            record = {
                "unique_key": _make_unique_key(self._tenant_id, self._source_id, workspace, slug),
                "workspace": workspace,
                "slug": slug,
                "name": repo.get("name"),
                "full_name": repo.get("full_name"),
                "uuid": repo.get("uuid"),
                "is_private": repo.get("is_private"),
                "description": repo.get("description"),
                "language": repo.get("language"),
                "size": repo.get("size"),
                "created_on": repo.get("created_on"),
                "updated_on": repo.get("updated_on"),
                "has_issues": repo.get("has_issues"),
                "has_wiki": repo.get("has_wiki"),
                "fork_policy": repo.get("fork_policy"),
                "mainbranch": repo.get("mainbranch"),
                "mainbranch_name": mainbranch,
                "project_key": project.get("key"),
                "project_name": project.get("name"),
            }
            yield self._envelope(record)

        logger.info(
            f"repositories: workspace={workspace} emitted={emitted} "
            f"skipped_forks={skipped}"
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
                "workspace": {"type": "string"},
                "slug": {"type": ["null", "string"]},
                "name": {"type": ["null", "string"]},
                "full_name": {"type": ["null", "string"]},
                "uuid": {"type": ["null", "string"]},
                "is_private": {"type": ["null", "boolean"]},
                "description": {"type": ["null", "string"]},
                "language": {"type": ["null", "string"]},
                "size": {"type": ["null", "integer"]},
                "created_on": {"type": ["null", "string"]},
                "updated_on": {"type": ["null", "string"]},
                "has_issues": {"type": ["null", "boolean"]},
                "has_wiki": {"type": ["null", "boolean"]},
                "fork_policy": {"type": ["null", "string"]},
                "mainbranch": {"type": ["null", "object"]},
                "mainbranch_name": {"type": ["null", "string"]},
                "project_key": {"type": ["null", "string"]},
                "project_name": {"type": ["null", "string"]},
            },
        }
