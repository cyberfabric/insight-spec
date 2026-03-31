---
name: connector-deploy
description: "Deploy connector to Airbyte + Argo"
---

# Deploy Connector

Registers connector in Airbyte, creates connections, and sets up Argo workflows.

## Prerequisites (ALL mandatory)

- Connector package validated (`/connector validate <name>` passed)
- **Local testing completed**: `source.sh check`, `discover`, `read` all pass
- **Schema generated from real data**: `./scripts/generate-schema.sh <name>` run, schemas in manifest
- **All cursor fields exist in schema** (prevents ClickHouse destination NPE)
- Tenant credentials in `connections/<tenant>.yaml`
- Cluster running (`./up.sh` completed)

## Phase 1: Upload Manifest

```bash
./update-connectors.sh
```

This updates the existing definition in Airbyte in-place (same definition ID).
If the connector is new, it creates a builder project and publishes a new definition.

**Important**: `upload-manifests.sh` updates definitions in-place. It does NOT create
duplicate definitions. The definition ID stays the same across updates.

## Phase 2: Create/Update Connections

```bash
./update-connections.sh <tenant>
```

This script is idempotent — it handles both creation and updates:
- **Destination**: creates if missing; updates database config if changed
- **Source**: creates if missing; recreates if definition ID changed (schema update)
- **Connection**: creates if missing; recreates if source was recreated (fresh discover)
- **Discover**: always runs against current source to get real schema with all fields

### Known pitfalls handled by the script

| Pitfall | How handled |
|---------|-------------|
| Duplicate definitions | Uses latest definition when multiple exist with same name |
| Stale schema after manifest update | Detects definition change, recreates source → fresh discover |
| Missing cursor field in schema | Discover from updated definition includes all fields |
| `full_refresh` + `overwrite` = NPE | Always uses `append_dedup` for all streams |
| Built-in vs custom name collision | Exact name match first, then case-insensitive fallback |

## Phase 3: Create Workflows

```bash
./update-workflows.sh <tenant>
```

Generates CronWorkflow from `descriptor.yaml` schedule.

## Phase 4: Run First Sync

```bash
./run-sync.sh <name> <tenant>
```

Monitor with:
```bash
./logs.sh -f latest
```

If sync fails, get detailed Airbyte logs:
```bash
./logs.sh airbyte latest
```

Common sync failures:
- **NPE getCursor**: cursor field missing from schema → re-run `generate-schema.sh`, update manifest, re-deploy
- **Destination check failed**: ClickHouse database doesn't exist → `apply-connections.sh` creates it
- **Source config validation error**: definition mismatch → re-upload manifest, re-run `update-connections.sh`

## Phase 5: Verify Data

After sync completes:
```sql
-- Bronze
SELECT count(*) FROM bronze_<name>.<stream>;

-- Check mandatory fields
SELECT tenant_id, source_id, unique_key FROM bronze_<name>.<stream> LIMIT 3;

-- Staging (after dbt)
SELECT count(*) FROM staging.<name>__<domain>;

-- Silver (after dbt)
SELECT count(*) FROM silver.class_<domain>;
```

## Summary

```
=== Deployment: <name> ===

  Connector:  registered in Airbyte (definition updated in-place)
  Destination: bronze_<name> (ClickHouse)
  Connection: <name>-to-clickhouse-<tenant> (N streams, discover-based schema)
  Workflow:   <name>-sync (schedule: 0 2 * * *)
  First sync: PASS (N rows in bronze)
```
