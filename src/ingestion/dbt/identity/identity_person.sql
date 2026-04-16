-- Identity person: append-only vertical history of person fields.
-- Each row = one field change for one person from one source profile.
-- Append-only: never updated or deleted, only new rows added.
--
-- Reacts to two types of events:
--   1. New links/unlinks → copy/nullify fields from identity_input
--   2. New input data for already-linked profiles → propagate to person
--
-- Current state of a person:
--   SELECT field_type, field_source,
--          argMax(field_value, valid_from) AS current_value
--   FROM identity.identity_person
--   WHERE person_id = '...'
--   GROUP BY field_type, field_source
--   HAVING current_value != ''
--
-- Run: dbt run --select identity_person

{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='identity',
    tags=['identity']
) }}

-- Current active links: latest action per (tenant, source_type, profile_id) = 'link'
WITH current_links AS (
    SELECT
        insight_tenant_id,
        person_id,
        source_type,
        profile_id,
        created_at AS linked_at
    FROM (
        SELECT *,
            row_number() OVER (
                PARTITION BY insight_tenant_id, source_type,
                    coalesce(profile_id, concat(toString(person_id), ':', source_type))
                ORDER BY created_at DESC
            ) AS rn
        FROM identity.links
    )
    WHERE rn = 1
      AND action = 'link'
      AND profile_id IS NOT NULL
),

-- New link/unlink events since last run
new_links AS (
    SELECT *
    FROM identity.links
    {% if is_incremental() %}
    WHERE created_at > (SELECT coalesce(max(valid_from), toDateTime64('1970-01-01', 3, 'UTC')) FROM {{ this }})
    {% endif %}
),

-- EVENT 1a: LINK — copy all input fields for the newly linked profile
link_fields AS (
    SELECT
        nl.person_id AS person_id,
        i.insight_tenant_id AS insight_tenant_id,
        i.field_type AS field_type,
        i.field_value AS field_value,
        i.source_type AS field_source,
        i.profile_id AS field_profile_id,
        nl.created_at AS valid_from
    FROM new_links nl
    JOIN {{ ref('identity_input') }} i
        ON nl.insight_tenant_id = i.insight_tenant_id
        AND nl.source_type = i.source_type
        AND nl.profile_id = i.profile_id
    WHERE nl.action = 'link'
      AND nl.profile_id IS NOT NULL
      AND i.operation = 'UPSERT'
      AND i.field_value != ''
),

-- EVENT 1b: UNLINK — nullify all fields the person had from this source/profile
-- Find the previous link to determine which profile_id was unlinked
unlink_fields AS (
    SELECT
        nl.person_id AS person_id,
        i.insight_tenant_id AS insight_tenant_id,
        i.field_type AS field_type,
        '' AS field_value,
        i.source_type AS field_source,
        prev_link.profile_id AS field_profile_id,
        nl.created_at AS valid_from
    FROM new_links nl
    -- Find the most recent previous link for this person+source to get the profile_id
    JOIN (
        SELECT *,
            row_number() OVER (
                PARTITION BY insight_tenant_id, person_id, source_type
                ORDER BY created_at DESC
            ) AS rn
        FROM identity.links
        WHERE action = 'link' AND profile_id IS NOT NULL
    ) prev_link
        ON nl.insight_tenant_id = prev_link.insight_tenant_id
        AND nl.person_id = prev_link.person_id
        AND nl.source_type = prev_link.source_type
        AND prev_link.created_at < nl.created_at
        AND prev_link.rn = 1
    -- Get all fields from input for the unlinked profile
    JOIN {{ ref('identity_input') }} i
        ON prev_link.insight_tenant_id = i.insight_tenant_id
        AND prev_link.source_type = i.source_type
        AND prev_link.profile_id = i.profile_id
    WHERE nl.action = 'unlink'
      AND i.operation = 'UPSERT'
      AND i.field_value != ''
),

-- EVENT 2: New input data for already-linked profiles
-- Only picks up input rows NEWER than the link creation date.
-- Older rows are already covered by EVENT 1 (link_fields).
new_input_fields AS (
    SELECT
        cl.person_id AS person_id,
        i.insight_tenant_id AS insight_tenant_id,
        i.field_type AS field_type,
        i.field_value AS field_value,
        i.source_type AS field_source,
        i.profile_id AS field_profile_id,
        i.observed_at AS valid_from
    FROM {{ ref('identity_input') }} i
    JOIN current_links cl
        ON i.insight_tenant_id = cl.insight_tenant_id
        AND i.source_type = cl.source_type
        AND i.profile_id = cl.profile_id
    WHERE i.operation = 'UPSERT'
      AND i.field_value != ''
      AND i.observed_at > cl.linked_at  -- only data newer than link creation
    {% if is_incremental() %}
      AND i.observed_at > (SELECT coalesce(max(valid_from), toDateTime64('1970-01-01', 3, 'UTC')) FROM {{ this }})
    {% endif %}
)

SELECT
    insight_tenant_id,
    person_id,
    field_type,
    field_value,
    field_source,
    field_profile_id,
    valid_from
FROM link_fields

UNION ALL

SELECT
    insight_tenant_id,
    person_id,
    field_type,
    field_value,
    field_source,
    field_profile_id,
    valid_from
FROM unlink_fields

UNION ALL

SELECT
    insight_tenant_id,
    person_id,
    field_type,
    field_value,
    field_source,
    field_profile_id,
    valid_from
FROM new_input_fields
