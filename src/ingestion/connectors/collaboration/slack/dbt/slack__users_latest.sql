{{ config(
    materialized='table',
    schema='staging',
    tags=['slack']
) }}

-- Dedup bronze_slack.users_details to one row per (user_id, email).
-- Bronze has one row per user per day; here we keep the latest `date` seen
-- for each (user_id, email) pair and drop rows with null/empty email.

WITH ranked AS (
    SELECT
        tenant_id,
        source_id,
        user_id,
        email_address AS email,
        is_guest,
        is_billable_seat,
        date,
        row_number() OVER (
            PARTITION BY tenant_id, source_id, user_id, email_address
            ORDER BY date DESC
        ) AS rn
    FROM {{ source('bronze_slack', 'users_details') }}
    WHERE email_address IS NOT NULL
      AND email_address != ''
)

SELECT
    tenant_id,
    source_id,
    user_id,
    email,
    is_guest,
    is_billable_seat,
    concat(tenant_id, '-', source_id, '-', user_id, '-', email) AS unique_key
FROM ranked
WHERE rn = 1
