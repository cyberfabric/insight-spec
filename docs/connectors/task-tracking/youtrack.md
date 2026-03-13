# YouTrack Connector Specification

> Version 1.1 — March 2026
> Based on: `docs/CONNECTORS_REFERENCE.md` Source 4 (YouTrack), OQ-5, OQ-6

Standalone specification for the YouTrack (Task Tracking) connector.

<!-- toc -->

- [Overview](#overview)
- [Bronze Tables](#bronze-tables)
  - [`youtrack_issue` — Issue identifiers and core fields](#youtrack_issue--issue-identifiers-and-core-fields)
  - [`youtrack_issue_history` — Complete field change log](#youtrack_issue_history--complete-field-change-log)
  - [`youtrack_issue_ext` — Custom fields (key-value)](#youtrack_issue_ext--custom-fields-key-value)
  - [`youtrack_worklogs` — Logged time per issue](#youtrack_worklogs--logged-time-per-issue)
  - [`youtrack_comments` — Issue comments](#youtrack_comments--issue-comments)
  - [`youtrack_projects` — Project directory](#youtrack_projects--project-directory)
  - [`youtrack_issue_links` — Issue dependencies](#youtrack_issue_links--issue-dependencies)
  - [`youtrack_sprints` — Agile board iterations](#youtrack_sprints--agile-board-iterations)
  - [`youtrack_user` — User directory](#youtrack_user--user-directory)
  - [`youtrack_collection_runs` — Connector execution log](#youtrack_collection_runs--connector-execution-log)
- [Identity Resolution](#identity-resolution)
- [Silver / Gold Mappings](#silver--gold-mappings)
- [Open Questions](#open-questions)

<!-- /toc -->

---

## Overview

**API**: YouTrack REST API (`/api/issues`, `/api/admin/projects`, `/api/agiles`)

**Category**: Task Tracking

**Authentication**: Permanent token (YouTrack service account)

**Identity**: `youtrack_user.email` — resolved to canonical `person_id` via Identity Manager. `youtrack_id` and `username` are YouTrack-internal; email is the cross-system key.

**Field naming**: snake_case — preserved as-is at Bronze level.

**Design principle**: `youtrack_issue` stores identifiers and immutable context fields (type, reporter, initial estimate). All state transitions live in `youtrack_issue_history` as an append-only event log. This is the source of truth for cycle time, status periods, and assignee history.

**`source_instance_id`**: present in all tables — required to disambiguate multiple YouTrack instances in the same Bronze store.

---

## Bronze Tables

### `youtrack_issue` — Issue identifiers and core fields

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier, e.g. `youtrack-acme-prod` |
| `youtrack_id` | text | YouTrack internal ID, e.g. `2-12345` |
| `id_readable` | text | Human-readable ID, e.g. `MON-123` — joins to `youtrack_issue_history.id_readable` |
| `project_key` | text | Project short name, e.g. `MON` — from `project(shortName)` |
| `issue_type` | text | Issue type name, e.g. `Bug` / `Story` / `Task` / `Epic` — from `type(name)` |
| `reporter_id` | text | Who created the issue — `reporter.id` — joins to `youtrack_user.youtrack_id` |
| `story_points` | numeric | Initial story points estimate — from custom field (field name is instance-specific, see note) |
| `due_date` | date | Due date — from `dueDate` field (NULL if not set) |
| `created` | timestamp | Issue creation timestamp — Unix ms, converted to datetime |
| `updated` | timestamp | Last update — Unix ms, converted; cursor for incremental sync |

**Note on `story_points`**: YouTrack stores estimates as a custom field. The field name varies by project template — common names are `Story Points` or `Estimation` (Scrum template uses minutes). The connector must be configured with the correct field name per instance.

**Note on timestamps**: YouTrack API returns all timestamps as Unix milliseconds. Convert to datetime at collection time.

---

### `youtrack_issue_history` — Complete field change log

Every state transition, reassignment, and field update is a separate row. Collected from `/api/issues/{id}/activities`.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier — scopes all IDs |
| `id_readable` | text | Human-readable issue ID — joins to `youtrack_issue.id_readable` |
| `issue_youtrack_id` | text | Parent issue's internal ID |
| `author_youtrack_id` | text | Who made the change — `author.id` — joins to `youtrack_user.youtrack_id` |
| `activity_id` | text | Activity ID — multiple changes in one operation share this batch ID |
| `created_at` | timestamptz | When the change was made — converted from Unix ms (`timestamp` field) |
| `field_id` | text | Machine-readable field identifier |
| `field_name` | text | Human-readable field name, e.g. `State`, `Assignee`, `Priority` |
| `value_added` | jsonb | New value after the change — from `added` array; varies by field type (see note) |
| `value_removed` | jsonb | Previous value before the change — from `removed` array; NULL if field was empty |
| `value_id` | text | Unique value change ID — for deduplication |

**`value_added` / `value_removed` field variation by type:**
- State / Priority / Type: plain string, e.g. `"In Progress"`
- User fields (Assignee): object `{"name": "Jane Smith", "id": "1-234"}`
- Tags: array of strings
- Numeric fields: numeric string, e.g. `"5"`

**Note**: Both `added` and `removed` arrays are returned by the YouTrack activities API. Previous specs only captured `added`. Capturing `value_removed` is required for cycle time calculations (e.g. "how long was this issue In Progress").

---

### `youtrack_issue_ext` — Custom fields (key-value)

Stores per-issue custom field values that don't fit the core schema. Follows the same key-value pattern as `git_repositories_ext`.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier |
| `id_readable` | text | Issue ID — joins to `youtrack_issue.id_readable` |
| `field_id` | text | Custom field machine ID |
| `field_name` | text | Custom field human name, e.g. `Team`, `Squad`, `Customer` |
| `field_value` | text | Field value as string (JSON for complex types) |
| `value_type` | text | Type hint: `string` / `number` / `user` / `enum` / `json` |
| `collected_at` | timestamptz | Collection timestamp |

**Purpose**: captures team, squad, domain, customer, and other org-specific fields without schema changes.

---

### `youtrack_worklogs` — Logged time per issue

Collected from `/api/issues/{id}/timeTracking/workItems`.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier |
| `work_item_id` | text | Work item ID |
| `id_readable` | text | Parent issue ID — joins to `youtrack_issue.id_readable` |
| `author_youtrack_id` | text | Who logged the time — joins to `youtrack_user.youtrack_id` |
| `date` | date | Date of work (not collection date) |
| `duration_minutes` | numeric | Time logged in minutes — from `duration.minutes` |
| `description` | text | Work item description / comment (nullable) |
| `collected_at` | timestamptz | Collection timestamp |

**Purpose**: actual time spent per person per issue. Complements state-change history — an issue can be "In Progress" for weeks but have only 2 hours of logged work.

---

### `youtrack_comments` — Issue comments

Collected from `/api/issues/{id}/comments`.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier |
| `comment_id` | text | Comment ID |
| `id_readable` | text | Parent issue ID — joins to `youtrack_issue.id_readable` |
| `author_youtrack_id` | text | Comment author — joins to `youtrack_user.youtrack_id` |
| `created_at` | timestamptz | When comment was posted |
| `updated_at` | timestamptz | Last edit timestamp (NULL if never edited) |
| `text` | text | Comment body (Markdown) |
| `deleted` | boolean | Whether the comment has been deleted |

**Purpose**: collaboration signal — comment volume per person, review participation, cross-team communication.

---

### `youtrack_projects` — Project directory

Collected from `/api/admin/projects`.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier |
| `project_id` | text | YouTrack internal project ID |
| `project_key` | text | Short name, e.g. `MON` — joins to `youtrack_issue.project_key` |
| `name` | text | Full project name |
| `leader_youtrack_id` | text | Project lead — joins to `youtrack_user.youtrack_id` |
| `archived` | boolean | Whether the project is archived |
| `collected_at` | timestamptz | Collection timestamp |

**Purpose**: maps issues to teams/departments. Required for team-level aggregations without external configuration.

---

### `youtrack_issue_links` — Issue dependencies

Collected from `/api/issues/{id}/links`.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier |
| `source_issue` | text | Source issue ID (`id_readable`) |
| `target_issue` | text | Target issue ID (`id_readable`) |
| `link_type` | text | Link type name, e.g. `blocks` / `duplicates` / `relates to` / `subtask of` |
| `direction` | text | `outward` / `inward` — perspective of the link from the source issue |
| `collected_at` | timestamptz | Collection timestamp |

**Purpose**: dependency and blocker analysis. Required for fair productivity measurement — blocked issues should not count against the assignee's throughput.

---

### `youtrack_sprints` — Agile board iterations

Collected from `/api/agiles/{boardId}/sprints`.

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier |
| `sprint_id` | text | Sprint ID |
| `board_id` | text | Agile board ID |
| `board_name` | text | Agile board name |
| `sprint_name` | text | Sprint name |
| `project_key` | text | Associated project — joins to `youtrack_projects.project_key` |
| `start_date` | date | Sprint start date |
| `end_date` | date | Sprint end date |
| `is_completed` | boolean | Whether the sprint is completed |
| `collected_at` | timestamptz | Collection timestamp |

**Purpose**: sprint-level analytics — velocity, completion rate, carry-over (issues not finished within the sprint).

---

### `youtrack_user` — User directory

| Field | Type | Description |
|-------|------|-------------|
| `source_instance_id` | text | Connector instance identifier |
| `youtrack_id` | text | YouTrack internal user ID — joins to `author_youtrack_id` / `reporter_id` / `leader_youtrack_id` |
| `email` | text | Email — primary key for cross-system identity resolution |
| `full_name` | text | Display name |
| `username` | text | Login username |
| `banned` | boolean | Whether the user account is banned / deactivated |

---

### `youtrack_collection_runs` — Connector execution log

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | text | Unique run identifier |
| `started_at` | timestamp | Run start time |
| `completed_at` | timestamp | Run end time |
| `status` | text | `running` / `completed` / `failed` |
| `issues_collected` | numeric | Rows collected for `youtrack_issue` |
| `history_records_collected` | numeric | Rows collected for `youtrack_issue_history` |
| `worklogs_collected` | numeric | Rows collected for `youtrack_worklogs` |
| `comments_collected` | numeric | Rows collected for `youtrack_comments` |
| `users_collected` | numeric | Rows collected for `youtrack_user` |
| `api_calls` | numeric | API calls made |
| `errors` | numeric | Errors encountered |
| `settings` | jsonb | Collection configuration (instance URL, project filter, lookback) |

---

## Identity Resolution

`youtrack_user.email` is the primary identity key — mapped to canonical `person_id` via Identity Manager in Silver step 2.

Resolution chain for history events:
`youtrack_issue_history.author_youtrack_id` → `youtrack_user.youtrack_id` → `youtrack_user.email` → `person_id`

Same chain applies to `youtrack_worklogs.author_youtrack_id`, `youtrack_comments.author_youtrack_id`, and `youtrack_projects.leader_youtrack_id`.

`source_instance_id` must be included in all joins — YouTrack IDs are scoped to their instance.

---

## Silver / Gold Mappings

| Bronze table | Silver target | Notes |
|-------------|--------------|-------|
| `youtrack_issue` + `youtrack_issue_history` | `class_task_tracker_activities` | Append-only event stream |
| `youtrack_issue` + `youtrack_issue_history` | `class_task_tracker_snapshot` | Current state per issue (upsert) |
| `youtrack_worklogs` | `class_task_tracker_worklogs` | Planned — actual time logged per person |
| `youtrack_comments` | `class_task_tracker_comments` | Planned — collaboration signal |
| `youtrack_user` | Identity Manager (`email` → `person_id`) | Used for identity resolution |
| `youtrack_projects` | Reference — team/project mapping | No unified stream; used for grouping |
| `youtrack_issue_links` | Reference — blocker analysis | Used to flag blocked issues in Gold |
| `youtrack_sprints` | `class_task_tracker_sprints` | Planned — sprint velocity metrics |
| `youtrack_issue_ext` | Merged into Silver snapshots | Custom fields promoted selectively |

**Silver step 1**: `class_task_tracker_activities` (event log) + `class_task_tracker_snapshot` (current state)

**Silver step 2**: identity resolution — `author_youtrack_id` → `person_id` via Identity Manager

**Gold metrics**: cycle time, throughput, WIP, status periods, sprint velocity, worklog hours per person, blocker rate

---

## Open Questions

### OQ-YT-1: `source_instance_id` in all tables

`source_instance_id` is now required in all tables including `youtrack_issue_history`, `youtrack_worklogs`, `youtrack_comments`. Confirm the connector produces this field consistently for all object types.

### OQ-YT-2: `author_youtrack_id` type — string format

`youtrack_issue_history.author_youtrack_id` is a string like `1-234`. Silver's `class_task_tracker_activities` previously used `UInt64` for `event_author_raw` — this is incompatible with YouTrack's `N-NNNNN` format. Should be `String` / `text` throughout.

### OQ-YT-3: `story_points` field name per instance

The custom field name for story points varies per YouTrack instance (e.g. `Story Points`, `Estimation`, `SP`). Connector must be configured with the correct field name. Should this be a per-project or per-instance setting?

### OQ-YT-4: Sprint-issue membership

Issue-sprint membership in YouTrack is via the `Sprint` custom field (visible in `youtrack_issue_history` when sprint changes) or via the Agile board API. Clarify which source the connector uses and how carry-over (issue moved to next sprint) is tracked.
