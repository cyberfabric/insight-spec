# Bitbucket Server Connector Specification# Bitbucket Connector Specification



> Version 1.0 — March 2026> Version 1.0 — March 2026

> Based on: Unified git data model (`docs/connectors/git/README.md`)> Based on: `docs/CONNECTORS_REFERENCE.md` Source 2 (Bitbucket)



Standalone specification for the Bitbucket Server/Data Center (Version Control) connector. Uses the unified `git_*` tables defined in `docs/connectors/git/README.md` with `data_source = "insight_bitbucket_server"`.Standalone specification for the Bitbucket (Version Control) connector. Expands Source 2 in the main Connector Reference with full table schemas, identity mapping, Silver/Gold pipeline notes, and open questions.



<!-- toc --><!-- toc -->



- [Overview](#overview)- [Overview](#overview)

- [Bronze Tables](#bronze-tables)- [Bronze Tables](#bronze-tables)

  - [Unified Git Tables](#unified-git-tables)  - [`bitbucket_repositories`](#bitbucketrepositories)

  - [`bitbucket_api_cache` — Optional API response cache](#bitbucket_api_cache-optional-api-response-cache)  - [`bitbucket_branches`](#bitbucketbranches)

- [API Details](#api-details)  - [`bitbucket_commits`](#bitbucketcommits)

  - [Base Configuration](#base-configuration)  - [`bitbucket_commit_files` — Per-file line changes](#bitbucketcommitfiles-per-file-line-changes)

  - [Key Endpoints](#key-endpoints)  - [`bitbucket_pull_requests`](#bitbucketpullrequests)

  - [Pagination Pattern](#pagination-pattern)  - [`bitbucket_pull_request_reviewers` — Reviewer list with status](#bitbucketpullrequestreviewers-reviewer-list-with-status)

- [Field Mapping to Unified Schema](#field-mapping-to-unified-schema)  - [`bitbucket_pull_request_comments`](#bitbucketpullrequestcomments)

  - [Repository Mapping](#repository-mapping)  - [`bitbucket_pull_request_commits`](#bitbucketpullrequestcommits)

  - [Commit Mapping](#commit-mapping)  - [`bitbucket_ticket_refs` — Ticket references extracted from PRs and commits](#bitbucketticketrefs-ticket-references-extracted-from-prs-and-commits)

  - [Pull Request Mapping](#pull-request-mapping)  - [`bitbucket_collection_runs` — Connector execution log](#bitbucketcollectionruns-connector-execution-log)

  - [PR Reviewer Mapping](#pr-reviewer-mapping)- [Identity Resolution](#identity-resolution)

  - [PR Comment Mapping](#pr-comment-mapping)- [Silver / Gold Mappings](#silver-gold-mappings)

- [Collection Strategy](#collection-strategy)- [Open Questions](#open-questions)

  - [Incremental Collection](#incremental-collection)  - [OQ-BB-1: `uuid` vs `account_id` as the canonical Bitbucket user identifier](#oq-bb-1-uuid-vs-accountid-as-the-canonical-bitbucket-user-identifier)

  - [Rate Limiting](#rate-limiting)  - [OQ-BB-2: Cross-source deduplication with GitHub/GitLab mirrors](#oq-bb-2-cross-source-deduplication-with-githubgitlab-mirrors)

  - [Error Handling](#error-handling)

- [Identity Resolution](#identity-resolution)<!-- /toc -->

- [Bitbucket-Specific Considerations](#bitbucket-specific-considerations)

- [Open Questions](#open-questions)---

  - [OQ-BB-1: Author name format handling](#oq-bb-1-author-name-format-handling)

  - [OQ-BB-2: API cache retention policy](#oq-bb-2-api-cache-retention-policy)## Overview

  - [OQ-BB-3: Participant vs Reviewer distinction](#oq-bb-3-participant-vs-reviewer-distinction)

**API**: Bitbucket REST v1/v2

<!-- /toc -->

**Category**: Version Control

---

**Authentication**: OAuth 2.0 (App passwords or Workspace access tokens)

## Overview

**Identity**: `author_email` (from `bitbucket_commits`) — resolved to canonical `person_id` via Identity Manager. Bitbucket users are identified internally by `uuid` and `account_id`; email takes precedence for cross-system resolution.

**API**: Bitbucket Server REST API v1.0

**Field naming**: snake_case — Bitbucket API uses snake_case; preserved as-is at Bronze level.

**Category**: Version Control

**Why multiple tables**: Same 1:N relational structure as GitHub — a commit has many files, a PR has many reviewers, comments, and commits. See `github.md` for the rationale; Bitbucket follows the same pattern with structural differences noted below.

**Authentication**: HTTP Basic Auth, Bearer Token, or Personal Access Token (PAT)

**Key differences from GitHub:**

**Data Source Identifier**: `data_source = "insight_bitbucket_server"`

| Aspect | GitHub | Bitbucket |

**Identity**: `author_email` (from commits) + `author_name` (Bitbucket username) — resolved to canonical `person_id` via Identity Manager. Email takes precedence; username is fallback when email is corporate-specific format or absent.|--------|--------|-----------|

| User identity | `login` (username) | `uuid` + `account_id` |

**Field naming**: Bitbucket uses camelCase in API responses (e.g., `displayId`, `authorTimestamp`) which are mapped to snake_case in the unified schema (`project_key`, `repo_slug`).| Namespace field | `owner` | `workspace` |

| PR review model | Formal reviews with `state` (`APPROVED` / `CHANGES_REQUESTED` / etc.) | Simple reviewer list with `status` (`APPROVED` / `UNAPPROVED` / `NEEDS_WORK`) |

**Why unified schema**: Bitbucket data is stored in the same `git_*` tables as GitHub and GitLab (defined in `docs/connectors/git/README.md`), using `data_source = "insight_bitbucket_server"` as the discriminator. This enables:| Comment severity | — | `severity`: `NORMAL` / `BLOCKER` (blocking comments must be resolved before merge) |

- Cross-platform analytics (e.g., "show all commits across GitHub and Bitbucket")| PR state values | `open` / `closed` / `merged` | `OPEN` / `MERGED` / `DECLINED` |

- Consistent identity resolution across git platforms| Draft PRs | `draft` boolean | Not supported |

- Simplified Silver/Gold layer transformations| Merged by | `merged_by_login` | Not returned by API |

- Deduplication when repositories are mirrored| Review comments | `comment_type` distinguishes general vs inline | All comments are the same kind |



> **Note**: Bitbucket Server's review model is simpler than GitHub's — reviewers can only `APPROVE` or `UNAPPROVE` (no `CHANGES_REQUESTED` or `COMMENTED` states). The unified schema accommodates both models via the `status` field normalization.---



---## Bronze Tables



## Bronze Tables### `bitbucket_repositories`



### Unified Git Tables| Field | Type | Description |

|-------|------|-------------|

Bitbucket data is stored in the following unified tables from `docs/connectors/git/README.md`:| `workspace` | String | Bitbucket workspace slug (replaces `owner`) |

| `repo_name` | String | Repository slug |

| Table | Purpose | Bitbucket Usage || `full_name` | String | Full path, e.g. `workspace/repo` |

|-------|---------|-----------------|| `description` | String | Repository description |

| `git_repositories` | Repository metadata | Stores projects and repos with `data_source = "insight_bitbucket_server"` || `is_private` | Int | 1 if private |

| `git_repositories_ext` | Extended repo properties | Optional: stores aggregated metrics (total LOC, contributor counts, etc.) || `language` | String | Primary programming language |

| `git_repository_branches` | Branch tracking for incremental sync | Tracks last collected commit per branch || `size` | Int | Repository size in KB |

| `git_commits` | Commit history | Stores commits from all branches || `created_at` | DateTime | Repository creation date |

| `git_commits_ext` | Extended commit properties | Optional: stores AI analysis, license scanning results || `updated_at` | DateTime | Last update |

| `git_commit_files` | Per-file line changes | Parsed from `/commits/{hash}/diff` endpoint || `pushed_at` | DateTime | Date of most recent push |

| `git_pull_requests` | PR metadata and lifecycle | Maps Bitbucket PRs with state normalization || `default_branch` | String | Default branch name |

| `git_pull_requests_ext` | Extended PR properties | Optional: stores review metrics, cycle time calculations || `is_empty` | Int | 1 if no commits |

| `git_pull_requests_reviewers` | Review submissions | Maps Bitbucket reviewers from PR activities || `metadata` | String (JSON) | Full API response |

| `git_pull_requests_comments` | PR comments (general + inline) | Combines comments from activities endpoint |

| `git_pull_requests_commits` | PR-to-commit junction table | Links PRs to their commits |---

| `git_tickets` | Ticket references (Jira, etc.) | Extracts Jira keys from PR titles/descriptions and commit messages |

| `git_collection_runs` | Connector execution log | Tracks ETL run statistics and status |### `bitbucket_branches`



**Reference**: See `docs/connectors/git/README.md` for complete table schemas, indexes, and field descriptions.| Field | Type | Description |

|-------|------|-------------|

**Key mapping differences**:| `workspace` | String | Bitbucket workspace slug |

- Bitbucket's `project.key` → `git_repositories.project_key`| `repo_name` | String | Repository slug |

- Bitbucket's `repo.slug` → `git_repositories.repo_slug`| `branch_name` | String | Branch name |

- GitHub's `owner` + `repo_name` maps to same fields for consistency| `is_default` | Int | 1 if default branch |

| `last_commit_hash` | String | Last collected commit — cursor for incremental sync |

---| `last_commit_date` | DateTime | Date of last commit |

| `last_checked_at` | DateTime | When this branch was last checked |

### `bitbucket_api_cache` — Optional API response cache

---

| Field | Type | Constraints | Description |

|-------|------|-------------|-------------|### `bitbucket_commits`

| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |

| `cache_key` | String | REQUIRED | Cache key derived from endpoint and parameters (e.g., `commits:PROJ:repo-slug:main`) || Field | Type | Description |

| `endpoint` | String | REQUIRED | API endpoint path (e.g., `/rest/api/1.0/projects/PROJ/repos/repo-slug/commits`) ||-------|------|-------------|

| `request_params` | String | REQUIRED | JSON-encoded request parameters (e.g., `{"until": "main", "limit": 100}`) || `workspace` | String | Bitbucket workspace slug |

| `response_body` | String | REQUIRED | Full API response body as JSON string || `repo_name` | String | Repository slug |

| `response_status` | Int64 | REQUIRED | HTTP status code (e.g., 200, 404, 500) || `commit_hash` | String | Git SHA-1 (40 chars) — primary key |

| `etag` | String | NULLABLE | ETag from response headers (for conditional requests) || `branch` | String | Branch where commit was found |

| `last_modified` | String | NULLABLE | Last-Modified header value || `author_name` | String | Commit author name |

| `cached_at` | DateTime64(3) | REQUIRED | When this response was cached || `author_email` | String | Author email — primary identity key |

| `expires_at` | DateTime64(3) | NULLABLE | Cache expiration timestamp (optional TTL) || `author_uuid` | String | Bitbucket user UUID of the author (if matched) |

| `hit_count` | Int64 | DEFAULT 0 | Number of times this cached response was used || `author_account_id` | String | Atlassian account ID of the author (if matched) |

| `data_source` | String | DEFAULT 'insight_bitbucket_server' | Source discriminator || `committer_name` | String | Committer name |

| `_version` | UInt64 | REQUIRED | Deduplication version || `committer_email` | String | Committer email |

| `message` | String | Commit message |

**Indexes**:| `date` | DateTime | Commit timestamp |

- `idx_cache_key`: `(cache_key, data_source)`| `parents` | String (JSON) | Parent commit hashes |

- `idx_endpoint`: `(endpoint)`| `files_changed` | Int | Number of files modified |

- `idx_expires_at`: `(expires_at)`| `lines_added` | Int | Total lines added |

| `lines_removed` | Int | Total lines removed |

**Purpose**: Optional performance optimization table for caching Bitbucket API responses. Reduces API calls for frequently accessed data (e.g., repository metadata, branch lists) and enables offline processing during API outages.| `is_merge_commit` | Int | 1 if merge commit |

| `language_breakdown` | String (JSON) | Lines per language |

**Cache key format**: `{endpoint_type}:{project_key}:{repo_slug}:{additional_params}`| `ai_percentage` | Float | AI-generated code estimate (0.0–1.0) |

| `ai_thirdparty_flag` | Int | 1 if AI-detected third-party code |

Examples:| `scancode_thirdparty_flag` | Int | 1 if license scanner detected third-party |

- `repos:PROJ:my-repo`| `metadata` | String (JSON) | Full API response |

- `commits:PROJ:my-repo:main:until=abc123`

- `pr:PROJ:my-repo:12345`---



**Usage pattern**:### `bitbucket_commit_files` — Per-file line changes

```sql

-- Check cache before API call| Field | Type | Description |

SELECT response_body, cached_at|-------|------|-------------|

FROM bitbucket_api_cache| `workspace` | String | Bitbucket workspace slug |

WHERE cache_key = 'repos:MYPROJ:my-repo'| `repo_name` | String | Repository slug |

  AND data_source = 'insight_bitbucket_server'| `commit_hash` | String | Parent commit |

  AND (expires_at IS NULL OR expires_at > NOW())| `file_path` | String | Full file path |

ORDER BY cached_at DESC| `file_extension` | String | File extension |

LIMIT 1;| `lines_added` | Int | Lines added in this file |

| `lines_removed` | Int | Lines removed in this file |

-- Store API response| `ai_thirdparty_flag` | Int | AI-detected third-party code |

INSERT INTO bitbucket_api_cache (| `scancode_thirdparty_flag` | Int | License scanner detected third-party |

  cache_key, endpoint, request_params, response_body, | `scancode_metadata` | String (JSON) | License and copyright info |

  response_status, cached_at, data_source, _version

) VALUES (---

  'repos:MYPROJ:my-repo',

  '/rest/api/1.0/projects/MYPROJ/repos/my-repo',### `bitbucket_pull_requests`

  '{}',

  '{"slug": "my-repo", "name": "My Repo", ...}',| Field | Type | Description |

  200,|-------|------|-------------|

  NOW(),| `workspace` | String | Bitbucket workspace slug |

  'insight_bitbucket_server',| `repo_name` | String | Repository slug |

  toUnixTimestamp64Milli(NOW())| `pr_number` | Int | PR number — unique per repo |

);| `title` | String | PR title |

```| `body` | String | PR description |

| `state` | String | `OPEN` / `MERGED` / `DECLINED` |

**Cache invalidation strategies**:| `author_uuid` | String | PR author Bitbucket UUID |

1. **TTL-based**: Set `expires_at` based on data volatility (e.g., repos: 24h, commits: 1h)| `author_account_id` | String | PR author Atlassian account ID |

2. **Event-based**: Invalidate on webhook events (PR merged, new commit)| `author_email` | String | Author email |

3. **Manual**: Periodic cache clearing for stale data| `head_branch` | String | Source branch |

4. **Conditional requests**: Use `etag`/`last_modified` for HTTP 304 Not Modified responses| `base_branch` | String | Target branch |

| `created_at` | DateTime | PR creation time |

**Note**: This table is Bitbucket-specific and optional. GitHub connector may use different caching strategy (e.g., GraphQL query result caching). The unified `git_*` tables do not require caching.| `updated_at` | DateTime | Last update |

| `merged_at` | DateTime | Merge time (NULL if not merged) |

---| `closed_at` | DateTime | Close time |

| `files_changed` | Int | Files modified |

## API Details| `lines_added` | Int | Lines added |

| `lines_removed` | Int | Lines removed |

### Base Configuration| `commit_count` | Int | Number of commits in PR |

| `comment_count` | Int | Number of comments |

**Base URL**: `https://git.company.com` (organization-specific)| `duration_seconds` | Int | Time from creation to close |

| `ticket_refs` | String (JSON) | Extracted issue / ticket IDs |

**API Base Path**: `/rest/api/1.0`

Note: `draft` and `merged_by_login` are not supported by the Bitbucket API.

**Authentication Headers**:

```http---

Authorization: Bearer {token}

Content-Type: application/json### `bitbucket_pull_request_reviewers` — Reviewer list with status

```

| Field | Type | Description |

**Alternative Authentication**:|-------|------|-------------|

- HTTP Basic Auth: `Authorization: Basic {base64(username:password)}`| `workspace` | String | Bitbucket workspace slug |

- Personal Access Token: `Authorization: Bearer {pat}`| `repo_name` | String | Repository slug |

| `pr_number` | Int | Parent PR |

---| `reviewer_uuid` | String | Reviewer Bitbucket UUID |

| `reviewer_account_id` | String | Reviewer Atlassian account ID |

### Key Endpoints| `reviewer_email` | String | Reviewer email — identity key |

| `status` | String | `APPROVED` / `UNAPPROVED` / `NEEDS_WORK` |

| Endpoint | Method | Purpose | Used For |

|----------|--------|---------|----------|Replaces `github_pull_request_reviews`. Bitbucket has no separate review state transitions — only current reviewer status.

| `/rest/api/1.0/projects` | GET | List all projects | Initial discovery |

| `/rest/api/1.0/projects/{project}/repos` | GET | List repositories in project | Repository collection |---

| `/rest/api/1.0/projects/{project}/repos/{repo}` | GET | Get repository details | Repository metadata |

| `/rest/api/1.0/projects/{project}/repos/{repo}/branches` | GET | List branches | Branch tracking |### `bitbucket_pull_request_comments`

| `/rest/api/1.0/projects/{project}/repos/{repo}/commits` | GET | List commits | Commit collection |

| `/rest/api/1.0/projects/{project}/repos/{repo}/commits/{hash}` | GET | Get commit details | Commit metadata || Field | Type | Description |

| `/rest/api/1.0/projects/{project}/repos/{repo}/commits/{hash}/diff` | GET | Get commit diff | File-level line changes ||-------|------|-------------|

| `/rest/api/1.0/projects/{project}/repos/{repo}/pull-requests` | GET | List pull requests | PR collection || `workspace` | String | Bitbucket workspace slug |

| `/rest/api/1.0/projects/{project}/repos/{repo}/pull-requests/{id}` | GET | Get PR details | PR metadata || `repo_name` | String | Repository slug |

| `/rest/api/1.0/projects/{project}/repos/{repo}/pull-requests/{id}/activities` | GET | Get PR activities | Reviews, comments, approvals || `pr_number` | Int | Parent PR |

| `/rest/api/1.0/projects/{project}/repos/{repo}/pull-requests/{id}/commits` | GET | Get PR commits | PR-to-commit linkage || `comment_id` | Int | Comment unique ID |

| `/rest/api/1.0/projects/{project}/repos/{repo}/pull-requests/{id}/changes` | GET | Get PR file changes | PR diffstat || `content` | String | Comment text (Markdown) |

| `author_uuid` | String | Comment author UUID |

---| `author_email` | String | Author email — identity key |

| `severity` | String | `NORMAL` / `BLOCKER` — BLOCKER comments must be resolved before merge |

### Pagination Pattern| `created_at` | DateTime | Creation timestamp |

| `updated_at` | DateTime | Last update timestamp |

All list endpoints use **server-side pagination**:| `file_path` | String | File path for inline comments (NULL for general) |

| `line_number` | Int | Line number for inline comments (NULL for general) |

**Query parameters**:

- `start` — Page start index (default: 0)Note: `comment_type` and `in_reply_to_id` are absent from the Bitbucket API; `severity` is Bitbucket-specific.

- `limit` — Page size (default: 25, recommended: 100, max: 1000)

---

**Response structure**:

```json### `bitbucket_pull_request_commits`

{

  "size": 25,| Field | Type | Description |

  "limit": 100,|-------|------|-------------|

  "isLastPage": false,| `workspace` | String | Bitbucket workspace slug |

  "start": 0,| `repo_name` | String | Repository slug |

  "nextPageStart": 100,| `pr_number` | Int | Parent PR |

  "values": [| `commit_hash` | String | Commit SHA |

    {/* item data */}| `commit_order` | Int | Order within PR (0-indexed) |

  ]

}---

```

### `bitbucket_ticket_refs` — Ticket references extracted from PRs and commits

**Pagination algorithm**:

```python| Field | Type | Description |

def paginate_endpoint(api_client, endpoint, **params):|-------|------|-------------|

    """Paginate through Bitbucket API endpoint."""| `external_ticket_id` | String | Ticket ID, e.g. `PROJ-123` |

    start = 0| `workspace` | String | Bitbucket workspace slug |

    limit = 100| `repo_name` | String | Repository slug |

    all_items = []| `pr_number` | Int | Associated PR (NULL if from commit) |

    | `commit_hash` | String | Associated commit (NULL if from PR) |

    while True:

        response = api_client.get(endpoint, params={---

            **params,

            'start': start,### `bitbucket_collection_runs` — Connector execution log

            'limit': limit

        })| Field | Type | Description |

        |-------|------|-------------|

        all_items.extend(response['values'])| `run_id` | String | Unique run identifier |

        | `started_at` | DateTime | Run start time |

        if response.get('isLastPage', True):| `completed_at` | DateTime | Run end time |

            break| `status` | String | `running` / `completed` / `failed` |

        | `repos_processed` | Int | Repositories processed |

        start = response['nextPageStart']| `commits_collected` | Int | Commits collected |

    | `prs_collected` | Int | PRs collected |

    return all_items| `api_calls` | Int | API calls made |

```| `errors` | Int | Errors encountered |

| `settings` | String (JSON) | Collection configuration (workspace, repos, lookback) |

---

Monitoring table — not an analytics source.

## Field Mapping to Unified Schema

---

### Repository Mapping

## Identity Resolution

**Bitbucket API** (`/rest/api/1.0/projects/{project}/repos/{repo}`) → **`git_repositories`**:

`author_email` in `bitbucket_commits` is the primary identity key — mapped to canonical `person_id` via Identity Manager in Silver step 2.

```python

{Bitbucket's internal identifiers — `uuid` and `account_id` (Atlassian account ID) — are not used for cross-system resolution. Email takes precedence. When email is absent, `uuid` may be used as a fallback if a Bitbucket-specific email lookup is implemented.

    # Primary keys

    'project_key': api_data['project']['key'],           # e.g., "MYPROJ"`reviewer_email` in `bitbucket_pull_request_reviewers` and `author_email` in `bitbucket_pull_request_comments` are resolved to `person_id` in the same Silver step 2.

    'repo_slug': api_data['slug'],                       # e.g., "my-repo"

    'repo_uuid': str(api_data.get('id')) or None,        # e.g., "368" (often null)---

    

    # Metadata## Silver / Gold Mappings

    'name': api_data['name'],                            # Display name

    'full_name': None,                                   # Not available in Bitbucket| Bronze table | Silver target | Status |

    'description': api_data.get('description'),          # May be null|-------------|--------------|--------|

    'is_private': 1 if not api_data.get('public') else 0,| `bitbucket_commits` | `class_commits` | Planned — stream not yet defined |

    | `bitbucket_pull_requests` | `class_pr_activity` | Planned — stream not yet defined |

    # Timestamps (not available in Bitbucket Server API)| `bitbucket_ticket_refs` | Cross-domain join → `class_task_tracker_activities.task_id` | Planned |

    'created_on': None,| `bitbucket_repositories` | *(reference table)* | No unified stream |

    'updated_on': None,| `bitbucket_branches` | *(reference table)* | No unified stream |

    | `bitbucket_commit_files` | *(granular detail)* | Available — no unified stream defined yet |

    # Platform-specific (not available)| `bitbucket_pull_request_reviewers` | *(review analytics)* | Available — no unified stream defined yet |

    'size': None,| `bitbucket_pull_request_comments` | *(review analytics)* | Available — no unified stream defined yet |

    'language': None,

    'has_issues': None,**Gold**: Same as GitHub — commit-level and PR-level Gold metrics derived from unified `class_commits` and `class_pr_activity` streams once defined.

    'has_wiki': None,

    ---

    # Bitbucket-specific

    'fork_policy': 'forkable' if api_data.get('forkable') else None,## Open Questions

    

    # System fields### OQ-BB-1: `uuid` vs `account_id` as the canonical Bitbucket user identifier

    'metadata': json.dumps(api_data),

    'data_source': 'insight_bitbucket_server',Bitbucket exposes both `uuid` (Bitbucket-native) and `account_id` (Atlassian platform ID, shared across Jira and Confluence). When email is unavailable, which identifier should be used as the identity fallback?

    '_version': int(time.time() * 1000)

}- `account_id` is more useful for Jira cross-referencing (same Atlassian platform)

```- `uuid` is the Bitbucket-native key used in the REST API



---### OQ-BB-2: Cross-source deduplication with GitHub/GitLab mirrors



### Commit MappingBitbucket repositories may be mirrors of GitHub repositories. The same `commit_hash` will arrive from both connectors.



**Bitbucket API** (`/rest/api/1.0/projects/{p}/repos/{r}/commits/{hash}`) → **`git_commits`**:- Same question as OQ-GH-1 — see `github.md` for full discussion.

- Decision applies equally to Bitbucket commits appearing in `class_commits`.

```python
{
    # Primary keys
    'project_key': project_key,
    'repo_slug': repo_slug,
    'commit_hash': api_data['id'],                       # Full SHA-1 (40 chars)
    'branch': branch_name,                               # From query context
    
    # Author information
    'author_name': api_data['author']['name'],           # e.g., "John.Smith"
    'author_email': api_data['author']['emailAddress'], # e.g., "john.smith@company.com"
    'committer_name': api_data['committer']['name'],
    'committer_email': api_data['committer']['emailAddress'],
    
    # Commit details
    'message': api_data['message'],
    'date': datetime.fromtimestamp(api_data['authorTimestamp'] / 1000),
    'parents': json.dumps([p['id'] for p in api_data.get('parents', [])]),
    
    # Statistics (from diff endpoint)
    'files_changed': len(diff_data.get('diffs', [])),
    'lines_added': calculate_lines_added(diff_data),
    'lines_removed': calculate_lines_removed(diff_data),
    'is_merge_commit': 1 if len(api_data.get('parents', [])) > 1 else 0,
    
    # System fields
    'metadata': json.dumps(api_data),
    'collected_at': datetime.now(),
    'data_source': 'insight_bitbucket_server',
    '_version': int(time.time() * 1000)
}
```

**Note**: Bitbucket author names often use dot-separated format (e.g., "John.Smith") which differs from GitHub's format. Identity resolution must handle this variation.

---

### Pull Request Mapping

**Bitbucket API** (`/rest/api/1.0/projects/{p}/repos/{r}/pull-requests/{id}`) → **`git_pull_requests`**:

```python
{
    # Primary keys
    'project_key': project_key,
    'repo_slug': repo_slug,
    'pr_id': api_data['id'],                             # Database ID
    'pr_number': api_data['id'],                         # Same as pr_id in Bitbucket
    
    # PR details
    'title': api_data['title'],
    'description': api_data.get('description', ''),
    'state': normalize_state(api_data['state']),         # OPEN/MERGED/DECLINED → OPEN/MERGED/DECLINED
    
    # Author information
    'author_name': api_data['author']['user']['name'],
    'author_uuid': str(api_data['author']['user']['id']),
    
    # Branch information
    'source_branch': api_data['fromRef']['displayId'],
    'destination_branch': api_data['toRef']['displayId'],
    
    # Timestamps
    'created_on': datetime.fromtimestamp(api_data['createdDate'] / 1000),
    'updated_on': datetime.fromtimestamp(api_data['updatedDate'] / 1000),
    'closed_on': datetime.fromtimestamp(api_data['closedDate'] / 1000) if api_data.get('closedDate') else None,
    
    # Merge information
    'merge_commit_hash': api_data.get('properties', {}).get('mergeCommit', {}).get('id'),
    
    # Statistics
    'commit_count': None,  # Populated from /pull-requests/{id}/commits
    'comment_count': None, # Populated from activities
    'task_count': None,    # Bitbucket-specific — populated from activities
    'files_changed': None, # Populated from /pull-requests/{id}/changes
    'lines_added': None,
    'lines_removed': None,
    
    # Calculated fields
    'duration_seconds': calculate_duration(api_data),
    
    # Ticket extraction
    'jira_tickets': extract_jira_tickets(api_data),
    
    # System fields
    'metadata': json.dumps(api_data),
    'collected_at': datetime.now(),
    'data_source': 'insight_bitbucket_server',
    '_version': int(time.time() * 1000)
}
```

**State normalization**:
- Bitbucket `OPEN` → `OPEN`
- Bitbucket `MERGED` → `MERGED`
- Bitbucket `DECLINED` → `DECLINED`

---

### PR Reviewer Mapping

**Bitbucket API** (`/rest/api/1.0/projects/{p}/repos/{r}/pull-requests/{id}/activities`) → **`git_pull_requests_reviewers`**:

Activities with `action` = `APPROVED` or `UNAPPROVED`, plus reviewers from PR details:

```python
{
    # Primary keys
    'project_key': project_key,
    'repo_slug': repo_slug,
    'pr_id': pr_id,
    
    # Reviewer information
    'reviewer_name': user_data['name'],                  # e.g., "bob"
    'reviewer_uuid': str(user_data['id']),
    'reviewer_email': user_data.get('emailAddress'),
    
    # Review status
    'status': api_data.get('status', 'UNAPPROVED'),     # APPROVED/UNAPPROVED
    'role': 'REVIEWER',
    'approved': 1 if api_data.get('status') == 'APPROVED' else 0,
    
    # Timestamp
    'reviewed_at': datetime.fromtimestamp(api_data['createdDate'] / 1000) if api_data.get('createdDate') else None,
    
    # System fields
    'metadata': json.dumps(api_data),
    'collected_at': datetime.now(),
    'data_source': 'insight_bitbucket_server',
    '_version': int(time.time() * 1000)
}
```

**Note**: Bitbucket tracks reviewers in two places:
1. PR `reviewers` array (from PR details) — current review status
2. Activities with `APPROVED`/`UNAPPROVED` actions — historical review events

The connector should merge both sources to ensure completeness.

---

### PR Comment Mapping

**Bitbucket API** (`/rest/api/1.0/projects/{p}/repos/{r}/pull-requests/{id}/activities`) → **`git_pull_requests_comments`**:

Activities with `action` = `COMMENTED`:

```python
{
    # Primary keys
    'project_key': project_key,
    'repo_slug': repo_slug,
    'pr_id': pr_id,
    'comment_id': comment_data['id'],
    
    # Comment content
    'content': comment_data['text'],
    
    # Author information
    'author_name': user_data['name'],
    'author_uuid': str(user_data['id']),
    'author_email': user_data.get('emailAddress'),
    
    # Timestamps
    'created_at': datetime.fromtimestamp(comment_data['createdDate'] / 1000),
    'updated_at': datetime.fromtimestamp(comment_data['updatedDate'] / 1000),
    
    # Bitbucket-specific fields
    'state': comment_data.get('state'),                  # OPEN/RESOLVED
    'severity': comment_data.get('severity'),            # NORMAL/BLOCKER
    'thread_resolved': 1 if comment_data.get('threadResolved') else 0,
    
    # Inline comment location (if applicable)
    'file_path': comment_data.get('anchor', {}).get('path'),
    'line_number': comment_data.get('anchor', {}).get('line'),
    
    # System fields
    'metadata': json.dumps(comment_data),
    'collected_at': datetime.now(),
    'data_source': 'insight_bitbucket_server',
    '_version': int(time.time() * 1000)
}
```

**Comment types**:
- **General comments**: `anchor` is null → `file_path` and `line_number` are NULL
- **Inline comments**: `anchor` contains file path and line → populated

---

## Collection Strategy

### Incremental Collection

**Principle**: Only fetch data that has changed since last collection run.

**Repository-level tracking**:
```sql
-- Get last update timestamp for repository
SELECT MAX(updated_on) as last_update
FROM git_pull_requests
WHERE project_key = 'MYPROJ'
  AND repo_slug = 'my-repo'
  AND data_source = 'insight_bitbucket_server';
```

**Branch-level tracking** (for commits):
```sql
-- Get last collected commit per branch
SELECT branch_name, last_commit_hash, last_commit_date
FROM git_repository_branches
WHERE project_key = 'MYPROJ'
  AND repo_slug = 'my-repo'
  AND data_source = 'insight_bitbucket_server';
```

**Collection algorithm**:
1. Fetch branches from `/branches` endpoint
2. For each branch:
   - Check `git_repository_branches.last_commit_hash`
   - Fetch commits until reaching last collected commit
   - Update `last_commit_hash` and `last_commit_date`
3. For PRs:
   - Fetch with `state=ALL`, `order=NEWEST`
   - Early exit when `updated_on` < last collected update
4. For each PR:
   - Check if PR already exists and `updated_on` hasn't changed → skip
   - Otherwise, collect full PR data (activities, commits, changes)

---

### Rate Limiting

**Bitbucket Server rate limits**: Typically not enforced by default, but may be configured by organization.

**Best practices**:
- Use `limit=100` for pagination (balance between API calls and response size)
- Implement exponential backoff on HTTP 429 (Too Many Requests)
- Add configurable sleep between requests (e.g., 100ms)

**Retry logic**:
```python
def api_call_with_retry(func, max_retries=3, base_delay=1):
    """Execute API call with exponential backoff retry."""
    for attempt in range(max_retries):
        try:
            return func()
        except requests.HTTPError as e:
            if e.response.status_code == 429:  # Rate limited
                delay = base_delay * (2 ** attempt)
                logger.warning(f"Rate limited, retrying in {delay}s...")
                time.sleep(delay)
            elif e.response.status_code >= 500:  # Server error
                delay = base_delay * (2 ** attempt)
                logger.error(f"Server error, retrying in {delay}s...")
                time.sleep(delay)
            else:
                raise
    
    raise Exception(f"Max retries ({max_retries}) exceeded")
```

---

### Error Handling

**Error categories**:

1. **Authentication errors** (401, 403):
   - Log error and halt collection
   - Notify operators of credential issues

2. **Not found errors** (404):
   - Log warning (repository/PR may have been deleted)
   - Continue with next item

3. **Server errors** (500, 502, 503):
   - Retry with exponential backoff
   - If persistent, log error and continue

4. **Malformed data**:
   - Log warning with API response
   - Skip malformed item
   - Continue collection

**Fault tolerance**:
- Checkpoint mechanism: Save progress after each repository
- Resume capability: Use `git_collection_runs` to track last processed repository
- Partial success: Mark run as `completed` even if some items failed (track error count)

---

## Identity Resolution

**Primary identity key**: `author_email` from commits and `reviewer_email` from reviews

**Bitbucket-specific considerations**:
- Email format is often corporate-specific (e.g., `john.smith@company.com`)
- Author name format uses dot-separation (e.g., `John.Smith`)
- User IDs are numeric (e.g., `152`, `660`)

**Resolution process**:
1. Extract email from `git_commits.author_email` and `git_pull_requests_reviewers.reviewer_email`
2. Normalize email (lowercase, trim)
3. Map to canonical `person_id` via Identity Manager
4. If email absent, attempt resolution by `author_name` with Bitbucket context
5. Fall back to `author_uuid` (Bitbucket user ID)

**Cross-source matching**: Same person may have:
- Bitbucket email: `john.smith@company.com`
- GitHub email: `john.smith@company.com` (same) or `jsmith@users.noreply.github.com` (different)
- Identity Manager uses email as primary key, resolves to single `person_id`

---

## Bitbucket-Specific Considerations

### Missing Metadata

Bitbucket Server API does **not** provide:
- Repository creation date (`created_on` = NULL)
- Repository size (`size` = NULL)
- Primary language detection (`language` = NULL)
- Issue tracker / wiki flags (`has_issues`, `has_wiki` = NULL)

These fields are nullable in the unified schema and will be NULL for Bitbucket sources.

### Task Count

Bitbucket supports inline **tasks** (checkboxes) in PR comments. This is tracked in `git_pull_requests.task_count` and is Bitbucket-specific (NULL for GitHub/GitLab).

### Review Model Differences

| Feature | Bitbucket | GitHub |
|---------|-----------|--------|
| Review states | `APPROVED`, `UNAPPROVED` | `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED` |
| Comment severity | `NORMAL`, `BLOCKER` | Not supported |
| Thread resolution | Supported | Supported (different model) |
| Required approvals | Server-enforced | Server-enforced |

The unified schema accommodates both models:
- `status` field accepts all possible values
- Platform-specific values (e.g., `severity`) are nullable

### PR Participants vs Reviewers

Bitbucket tracks:
- **Reviewers**: Users explicitly added as reviewers
- **Participants**: Users who commented/interacted with PR

Current schema only tracks **reviewers** in `git_pull_requests_reviewers`. Participants are implicit from `git_pull_requests_comments.author_name`.

---

## Open Questions

### OQ-BB-1: Author name format handling

Bitbucket author names use dot-separated format (`John.Smith`) while GitHub uses various formats (`johndoe`, `John Doe`).

**Question**: Should we normalize author names in Bronze layer or preserve as-is and normalize in Silver?

**Current approach**: Preserve as-is in Bronze, normalize in Silver identity resolution

**Consideration**: Dot-separated names may be corporate standard, normalizing could lose information

---

### OQ-BB-2: API cache retention policy

The optional `bitbucket_api_cache` table can grow unbounded without a retention policy.

**Question**: What is the recommended retention period for cached API responses?

**Options**:
1. **Short TTL** (1-4 hours) for volatile data (commits, PRs)
2. **Long TTL** (24 hours) for stable data (repositories, branches)
3. **Event-based invalidation** (webhook triggers)
4. **Periodic purge** (delete entries older than 7 days)

**Current approach**: No automatic expiration — manual cache management required

---

### OQ-BB-3: Participant vs Reviewer distinction

Bitbucket distinguishes between:
- **Reviewers**: Formally assigned to review PR
- **Participants**: Commented or interacted with PR

**Question**: Should we add a separate `git_pull_requests_participants` table or merge into `git_pull_requests_reviewers` with a `role` field?

**Current approach**: Only store reviewers in `git_pull_requests_reviewers`, participants are implicit from comments

**Consideration**: Participants data is useful for collaboration analysis but may duplicate comment authors

---
