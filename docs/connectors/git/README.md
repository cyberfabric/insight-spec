# Git Connector Specification (Multi-Source)

> Version 1.0 — March 2026
> Based on: Unified git data model for Bitbucket, GitHub, and GitLab

Data-source agnostic specification for Version Control connectors. Defines unified Silver schemas that work across Bitbucket Server, GitHub, GitLab, and custom git sources using a `data_source` discriminator column. Bronze-level raw API data is defined in source-specific connector specs (e.g., `bitbucket.md`, `github.md`).

<!-- toc -->

- [Overview](#overview)
- [Silver Tables](#silver-tables)
  - [`git_repositories`](#git_repositories)
  - [`git_repositories_ext` — Extended repository properties](#git_repositories_ext-extended-repository-properties)
  - [`git_repository_branches`](#git_repository_branches)
  - [`git_commits`](#git_commits)
  - [`git_commits_ext` — Extended commit properties](#git_commits_ext-extended-commit-properties)
  - [`git_commit_files` — Per-file line changes](#git_commit_files-per-file-line-changes)
  - [`git_pull_requests`](#git_pull_requests)
  - [`git_pull_requests_ext` — Extended PR properties](#git_pull_requests_ext-extended-pr-properties)
  - [`git_pull_requests_reviewers` — Review submissions and approvals](#git_pull_requests_reviewers-review-submissions-and-approvals)
  - [`git_pull_requests_comments`](#git_pull_requests_comments)
  - [`git_pull_requests_commits`](#git_pull_requests_commits)
  - [`git_tickets` — Ticket references extracted from PRs and commits](#git_tickets-ticket-references-extracted-from-prs-and-commits)
  - [`git_collection_runs` — Connector execution log](#git_collection_runs-connector-execution-log)
- [Data Source Support](#data-source-support)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver--gold-mappings)
- [Open Questions](#open-questions)
  - [OQ-GIT-1: Field naming standardization across sources](#oq-git-1-field-naming-standardization-across-sources)
  - [OQ-GIT-2: Handling source-specific features](#oq-git-2-handling-source-specific-features)
  - [OQ-GIT-3: Deduplication strategy for mirrored repositories](#oq-git-3-deduplication-strategy-for-mirrored-repositories)

<!-- /toc -->

---

## Overview

**Category**: Version Control

**Supported Sources**:
- Bitbucket Server (`data_source = "insight_bitbucket_server"`)
- GitHub (`data_source = "insight_github"`)
- GitLab (`data_source = "insight_gitlab"`)
- Custom ETL (`data_source = "custom_etl"`)

**Authentication**: 
- Bitbucket: HTTP Basic Auth or Personal Access Token
- GitHub: GitHub App installation token or Personal Access Token (PAT)
- GitLab: Personal Access Token or OAuth2

**Identity**: `author_email` (from commits) + `author_name`/`author_uuid` (source-specific username/ID) — resolved to canonical `person_id` via Identity Manager. Email takes precedence; username/UUID is fallback when email is absent or masked.

**Field naming**: Uses unified field names across all sources:
- Repository identification: `project_key` + `repo_slug`
- Primary keys: Auto-generated `id` column + composite natural keys
- Deduplication: `_version` column (UInt64 millisecond timestamp)

**Why multi-source design**: Organizations often use multiple git platforms (e.g., Bitbucket for internal, GitHub for open source) or mirror repositories across platforms. This unified schema enables:
- Single query across all git sources
- Consistent identity resolution regardless of source
- Global deduplication by `commit_hash`
- Simplified Gold layer transformation

**Source-specific fields**: Platform-specific features (e.g., GitHub's formal review states, Bitbucket's task count) are stored in the `metadata` JSON column and can be extracted in Gold layer if needed.

---

## Silver Tables

### `git_repositories`

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Organization/workspace/project key |
| `repo_slug` | String | REQUIRED | Repository name/slug |
| `repo_uuid` | String | NULLABLE | Source-specific unique ID (GitHub always populated, Bitbucket often null) |
| `name` | String | REQUIRED | Repository display name |
| `full_name` | String | NULLABLE | Full path (e.g., `org/repo` for GitHub) |
| `description` | String | NULLABLE | Repository description |
| `is_private` | Int64 | NULLABLE | 1 if private, 0 if public |
| `created_on` | DateTime64(3) | NULLABLE | Repository creation date (not available for Bitbucket Server) |
| `updated_on` | DateTime64(3) | NULLABLE | Last update timestamp |
| `size` | Int64 | NULLABLE | Repository size in KB (GitHub only) |
| `language` | String | NULLABLE | Primary programming language (GitHub only) |
| `has_issues` | Int64 | NULLABLE | 1 if issue tracker enabled (GitHub/GitLab) |
| `has_wiki` | Int64 | NULLABLE | 1 if wiki enabled (GitHub/GitLab) |
| `fork_policy` | String | NULLABLE | Fork policy (Bitbucket only) |
| `metadata` | String | REQUIRED | Full API response as JSON |
| `first_seen` | DateTime64(3) | NULLABLE | First time seen in our system |
| `last_updated` | DateTime64(3) | NULLABLE | Last time updated in our system |
| `last_commit_date` | DateTime64(3) | NULLABLE | Date of most recent commit |
| `last_commit_date_first_seen` | DateTime64(3) | NULLABLE | First time last_commit_date was observed |
| `last_commit_date_last_checked` | DateTime64(3) | NULLABLE | Last time last_commit_date was checked |
| `is_empty` | Int64 | NULLABLE | 1 if repository has no commits |
| `data_source` | String | DEFAULT '' | Source discriminator (insight_bitbucket_server, insight_github, insight_gitlab) |
| `_version` | UInt64 | REQUIRED | Deduplication version (millisecond timestamp) |

**Indexes**:
- `idx_repo_lookup`: `(project_key, repo_slug, data_source)`

**Source mapping**:
- **Bitbucket**: `project_key` ← `project.key`, `repo_slug` ← `slug`
- **GitHub**: `project_key` ← `owner.login`, `repo_slug` ← `name`
- **GitLab**: `project_key` ← `namespace.path`, `repo_slug` ← `path`

**Note**: Extended repository properties (aggregated statistics, analysis results, health metrics, etc.) are stored in the separate `git_repositories_ext` table to maintain schema flexibility.

---

### `git_repositories_ext` — Extended repository properties

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner — joins to `git_repositories.project_key` |
| `repo_slug` | String | REQUIRED | Repository name — joins to `git_repositories.repo_slug` |
| `property_key` | String | REQUIRED | Property name (e.g., `total_loc`, `active_contributors_30d`, `code_health_score`) |
| `property_value` | String | REQUIRED | Property value (stored as string, can be JSON for complex values) |
| `property_type` | String | REQUIRED | Value type hint: `string`, `number`, `boolean`, `json` |
| `collected_at` | DateTime64(3) | REQUIRED | When this property was collected/computed |
| `data_source` | String | DEFAULT '' | Source discriminator — joins to `git_repositories.data_source` |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_repo_ext_lookup`: `(project_key, repo_slug, property_key, data_source)`
- `idx_repo_property_key`: `(property_key)`

**Purpose**: Flexible key-value table for storing extended repository properties without modifying the core `git_repositories` schema. Enables addition of aggregated statistics, analysis results, and health metrics computed from commit/PR history without schema migrations.

**Common property keys**:

**Code statistics**:
- `total_loc` — Total lines of code across all files — type: `number`
- `total_files` — Total number of files in repository — type: `number`
- `language_breakdown` — Distribution of languages, e.g. `{"TypeScript": 45.2, "Python": 32.1, "Go": 22.7}` (percentages) — type: `json`
- `loc_by_language` — Lines of code per language, e.g. `{"TypeScript": 12450, "Python": 8920}` — type: `json`
- `binary_files_count` — Number of binary files — type: `number`
- `documentation_coverage` — Percentage of code with documentation — type: `number`

**Activity metrics**:
- `active_contributors_30d` — Number of unique contributors in last 30 days — type: `number`
- `active_contributors_90d` — Number of unique contributors in last 90 days — type: `number`
- `total_contributors` — Total unique contributors all-time — type: `number`
- `commit_frequency_30d` — Average commits per day in last 30 days — type: `number`
- `pr_frequency_30d` — Average PRs per day in last 30 days — type: `number`
- `last_activity_date` — Date of last commit or PR — type: `string` (ISO date)

**Quality metrics**:
- `code_health_score` — Overall code health score (0.0–100.0) — type: `number`
- `test_coverage_percentage` — Average test coverage across codebase — type: `number`
- `complexity_score` — Average code complexity metric — type: `number`
- `technical_debt_ratio` — Ratio of technical debt to total code — type: `number`
- `code_duplication_percentage` — Percentage of duplicated code — type: `number`
- `security_vulnerabilities_count` — Number of known security vulnerabilities — type: `number`
- `license_compliance_score` — License compliance score (0.0–100.0) — type: `number`

**AI analysis**:
- `ai_generated_percentage` — Estimated percentage of AI-generated code — type: `number`
- `third_party_code_percentage` — Percentage of third-party code — type: `number`
- `third_party_licenses` — List of detected third-party licenses — type: `json`

**Repository health**:
- `is_archived` — Repository is archived (0 or 1) — type: `boolean`
- `is_stale` — No activity in last 90 days (0 or 1) — type: `boolean`
- `is_monorepo` — Repository is a monorepo (0 or 1) — type: `boolean`
- `primary_framework` — Main framework/stack detected (e.g., "React", "Django") — type: `string`
- `deployment_frequency_30d` — Deployments per day in last 30 days — type: `number`
- `mean_time_to_recovery` — Average time to fix production issues (hours) — type: `number`

**Collaboration metrics**:
- `avg_pr_cycle_time_hours` — Average PR cycle time in hours — type: `number`
- `avg_review_depth_score` — Average review quality score — type: `number`
- `bus_factor` — Number of people needed to lose to stall project — type: `number`
- `contributor_diversity_score` — Distribution evenness of contributions (0.0–1.0) — type: `number`

**Trend data**:
- `loc_trend_30d` — LOC change over last 30 days — type: `json` (time series)
- `contributor_trend_90d` — Contributor count trend over last 90 days — type: `json` (time series)
- `velocity_trend_30d` — Commit/PR velocity trend — type: `json` (time series)

**Usage example**:
```sql
-- Get total LOC for a specific repository
SELECT property_value 
FROM git_repositories_ext 
WHERE project_key = 'MyOrg' 
  AND repo_slug = 'my-repo'
  AND property_key = 'total_loc'
  AND data_source = 'insight_github';

-- Get language breakdown for all repositories in an org
SELECT r.repo_slug, ext.property_value as language_breakdown
FROM git_repositories r
JOIN git_repositories_ext ext 
  ON r.project_key = ext.project_key 
  AND r.repo_slug = ext.repo_slug
  AND r.data_source = ext.data_source
WHERE r.project_key = 'MyOrg'
  AND ext.property_key = 'language_breakdown';

-- Find all stale repositories
SELECT r.project_key, r.repo_slug, r.last_commit_date
FROM git_repositories r
JOIN git_repositories_ext ext 
  ON r.project_key = ext.project_key 
  AND r.repo_slug = ext.repo_slug
  AND r.data_source = ext.data_source
WHERE ext.property_key = 'is_stale'
  AND ext.property_value = '1';

-- Get code health metrics for active repos
SELECT 
  r.repo_slug,
  MAX(CASE WHEN ext.property_key = 'code_health_score' THEN ext.property_value END) as health_score,
  MAX(CASE WHEN ext.property_key = 'test_coverage_percentage' THEN ext.property_value END) as test_coverage,
  MAX(CASE WHEN ext.property_key = 'complexity_score' THEN ext.property_value END) as complexity
FROM git_repositories r
JOIN git_repositories_ext ext 
  ON r.project_key = ext.project_key 
  AND r.repo_slug = ext.repo_slug
  AND r.data_source = ext.data_source
WHERE r.is_empty = 0
  AND ext.property_key IN ('code_health_score', 'test_coverage_percentage', 'complexity_score')
GROUP BY r.repo_slug;
```

**Design rationale**: 
- **Aggregated metrics**: Store computed statistics that would be expensive to calculate on-demand
- **Time-series data**: Track trends without schema changes
- **Periodic updates**: Metrics can be recomputed daily/weekly via `collected_at` timestamp
- **Flexibility**: Add new health metrics as analysis capabilities evolve
- **Efficiency**: Pre-computed values enable fast dashboard queries
- **Historical tracking**: Multiple `collected_at` values show metric evolution over time

---

### `git_repository_branches`

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `branch_name` | String | REQUIRED | Branch name |
| `is_default` | Int64 | REQUIRED | 1 if default branch, 0 otherwise |
| `last_commit_hash` | String | NULLABLE | Last commit collected from this branch — cursor for incremental sync |
| `last_commit_date` | DateTime64(3) | NULLABLE | Date of last commit |
| `last_checked_at` | String | NULLABLE | Last time this branch was checked (millisecond timestamp string) |
| `metadata` | String | NULLABLE | Branch metadata as JSON |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_branch_lookup`: `(project_key, repo_slug, branch_name, data_source)`

**Purpose**: Track branch state for incremental collection. The `last_commit_hash` serves as a cursor — only commits after this hash need to be fetched on subsequent runs.

---

### `git_commits`

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `commit_hash` | String | REQUIRED | Git SHA-1 hash (40 characters) — natural deduplication key |
| `branch` | String | NULLABLE | Branch where commit was found |
| `author_name` | String | REQUIRED | Commit author name |
| `author_email` | String | REQUIRED | Author email — primary identity key for cross-system resolution |
| `committer_name` | String | REQUIRED | Committer name |
| `committer_email` | String | REQUIRED | Committer email |
| `message` | String | REQUIRED | Commit message |
| `date` | DateTime64(3) | REQUIRED | Commit timestamp |
| `parents` | String | REQUIRED | JSON array of parent commit hashes — length > 1 indicates merge commit |
| `files_changed` | Int64 | NULLABLE | Number of files modified |
| `lines_added` | Int64 | NULLABLE | Total lines added |
| `lines_removed` | Int64 | NULLABLE | Total lines removed |
| `is_merge_commit` | Int64 | NULLABLE | 1 if merge commit (multiple parents), 0 otherwise |
| `metadata` | String | REQUIRED | Full API response as JSON |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_commit_lookup`: `(project_key, repo_slug, commit_hash, data_source)`
- `idx_commit_date`: `(date)`

**Deduplication**: Same `commit_hash` may appear from multiple sources if repository is mirrored. The `data_source` column distinguishes records, but analytics should typically `COUNT(DISTINCT commit_hash)` to avoid double-counting.

**Note**: Extended commit properties (AI analysis, license scanning, language breakdown, etc.) are stored in the separate `git_commits_ext` table to maintain schema flexibility.

---

### `git_commits_ext` — Extended commit properties

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner — joins to `git_commits.project_key` |
| `repo_slug` | String | REQUIRED | Repository name — joins to `git_commits.repo_slug` |
| `commit_hash` | String | REQUIRED | Commit SHA — joins to `git_commits.commit_hash` |
| `property_key` | String | REQUIRED | Property name (e.g., `ai_percentage`, `scancode_metadata`, `language_breakdown`) |
| `property_value` | String | REQUIRED | Property value (stored as string, can be JSON for complex values) |
| `property_type` | String | REQUIRED | Value type hint: `string`, `number`, `boolean`, `json` |
| `collected_at` | DateTime64(3) | REQUIRED | When this property was collected/computed |
| `data_source` | String | DEFAULT '' | Source discriminator — joins to `git_commits.data_source` |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_commit_ext_lookup`: `(project_key, repo_slug, commit_hash, property_key, data_source)`
- `idx_property_key`: `(property_key)`

**Purpose**: Flexible key-value table for storing extended commit properties without modifying the core `git_commits` schema. Enables addition of new analysis results (AI detection, license scanning, security analysis, code quality metrics) without schema migrations.

**Common property keys**:
- `ai_percentage` — AI-generated code estimate (0.0–1.0) — type: `number`
- `ai_thirdparty_flag` — AI-detected third-party code (0 or 1) — type: `boolean`
- `ai_thirdparty_repos` — Third-party repository detection metadata — type: `json`
- `scancode_metadata` — License and copyright scanning results — type: `json`
- `scancode_thirdparty_flag` — License scanner detected third-party (0 or 1) — type: `boolean`
- `language_breakdown` — Lines per language, e.g. `{"TypeScript": 120, "Python": 45}` — type: `json`
- `hash_sum` — Deduplication hash for multi-file commits — type: `string`
- `security_scan_results` — Security vulnerability scan results — type: `json`
- `code_quality_score` — Static analysis quality score — type: `number`
- `test_coverage_delta` — Change in test coverage from this commit — type: `number`

**Usage example**:
```sql
-- Get AI percentage for a specific commit
SELECT property_value 
FROM git_commits_ext 
WHERE commit_hash = 'abc123...' 
  AND property_key = 'ai_percentage'
  AND data_source = 'insight_github';

-- Get all language breakdowns for commits in a repo
SELECT commit_hash, property_value as language_breakdown
FROM git_commits_ext
WHERE project_key = 'MyOrg'
  AND repo_slug = 'my-repo'
  AND property_key = 'language_breakdown';
```

**Design rationale**: 
- **Flexibility**: Add new properties without schema changes
- **Efficiency**: Query only needed properties via index on `property_key`
- **Versioning**: Track when each property was computed via `collected_at`
- **Normalization**: Avoid wide table with many NULL values
- **Evolution**: Properties can be deprecated or renamed without data migration

---

### `git_commit_files` — Per-file line changes

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `commit_hash` | String | REQUIRED | Parent commit SHA — joins to `git_commits.commit_hash` |
| `diff_hash` | String | REQUIRED | SHA-256 hash of diff content for deduplication |
| `file_path` | String | REQUIRED | Full file path |
| `file_extension` | String | NULLABLE | File extension (e.g., "py", "java", "ts") |
| `lines_added` | Int64 | NULLABLE | Lines added in this file |
| `lines_removed` | Int64 | NULLABLE | Lines removed in this file |
| `ai_thirdparty_flag` | UInt8 | DEFAULT 0 | AI-detected third-party code flag (0 or 1) |
| `scancode_thirdparty_flag` | UInt8 | DEFAULT 0 | License scanner detected third-party flag (0 or 1) |
| `scancode_metadata` | String | NULLABLE | License and copyright info as JSON |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | REQUIRED | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_file_lookup`: `(project_key, repo_slug, commit_hash, file_path, data_source)`

**Purpose**: Granular file-level analysis for commit impact. Enables queries like "show all changes to authentication files" or "calculate churn per directory."

---

### `git_pull_requests`

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `pr_id` | Int64 | REQUIRED | PR database ID from source API |
| `pr_number` | Int64 | REQUIRED | PR display number (user-facing) |
| `title` | String | REQUIRED | PR title |
| `description` | String | NULLABLE | PR body/description (Markdown) |
| `state` | String | REQUIRED | PR state — normalized to: `OPEN`, `MERGED`, `CLOSED`, `DECLINED` |
| `author_name` | String | REQUIRED | PR author username |
| `author_uuid` | String | REQUIRED | Author unique identifier from source |
| `created_on` | DateTime64(3) | REQUIRED | PR creation timestamp |
| `updated_on` | DateTime64(3) | REQUIRED | Last update timestamp |
| `closed_on` | DateTime64(3) | NULLABLE | Close/merge timestamp (NULL if still open) |
| `merge_commit_hash` | String | NULLABLE | Hash of merge commit (NULL if not merged) |
| `source_branch` | String | REQUIRED | Source/head branch name |
| `destination_branch` | String | REQUIRED | Target/base branch name |
| `commit_count` | Int64 | NULLABLE | Number of commits in PR |
| `comment_count` | Int64 | NULLABLE | Number of general discussion comments |
| `task_count` | Int64 | NULLABLE | Number of tasks (Bitbucket only — NULL for GitHub/GitLab) |
| `files_changed` | Int64 | NULLABLE | Number of files modified |
| `lines_added` | Int64 | NULLABLE | Total lines added |
| `lines_removed` | Int64 | NULLABLE | Total lines removed |
| `duration_seconds` | Int64 | NULLABLE | Time from creation to close in seconds |
| `jira_tickets` | String | NULLABLE | JSON array of extracted Jira ticket IDs, e.g. `["PROJ-123", "PROJ-456"]` |
| `metadata` | String | REQUIRED | Full API response as JSON |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_pr_lookup`: `(project_key, repo_slug, pr_id, data_source)`
- `idx_pr_updated`: `(updated_on)`
- `idx_pr_state`: `(state)`

**State normalization**:
- Bitbucket: `OPEN`, `MERGED`, `DECLINED` → maps directly
- GitHub: `open` → `OPEN`, `closed` + `merged=true` → `MERGED`, `closed` + `merged=false` → `CLOSED`
- GitLab: `opened` → `OPEN`, `merged` → `MERGED`, `closed` → `CLOSED`

**Note**: Extended PR properties (AI analysis, review metrics, quality scores, etc.) are stored in the separate `git_pull_requests_ext` table to maintain schema flexibility.

---

### `git_pull_requests_ext` — Extended PR properties

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner — joins to `git_pull_requests.project_key` |
| `repo_slug` | String | REQUIRED | Repository name — joins to `git_pull_requests.repo_slug` |
| `pr_id` | Int64 | REQUIRED | PR database ID — joins to `git_pull_requests.pr_id` |
| `property_key` | String | REQUIRED | Property name (e.g., `review_depth_score`, `ai_generated_percentage`, `cycle_time_hours`) |
| `property_value` | String | REQUIRED | Property value (stored as string, can be JSON for complex values) |
| `property_type` | String | REQUIRED | Value type hint: `string`, `number`, `boolean`, `json` |
| `collected_at` | DateTime64(3) | REQUIRED | When this property was collected/computed |
| `data_source` | String | DEFAULT '' | Source discriminator — joins to `git_pull_requests.data_source` |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_pr_ext_lookup`: `(project_key, repo_slug, pr_id, property_key, data_source)`
- `idx_pr_property_key`: `(property_key)`

**Purpose**: Flexible key-value table for storing extended PR properties without modifying the core `git_pull_requests` schema. Enables addition of new analysis results (review quality metrics, AI-assisted PR detection, security analysis, complexity scores) without schema migrations.

**Common property keys**:
- `review_depth_score` — Quality/depth of code review (0.0–1.0) — type: `number`
- `review_participation_ratio` — Percentage of team members who reviewed — type: `number`
- `ai_generated_percentage` — Estimated AI-generated code in PR (0.0–1.0) — type: `number`
- `ai_assisted_pr_flag` — PR created/assisted by AI tools (0 or 1) — type: `boolean`
- `cycle_time_hours` — Time from first commit to merge in hours — type: `number`
- `pickup_time_hours` — Time from PR creation to first review in hours — type: `number`
- `rework_ratio` — Ratio of rework commits to total commits — type: `number`
- `approval_velocity` — Average time to approval in hours — type: `number`
- `complexity_score` — Code complexity metric — type: `number`
- `security_scan_results` — Security vulnerability scan results — type: `json`
- `test_coverage_delta` — Change in test coverage from this PR — type: `number`
- `breaking_change_flag` — PR contains breaking changes (0 or 1) — type: `boolean`
- `hotfix_flag` — PR is a hotfix (0 or 1) — type: `boolean`
- `docs_only_flag` — PR only changes documentation (0 or 1) — type: `boolean`
- `draft_pr_flag` — PR was created as draft (GitHub-specific, 0 or 1) — type: `boolean`
- `diffstat_metadata` — Detailed file-level diff statistics — type: `json`

**Usage example**:
```sql
-- Get review depth score for a specific PR
SELECT property_value 
FROM git_pull_requests_ext 
WHERE pr_id = 12345 
  AND property_key = 'review_depth_score'
  AND data_source = 'insight_github';

-- Get cycle time for all merged PRs in a repo
SELECT pr.pr_number, pr.title, ext.property_value as cycle_time_hours
FROM git_pull_requests pr
JOIN git_pull_requests_ext ext 
  ON pr.pr_id = ext.pr_id 
  AND pr.data_source = ext.data_source
WHERE pr.project_key = 'MyOrg'
  AND pr.repo_slug = 'my-repo'
  AND pr.state = 'MERGED'
  AND ext.property_key = 'cycle_time_hours';

-- Find all hotfix PRs
SELECT pr.pr_number, pr.title, pr.created_on
FROM git_pull_requests pr
JOIN git_pull_requests_ext ext 
  ON pr.pr_id = ext.pr_id 
  AND pr.data_source = ext.data_source
WHERE ext.property_key = 'hotfix_flag'
  AND ext.property_value = '1';
```

**Design rationale**: 
- **Flexibility**: Add new PR metrics without schema changes
- **Source-specific features**: Store platform-specific properties (e.g., GitHub's `draft` flag, Bitbucket's `task_count`) without NULLs in main table
- **Computed metrics**: Store calculated metrics (review velocity, complexity) alongside raw data
- **Efficiency**: Query only needed properties via index on `property_key`
- **Versioning**: Track when each metric was computed via `collected_at`
- **Evolution**: Metrics can be recalculated or redefined without data migration

---

### `git_pull_requests_reviewers` — Review submissions and approvals

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `pr_id` | Int64 | REQUIRED | Parent PR ID — joins to `git_pull_requests.pr_id` |
| `reviewer_name` | String | REQUIRED | Reviewer username |
| `reviewer_uuid` | String | REQUIRED | Reviewer unique identifier |
| `reviewer_email` | String | NULLABLE | Reviewer email — identity key (NULL when not available) |
| `status` | String | REQUIRED | Review status — normalized to: `APPROVED`, `UNAPPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED` |
| `role` | String | REQUIRED | Reviewer role (always "REVIEWER" in current implementation) |
| `approved` | Int64 | REQUIRED | 1 if approved, 0 if not |
| `reviewed_at` | DateTime64(3) | NULLABLE | Review submission timestamp (NULL when not available) |
| `metadata` | String | REQUIRED | Review metadata as JSON |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_reviewer_lookup`: `(project_key, repo_slug, pr_id, reviewer_uuid, data_source)`

**Status normalization**:
- Bitbucket: `APPROVED`, `UNAPPROVED`
- GitHub: `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED` (GitHub's formal review model)
- GitLab: `APPROVED`, `UNAPPROVED` (approval-only model)

**Note**: GitHub's review model is more granular. The `metadata` field preserves source-specific details for platform-specific analytics.

---

### `git_pull_requests_comments`

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `pr_id` | Int64 | REQUIRED | Parent PR ID |
| `comment_id` | Int64 | REQUIRED | Comment unique ID from API |
| `content` | String | REQUIRED | Comment text/body (Markdown supported) |
| `author_name` | String | REQUIRED | Comment author username |
| `author_uuid` | String | NULLABLE | Author unique identifier |
| `author_email` | String | NULLABLE | Author email — identity key |
| `created_at` | DateTime64(3) | REQUIRED | Comment creation timestamp |
| `updated_at` | DateTime64(3) | REQUIRED | Last update timestamp |
| `state` | String | NULLABLE | Thread state (Bitbucket: `OPEN`/`RESOLVED`, GitHub: NULL) |
| `severity` | String | NULLABLE | Comment severity (Bitbucket: `NORMAL`/`BLOCKER`, GitHub: NULL) |
| `thread_resolved` | Int64 | NULLABLE | 1 if thread resolved (Bitbucket only) |
| `file_path` | String | NULLABLE | File path for inline code review comments (NULL for general comments) |
| `line_number` | Int64 | NULLABLE | Line number for inline comments (NULL for general comments) |
| `metadata` | String | REQUIRED | Comment metadata as JSON |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_comment_lookup`: `(project_key, repo_slug, pr_id, comment_id, data_source)`

**Comment types**:
- **General comments**: Discussion on the PR as a whole (`file_path` and `line_number` are NULL)
- **Inline comments**: Code review comments on specific lines (`file_path` and `line_number` populated)

---

### `git_pull_requests_commits`

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `pr_id` | Int64 | REQUIRED | Parent PR ID |
| `commit_hash` | String | REQUIRED | Commit SHA — joins to `git_commits.commit_hash` |
| `commit_order` | Int64 | REQUIRED | Order of commit within PR (0-indexed) |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_pr_commit_lookup`: `(project_key, repo_slug, pr_id, commit_hash, data_source)`

**Purpose**: Junction table linking PRs to commits. A commit may appear in multiple PRs if cherry-picked or merged across branches. This table preserves the many-to-many relationship.

---

### `git_tickets` — Ticket references extracted from PRs and commits

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `external_ticket_id` | String | REQUIRED | Ticket ID extracted from text, e.g. `PROJ-123`, `#456` |
| `project_key` | String | REQUIRED | Repository owner |
| `repo_slug` | String | REQUIRED | Repository name |
| `pr_id` | Int64 | NULLABLE | Associated PR (NULL if from commit) |
| `commit_hash` | String | NULLABLE | Associated commit (NULL if from PR) |
| `ticket_source` | String | REQUIRED | Source of ticket reference: `PR_TITLE`, `PR_DESCRIPTION`, `COMMIT_MESSAGE` |
| `collected_at` | DateTime64(3) | REQUIRED | Collection timestamp |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_ticket_lookup`: `(external_ticket_id, project_key, repo_slug, data_source)`

**Purpose**: Links code activity back to task tracker items (Jira, Linear, etc.) without requiring real-time joins. Enables queries like "show all PRs related to PROJ-123" or "calculate cycle time from ticket creation to PR merge."

**Extraction patterns**: Common patterns include Jira keys (`[A-Z]+-[0-9]+`), GitHub issue numbers (`#[0-9]+`), and custom formats configurable per organization.

---

### `git_collection_runs` — Connector execution log

| Field | Type | Constraints | Description |
|-------|------|-------------|-------------|
| `id` | Int64 | PRIMARY KEY | Auto-generated unique identifier |
| `run_id` | String | REQUIRED | Unique run identifier (UUID) |
| `started_at` | DateTime64(3) | REQUIRED | Run start timestamp |
| `completed_at` | DateTime64(3) | NULLABLE | Run end timestamp (NULL if still running) |
| `status` | String | REQUIRED | Run status: `running`, `completed`, `failed` |
| `repos_processed` | Int64 | NULLABLE | Number of repositories processed |
| `commits_collected` | Int64 | NULLABLE | Number of commits collected |
| `prs_collected` | Int64 | NULLABLE | Number of PRs collected |
| `api_calls` | Int64 | NULLABLE | Total API calls made |
| `errors` | Int64 | NULLABLE | Number of errors encountered |
| `settings` | String | NULLABLE | Collection configuration as JSON (org, repos, lookback period) |
| `data_source` | String | DEFAULT '' | Source discriminator |
| `_version` | UInt64 | REQUIRED | Deduplication version |

**Indexes**:
- `idx_run_lookup`: `(run_id, data_source)`
- `idx_run_started`: `(started_at)`

**Purpose**: Monitoring and debugging table — not an analytics source. Tracks connector execution health, performance, and error rates.

---

## Data Source Support

### Bitbucket Server

**API**: REST API v1.0

**Data source identifier**: `insight_bitbucket_server`

**Authentication**: HTTP Basic Auth or Personal Access Token

**Key endpoints**:
- Projects: `/rest/api/1.0/projects`
- Repositories: `/rest/api/1.0/projects/{project}/repos`
- Commits: `/rest/api/1.0/projects/{project}/repos/{repo}/commits`
- PRs: `/rest/api/1.0/projects/{project}/repos/{repo}/pull-requests`

**Limitations**:
- No repository creation date in API
- No primary language detection
- Email addresses may be corporate-specific format
- Review model is simpler (approved/unapproved only)

---

### GitHub

**API**: REST API v3 + GraphQL API v4

**Data source identifier**: `insight_github`

**Authentication**: GitHub App installation token or Personal Access Token (PAT)

**Key endpoints**:
- REST repositories: `/repos/{owner}/{repo}`
- REST commits: `/repos/{owner}/{repo}/commits`
- REST PRs: `/repos/{owner}/{repo}/pulls`
- GraphQL: `repository` query with nested data (100x more efficient)

**Advantages**:
- GraphQL allows bulk fetching (100 commits per call vs 1 in REST)
- Rich metadata (language, size, timestamps)
- Formal review model with multiple states
- Email addresses widely available

**Limitations**:
- Rate limiting stricter than Bitbucket
- Privacy settings may mask emails
- Draft PR concept not in Bitbucket/GitLab

---

### GitLab

**API**: REST API v4 + GraphQL (experimental)

**Data source identifier**: `insight_gitlab`

**Authentication**: Personal Access Token or OAuth2

**Key endpoints**:
- Projects: `/api/v4/projects`
- Commits: `/api/v4/projects/{id}/repository/commits`
- Merge Requests: `/api/v4/projects/{id}/merge_requests`

**Terminology differences**:
- "Merge Request" instead of "Pull Request"
- "Project" instead of "Repository"
- Approval model similar to Bitbucket

---

## Identity Resolution

**Primary identity key**: `author_email` from commits and `reviewer_email` from reviews

**Fallback identifiers**: `author_name`, `author_uuid` (source-specific username and ID)

**Resolution process**:
1. Extract email from `git_commits.author_email` and `git_pull_requests_reviewers.reviewer_email`
2. Normalize email (lowercase, trim whitespace)
3. Map to canonical `person_id` via Identity Manager in Gold step 2
4. If email absent/masked, attempt resolution by `author_name` or `author_uuid` with source context
5. Create new `person_id` if no match found

**Cross-source matching**: Same person may have different usernames across platforms but same email. Email-based resolution ensures they're identified as one person in analytics.

**Deduplication**: `commit_hash` is globally unique. If same commit appears from multiple sources (mirrored repos), use `COUNT(DISTINCT commit_hash)` in queries to avoid double-counting work.

---

## Silver / Gold Mappings

| Silver table | Gold target | Status |
|-------------|--------------|--------|
| `git_repositories` | *(reference table)* | No unified stream — used for filtering and metadata |
| `git_repositories_ext` | *(aggregated metrics)* | Used for repository analytics dashboards and health scoring |
| `git_repository_branches` | *(reference table)* | No unified stream — used for incremental sync |
| `git_commits` | `class_commits` | Planned — stream not yet defined |
| `git_commits_ext` | *(enrichment data)* | Merged into `class_commits` during Gold transformation |
| `git_pull_requests` | `class_pr_activity` | Planned — stream not yet defined |
| `git_pull_requests_ext` | *(enrichment data)* | Merged into `class_pr_activity` during Gold transformation |
| `git_tickets` | Used for `class_task_tracker` cross-reference | Planned |
| `git_commit_files` | *(granular detail)* | Available — no unified stream defined yet |
| `git_pull_requests_reviewers` | *(review analytics)* | Available — aggregated into PR-level metrics |
| `git_pull_requests_comments` | *(review analytics)* | Available — aggregated into PR-level metrics |
| `git_pull_requests_commits` | *(junction)* | Used internally for PR↔commit linkage |

**Planned Gold streams**:
- `class_commits`: Deduplicated commits with resolved `person_id`, language breakdown, and AI detection flags
- `class_pr_activity`: PR lifecycle events with review depth metrics and cycle time calculations

**Gold metrics**:
- Commit-level: lines of code per author, AI percentage trends, commit frequency, language distribution
- PR-level: cycle time (creation to merge), review depth (comments per PR), approval time, merge rate
- Team-level: throughput (commits/PRs per week), collaboration patterns (review participation), quality indicators (rework ratio)

---

## Open Questions

### OQ-GIT-1: Field naming standardization across sources

Current implementation uses `project_key` + `repo_slug` (Bitbucket terminology) as the standard repository identifier. However:
- GitHub uses `owner` + `name`
- GitLab uses `namespace` + `path`

**Question**: Should we maintain Bitbucket naming in the unified schema, or adopt neutral terms like `org_key` + `repo_name`?

**Impact**: Existing queries and transformations may need updates if field names change.

---

### OQ-GIT-2: Handling source-specific features

Some features are platform-specific:
- GitHub: `draft` PRs, formal review states (`CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED`)
- Bitbucket: `task_count`, comment `severity` (`BLOCKER`)
- GitLab: Approval rules, merge request approvals

**Current approach**: Store in `metadata` JSON column, expose in Silver schema only if widely supported

**Question**: Should we add nullable columns for common source-specific features (e.g., `is_draft`, `task_count`) even if they're NULL for some sources?

**Tradeoff**: More columns = easier querying but more schema complexity

---

### OQ-GIT-3: Deduplication strategy for mirrored repositories

When a repository is mirrored across GitHub and Bitbucket, the same `commit_hash` appears twice with different `data_source` values.

**Current approach**: Both records stored in `git_commits`, analytics must `COUNT(DISTINCT commit_hash)`

**Alternatives**:
1. Deduplicate at ingestion — only store first-seen source
2. Add `is_primary_source` flag — mark one source as canonical
3. Keep both records — require DISTINCT in queries (current)

**Question**: Which approach best serves analytics needs?

**Consideration**: Different sources may have different metadata quality (e.g., GitHub has better language detection). Keeping both records allows choosing best metadata at Gold layer.

---

