-- identity.person — append-only log of identity assertions per person.
-- Each row: "source X says person P has value V for kind K, observed at T".
--
-- This model is the automerge bootstrap: groups profiles from silver.identity_input
-- by normalized email within tenant, assigns a random UUIDv7 per group, emits
-- (id, email, display_name) rows for each profile in the group.
--
-- Run MANUALLY: dbt run --select person
-- Intentionally not part of the automatic pipeline (no downstream refs).
--
-- depends_on: {{ ref('identity_input') }}

{{ config(
    materialized='table',
    schema='identity',
    engine='MergeTree()',
    order_by='(tenant_id, kind, source_type, source_id, value)',
    settings={'allow_nullable_key': 1},
    tags=['identity', 'manual']
) }}

WITH
-- Latest UPSERT email per profile
latest_email_per_profile AS (
    SELECT
        insight_tenant_id                            AS tenant_id,
        source_type,
        source_id,
        profile_id,
        lower(trim(field_value))                     AS email_normalized,
        observed_at                                  AS email_observed_at
    FROM (
        SELECT
            insight_tenant_id,
            source_type,
            source_id,
            profile_id,
            field_value,
            observed_at,
            _version,
            row_number() OVER (
                PARTITION BY insight_tenant_id, source_type, source_id, profile_id
                ORDER BY observed_at DESC, _version DESC
            ) AS rn
        FROM {{ ref('identity_input') }}
        WHERE field_type = 'email'
          AND operation  = 'UPSERT'
          AND field_value != ''
    ) t
    WHERE rn = 1
),

-- Latest UPSERT display_name per profile (optional — LEFT JOIN)
latest_display_name_per_profile AS (
    SELECT
        insight_tenant_id                            AS tenant_id,
        source_type,
        source_id,
        profile_id,
        field_value                                  AS display_name_value,
        observed_at                                  AS display_name_observed_at
    FROM (
        SELECT
            insight_tenant_id,
            source_type,
            source_id,
            profile_id,
            field_value,
            observed_at,
            _version,
            row_number() OVER (
                PARTITION BY insight_tenant_id, source_type, source_id, profile_id
                ORDER BY observed_at DESC, _version DESC
            ) AS rn
        FROM {{ ref('identity_input') }}
        WHERE field_type = 'display_name'
          AND operation  = 'UPSERT'
          AND field_value != ''
    ) t
    WHERE rn = 1
),

-- One UUIDv7 per distinct (tenant_id, email_normalized)
person_groups AS (
    SELECT
        tenant_id,
        email_normalized,
        generateUUIDv7() AS person_uid
    FROM (
        SELECT DISTINCT tenant_id, email_normalized
        FROM latest_email_per_profile
    ) d
),

-- Each profile with its resolved person_uid and optional display_name
profiles_with_uid AS (
    SELECT
        le.tenant_id                              AS tenant_id,
        le.source_type                            AS source_type,
        le.source_id                              AS source_id,
        le.profile_id                             AS profile_id,
        le.email_normalized                       AS email_normalized,
        le.email_observed_at                      AS email_observed_at,
        pg.person_uid                             AS person_uid,
        dn.display_name_value                     AS display_name_value,
        dn.display_name_observed_at               AS display_name_observed_at
    FROM latest_email_per_profile le
    INNER JOIN person_groups pg
        ON  le.tenant_id        = pg.tenant_id
        AND le.email_normalized = pg.email_normalized
    LEFT JOIN latest_display_name_per_profile dn
        ON  le.tenant_id   = dn.tenant_id
        AND le.source_type = dn.source_type
        AND le.source_id   = dn.source_id
        AND le.profile_id  = dn.profile_id
)

SELECT
    p.person_uid                                     AS person_uid,
    toLowCardinality(k.kind)                         AS kind,
    p.source_type                                    AS source_type,
    p.source_id                                      AS source_id,
    p.tenant_id                                      AS tenant_id,
    toNullable(
        CASE k.kind
            WHEN 'id'           THEN toString(p.profile_id)
            WHEN 'email'        THEN p.email_normalized
            WHEN 'display_name' THEN p.display_name_value
        END
    )                                                AS value,
    toUUID('00000000-0000-0000-0000-000000000000')   AS author_uid,
    CASE k.kind
        WHEN 'display_name' THEN p.display_name_observed_at
        ELSE p.email_observed_at
    END                                              AS observed_at,
    now64(3)                                         AS created_at,
    toUnixTimestamp64Milli(now64())                  AS _version,
    'dbt automerge'                                  AS reason
FROM profiles_with_uid p
CROSS JOIN (SELECT arrayJoin(['id', 'email', 'display_name']) AS kind) k
WHERE NOT (
    k.kind = 'display_name'
    AND (p.display_name_value IS NULL OR p.display_name_value = '')
)
