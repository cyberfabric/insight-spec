# Jira Connector Specification

> Version 1.1 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 5 (Jira)

Standalone specification for the Jira (Task Tracking) connector.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`jira_issue` — Issue identifiers and core fields](#jira_issue--issue-identifiers-and-core-fields)
  - [`jira_issue_history` — Complete changelog](#jira_issue_history--complete-changelog)
  - [`jira_issue_ext` — Custom fields (key-value)](#jira_issue_ext--custom-fields-key-value)
  - [`jira_worklogs` — Logged time per issue](#jira_worklogs--logged-time-per-issue)
  - [`jira_comments` — Issue comments](#jira_comments--issue-comments)
  - [`jira_projects` — Project directory](#jira_projects--project-directory)
  - [`jira_issue_links` — Issue dependencies](#jira_issue_links--issue-dependencies)
  - [`jira_sprints` — Sprint metadata](#jira_sprints--sprint-metadata)
  - [`jira_user` — User directory](#jira_user--user-directory)
  - [`jira_collection_runs` — Connector execution log](#jira_collection_runs--connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver--gold-mappings)
- [Open Questions](#open-questions)

<!-- /toc -->

---

## Overview

**API**: Jira REST API v3 (Atlassian Cloud) or v2 (Jira Server / Data Center). Agile endpoints: Jira Software REST API v1 (`/rest/agile/1.0/`).

**Category**: Task Tracking

**Authentication**: API token + email (Cloud) or Basic Auth (Server/Data Center)

**Identity**: `jira_user.email` — resolved to canonical `person_id` via Identity Manager. Jira Cloud uses Atlassian `account_id` as the internal user identifier; email is the cross-system key. Note: Atlassian privacy controls may suppress email for some users (see OQ-JIRA-1).

**Field naming**: snake_case — Jira API uses camelCase; fields renamed to snake_case at Bronze level.

**Key differences from YouTrack:**

| Aspect | YouTrack | Jira |
|--------|----------|------|
| User ID | Internal string, e.g. `2-12345` | Atlassian `account_id` (alphanumeric) |
| Changelog | `added` + `removed` arrays | `value_from` + `value_to` + human-readable `*_string` |
| Sprint API | Agile board → sprints | `/rest/agile/1.0/board/{id}/sprint` |
| Story points | Custom field (name varies) | `customfield_10016` (Next-gen) or `story_points` (Classic) |
| Issue type | `type(name)` custom field | Native `issuetype.name` |

---

## Bronze Tables

### `jira_issue` — Issue identifiers and core fields

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier, e.g. `jira-team-alpha` |
| `jira_id` | text | Jira internal numeric ID, e.g. `10001` |
| `id_readable` | text | Human-readable key, e.g. `PROJ-123` — joins to `jira_issue_history.id_readable` |
| `project_key` | text | Project key, e.g. `PROJ` — from `fields.project.key` |
| `issue_type` | text | Issue type name — from `fields.issuetype.name`, e.g. `Bug` / `Story` / `Task` / `Epic` |
| `reporter_id` | text | Who created the issue — `fields.reporter.accountId` — joins to `jira_user.account_id` |
| `story_points` | numeric | Story points estimate — from `fields.story_points` (Classic) or `fields.customfield_10016` (Next-gen); NULL if not set |
| `due_date` | date | Due date — from `fields.duedate`; NULL if not set |
| `parent_id` | text | Parent issue key for subtasks or Epic link — from `fields.parent.key` or `fields.customfield_10014`; NULL if top-level |
| `created` | timestamptz | Issue creation timestamp — from `fields.created` |
| `updated` | timestamptz | Last update — from `fields.updated`; cursor for incremental sync |

**Note on `story_points`**: field name differs between Jira Classic (`story_points`) and Next-gen projects (`customfield_10016`). Some instances use other custom field IDs. Connector must detect or be configured with the correct field ID per instance.

---

### `jira_issue_history` — Complete changelog

Every state transition, reassignment, and field update is a separate row. Collected from `GET /rest/api/3/issue/{key}/changelog`. Each changelog entry may contain multiple field changes — each stored as a separate row.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier — scopes all IDs |
| `id_readable` | text | Human-readable issue key — joins to `jira_issue.id_readable` |
| `issue_jira_id` | text | Parent issue's internal numeric ID |
| `author_account_id` | text | Atlassian account ID of who made the change — joins to `jira_user.account_id` |
| `changelog_id` | text | Changelog entry ID — multiple field changes in one operation share this |
| `created_at` | timestamptz | When the change was made — from `created` |
| `field_id` | text | Machine-readable field identifier — from `fieldId` |
| `field_name` | text | Human-readable field name — from `field`, e.g. `status`, `assignee`, `priority` |
| `value_from` | text | Previous raw value (ID or key) — from `from`; NULL if field was empty |
| `value_from_string` | text | Previous human-readable value — from `fromString`, e.g. `In Progress` |
| `value_to` | text | New raw value after the change — from `to` |
| `value_to_string` | text | New human-readable value — from `toString`, e.g. `Done` |

**`changelog_id` groups related changes**: one user action updating multiple fields produces multiple rows with the same `changelog_id`.

---

### `jira_issue_ext` — Custom fields (key-value)

Stores per-issue custom field values that don't fit the core schema. Follows the same key-value pattern as `git_repositories_ext`.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier |
| `id_readable` | text | Issue key — joins to `jira_issue.id_readable` |
| `field_id` | text | Custom field ID, e.g. `customfield_10050` |
| `field_name` | text | Custom field display name, e.g. `Team`, `Squad`, `Customer` |
| `field_value` | text | Field value as string (JSON for complex types) |
| `value_type` | text | Type hint: `string` / `number` / `user` / `option` / `json` |
| `collected_at` | timestamptz | Collection timestamp |

**Purpose**: captures team, squad, domain, customer, and other org-specific fields without schema changes. Custom field discovery via `GET /rest/api/3/field`.

---

### `jira_worklogs` — Logged time per issue

Collected from `GET /rest/api/3/issue/{key}/worklog`.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier |
| `worklog_id` | text | Worklog entry ID |
| `id_readable` | text | Parent issue key — joins to `jira_issue.id_readable` |
| `author_account_id` | text | Who logged the time — joins to `jira_user.account_id` |
| `started` | timestamptz | When the work was done (not collection time) — from `started` |
| `time_spent_seconds` | numeric | Time logged in seconds — from `timeSpentSeconds` |
| `comment` | text | Worklog comment (nullable) — from `comment.content` |
| `collected_at` | timestamptz | Collection timestamp |

**Purpose**: actual time spent per person per issue. Complements state-change history — an issue can be "In Progress" for weeks but have only 2 hours of logged work.

---

### `jira_comments` — Issue comments

Collected from `GET /rest/api/3/issue/{key}/comment`.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier |
| `comment_id` | text | Comment ID |
| `id_readable` | text | Parent issue key — joins to `jira_issue.id_readable` |
| `author_account_id` | text | Comment author — joins to `jira_user.account_id` |
| `created` | timestamptz | When comment was posted |
| `updated` | timestamptz | Last edit timestamp |
| `body` | text | Comment body (Atlassian Document Format; plain text extracted at collection) |

**Purpose**: collaboration signal — comment volume per person, review participation, cross-team communication.

---

### `jira_projects` — Project directory

Collected from `GET /rest/api/3/project`.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier |
| `project_id` | text | Jira internal project ID |
| `project_key` | text | Project key, e.g. `PROJ` — joins to `jira_issue.project_key` |
| `name` | text | Project name |
| `lead_account_id` | text | Project lead — joins to `jira_user.account_id` |
| `project_type` | text | `software` / `business` / `service_desk` |
| `style` | text | `classic` / `next-gen` — affects custom field names |
| `archived` | boolean | Whether the project is archived |
| `collected_at` | timestamptz | Collection timestamp |

**Purpose**: maps issues to teams/departments. `style` field is important — Next-gen and Classic projects use different custom field IDs for story points and sprints.

---

### `jira_issue_links` — Issue dependencies

Collected from `fields.issuelinks` in issue response.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier |
| `source_issue` | text | Source issue key |
| `target_issue` | text | Target issue key |
| `link_type` | text | Link type name, e.g. `blocks` / `is blocked by` / `duplicates` / `relates to` / `is subtask of` |
| `collected_at` | timestamptz | Collection timestamp |

**Purpose**: dependency and blocker analysis. Required for fair productivity measurement — blocked issues should not count against the assignee's throughput.

---

### `jira_sprints` — Sprint metadata

Collected from `GET /rest/agile/1.0/board/{boardId}/sprint`. Board list from `GET /rest/agile/1.0/board`.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier |
| `sprint_id` | numeric | Sprint ID |
| `board_id` | numeric | Agile board ID |
| `board_name` | text | Agile board name |
| `sprint_name` | text | Sprint name |
| `state` | text | `active` / `closed` / `future` |
| `start_date` | timestamptz | Sprint start |
| `end_date` | timestamptz | Sprint end (planned) |
| `complete_date` | timestamptz | Sprint completion date (NULL if not closed) |
| `project_key` | text | Associated project — from board configuration |
| `collected_at` | timestamptz | Collection timestamp |

**Note**: Issue-to-sprint assignment is tracked via `fields.customfield_10020` (Next-gen) or `fields.sprint` (Classic) in the issue. Sprint changes appear in `jira_issue_history` as `field_name = "Sprint"`.

---

### `jira_user` — User directory

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier |
| `account_id` | text | Atlassian account ID — joins to `author_account_id` / `reporter_id` / `lead_account_id` |
| `email` | text | Email — primary key for cross-system identity resolution; **nullable** — may be suppressed by Atlassian privacy controls |
| `display_name` | text | Display name |
| `account_type` | text | `atlassian` / `app` / `customer` |
| `active` | boolean | Whether the account is active |

**Note**: `account_id` is shared across the Atlassian platform (Jira, Confluence, Bitbucket on the same tenant). When `email` is suppressed, `account_id` may be used as a fallback within the Atlassian ecosystem — see OQ-JIRA-1.

---

### `jira_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | text | Unique run identifier |
| `started_at` | timestamp | Run start time |
| `completed_at` | timestamp | Run end time |
| `status` | text | `running` / `completed` / `failed` |
| `issues_collected` | numeric | Rows collected for `jira_issue` |
| `history_records_collected` | numeric | Rows collected for `jira_issue_history` |
| `worklogs_collected` | numeric | Rows collected for `jira_worklogs` |
| `comments_collected` | numeric | Rows collected for `jira_comments` |
| `users_collected` | numeric | Rows collected for `jira_user` |
| `api_calls` | numeric | API / SOQL calls made |
| `errors` | numeric | Errors encountered |
| `settings` | jsonb | Collection configuration (instance URL, project filter, lookback) |

---

## Identity Resolution

`jira_user.email` is the primary identity key — mapped to canonical `person_id` via Identity Manager in Silver step 2.

Resolution chain for history events:
`jira_issue_history.author_account_id` → `jira_user.account_id` → `jira_user.email` → `person_id`

Same chain applies to `jira_worklogs.author_account_id`, `jira_comments.author_account_id`, and `jira_projects.lead_account_id`.

`account_id` is Atlassian-platform-specific and shared across Jira, Confluence, and Bitbucket on the same tenant — useful for cross-tool resolution within the Atlassian ecosystem. Email remains the canonical cross-system key for Insight's Identity Manager.

`source_instance_id` must be included in all joins — `id_readable` values like `PROJ-123` can collide across instances.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Notes |
|-------------|--------------|-------|
| `jira_issue` + `jira_issue_history` | `class_task_tracker_activities` | Append-only event stream |
| `jira_issue` + `jira_issue_history` | `class_task_tracker_snapshot` | Current state per issue (upsert) |
| `jira_worklogs` | `class_task_tracker_worklogs` | Planned — actual time logged per person |
| `jira_comments` | `class_task_tracker_comments` | Planned — collaboration signal |
| `jira_user` | Identity Manager (`email` → `person_id`) | Used for identity resolution |
| `jira_projects` | Reference — team/project mapping | No unified stream; used for grouping |
| `jira_issue_links` | Reference — blocker analysis | Used to flag blocked issues in Gold |
| `jira_sprints` | `class_task_tracker_sprints` | Planned — sprint velocity metrics |
| `jira_issue_ext` | Merged into Silver snapshots | Custom fields promoted selectively |

**Silver step 1**: `class_task_tracker_activities` (event log) + `class_task_tracker_snapshot` (current state)

**Silver step 2**: identity resolution — `author_account_id` → `person_id` via Identity Manager

**Gold metrics**: cycle time, throughput, WIP, status periods, sprint velocity, worklog hours per person, blocker rate

---

## Open Questions

### OQ-JIRA-1: `account_id` vs email as primary identity key

Jira Cloud may suppress `emailAddress` for some users via Atlassian privacy controls. Options:
- Use `account_id` as fallback within Atlassian ecosystem (Jira + Bitbucket share the same account)
- Require email for all users and exclude those without it from person-level analytics
- Support `account_id` as an alternative resolution path in Identity Manager

### OQ-JIRA-2: Multi-instance deployments

`(source_instance_id, id_readable)` is the unique composite key for issues. Confirm that `task_id` in `class_task_tracker` includes the instance prefix to prevent collisions.

### OQ-JIRA-3: `story_points` field ID per instance

Story points field ID differs between Jira Classic (`story_points`) and Next-gen (`customfield_10016`). The `jira_projects.style` field indicates which applies. Connector must detect the correct field ID per project. Should this be auto-detected or manually configured?

### OQ-JIRA-4: Sprint-issue membership for Classic projects

In Classic projects, sprint assignment is via `fields.sprint` (single sprint) or changelog entries for `Sprint` field changes. In Next-gen, it's `customfield_10020`. How does the connector handle issues that have been moved across sprints? Are all historical sprint assignments captured or only the current one?
