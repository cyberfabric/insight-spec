# Table: `class_task_tracker`

## Overview

**Purpose**: Store unified task/issue data from multiple task tracker sources (YouTrack, Jira) with lifecycle timestamps and ownership information.

**Data Sources**:
- YouTrack: `source = "youtrack"`
- Jira: `source = "jira"`

---

## Schema Definition

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | int | PRIMARY KEY, AUTO INCREMENT | Internal primary key |
| `ingestion_at` | timestamp | NOT NULL | Ingestion date |
| `deleted` | boolean | NOT NULL | Record deletion flag |
| `task_id` | text | NOT NULL | Human-readable task identifier |
| `task_id_ref` | text | NOT NULL | Task identifier in source tracker system |
| `source` | text | NOT NULL | Source marker: "youtrack" or "jira" |
| `metadata` | jsonb | NOT NULL | Free-form metadata |
| `created_at` | timestamp | NOT NULL | Task creation datetime |
| `created_by_name` | text | NOT NULL | Task creator name |
| `created_by_id` | text | NOT NULL | Task creator identifier in tracker |
| `started_at` | timestamp | NULLABLE | Task start datetime |
| `started_by_name` | text | NULLABLE | Task starter name |
| `started_by_id` | text | NULLABLE | Task starter identifier in tracker |
| `testing_started_at` | timestamp | NULLABLE | Testing start datetime |
| `testing_started_by_name` | text | NULLABLE | Testing starter name |
| `testing_started_by_id` | text | NULLABLE | Testing starter identifier in tracker |
| `done_at` | timestamp | NULLABLE | Task completion datetime |
| `done_by_name` | text | NULLABLE | Task completer name |
| `done_by_id` | text | NULLABLE | Task completer identifier in tracker |

**Indexes**:
- `idx_class_task_tracker_ingestion_at`: `(ingestion_at)`
- `idx_class_task_tracker_task_id`: `(task_id)`
- `idx_class_task_tracker_task_id_ref`: `(task_id_ref)`
- `idx_class_task_tracker_source_task_id_ref`: `(source, task_id_ref)`
- `uq_class_task_tracker_source_task_id_ref_deleted`: `(source, task_id_ref, deleted)` — UNIQUE

---

## Field Semantics

### Core Identifiers

**`id`** (int, PRIMARY KEY)
- **Purpose**: Internal auto-increment key
- **Usage**: Internal references

**`task_id`** (text, NOT NULL)
- **Purpose**: Human-readable task identifier
- **Examples**: "MON-123", "PLAT-456"
- **Usage**: Display, cross-referencing with commit messages

**`task_id_ref`** (text, NOT NULL)
- **Purpose**: Task identifier as used in the source tracker system
- **Format**: Source-specific format
- **YouTrack**: YouTrack issue ID
- **Jira**: Jira issue key
- **Usage**: Source system lookups, API references

**`source`** (text, NOT NULL)
- **Purpose**: Identifies the source tracker system
- **Values**: "youtrack", "jira"
- **Usage**: Multi-source filtering, source-specific logic

### Task Lifecycle

**`created_at`** (timestamp, NOT NULL)
- **Purpose**: When the task was created in the source system
- **Usage**: Task age calculation, creation metrics

**`created_by_name`** / **`created_by_id`** (text, NOT NULL)
- **Purpose**: Who created the task
- **Usage**: Task origin analysis

**`started_at`** (timestamp, NULLABLE)
- **Purpose**: When work on the task began
- **Note**: NULL if task hasn't been started
- **Usage**: Lead time calculation (created → started)

**`started_by_name`** / **`started_by_id`** (text, NULLABLE)
- **Purpose**: Who started working on the task
- **Usage**: Work assignment analysis

**`testing_started_at`** (timestamp, NULLABLE)
- **Purpose**: When testing phase began
- **Note**: NULL if task hasn't reached testing
- **Usage**: Development time calculation (started → testing)

**`testing_started_by_name`** / **`testing_started_by_id`** (text, NULLABLE)
- **Purpose**: Who moved the task to testing
- **Usage**: Testing assignment analysis

**`done_at`** (timestamp, NULLABLE)
- **Purpose**: When the task was completed
- **Note**: NULL if task isn't done
- **Usage**: Cycle time (created → done), throughput

**`done_by_name`** / **`done_by_id`** (text, NULLABLE)
- **Purpose**: Who completed the task
- **Usage**: Completion attribution

### System Fields

**`ingestion_at`** (timestamp, NOT NULL)
- **Purpose**: When the record was ingested into the system
- **Usage**: Data freshness, incremental processing

**`deleted`** (boolean, NOT NULL)
- **Purpose**: Soft delete flag
- **Values**: true (deleted), false (active)
- **Usage**: Filtering active records, audit trail

**`metadata`** (jsonb, NOT NULL)
- **Purpose**: Free-form additional metadata from source system
- **Format**: JSON object
- **Usage**: Source-specific fields, debugging, custom analysis

---

## Relationships

This table is standalone. Task correlation with git commits is done via `task_id` matching `git.commit.task_id`.

---

## Usage Examples

### Cycle time analysis

```sql
SELECT
    task_id,
    source,
    created_at,
    started_at,
    done_at,
    EXTRACT(EPOCH FROM (done_at - created_at)) / 3600 as cycle_time_hours,
    EXTRACT(EPOCH FROM (started_at - created_at)) / 3600 as lead_time_hours
FROM class_task_tracker
WHERE done_at IS NOT NULL
  AND deleted = false
  AND created_at >= '2026-01-01'
ORDER BY cycle_time_hours DESC;
```

### Tasks linked to commits

```sql
SELECT
    t.task_id,
    t.source,
    t.created_at,
    t.done_at,
    COUNT(c.id) as commit_count
FROM class_task_tracker t
LEFT JOIN git.commit c ON t.task_id = c.task_id
WHERE t.deleted = false
GROUP BY t.task_id, t.source, t.created_at, t.done_at
ORDER BY commit_count DESC
LIMIT 20;
```

### Open tasks by creator

```sql
SELECT
    created_by_name,
    COUNT(*) as open_tasks
FROM class_task_tracker
WHERE done_at IS NULL
  AND deleted = false
GROUP BY created_by_name
ORDER BY open_tasks DESC;
```

### Task throughput by week

```sql
SELECT
    DATE_TRUNC('week', done_at) as week,
    source,
    COUNT(*) as completed_tasks
FROM class_task_tracker
WHERE done_at IS NOT NULL
  AND deleted = false
GROUP BY week, source
ORDER BY week DESC;
```

---

## Notes and Considerations

### Multi-Source Design

This table unifies tasks from YouTrack and Jira. The unique constraint on `(source, task_id_ref, deleted)` ensures no duplicate tasks per source.

### Soft Deletes

Records are soft-deleted (`deleted = true`) rather than physically removed. Always filter with `deleted = false` for active task analysis.

### Lifecycle Timestamps

The lifecycle timestamps (`created_at` → `started_at` → `testing_started_at` → `done_at`) enable detailed workflow analysis. Not all transitions may be captured — some tasks may skip the testing phase or go directly from created to done.

### Metadata

The `metadata` JSONB field contains source-specific information that doesn't fit the normalized schema. Contents vary by source and may include priority, assignee details, labels, and custom fields.
