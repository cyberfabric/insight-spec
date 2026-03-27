{{ config(
    materialized='view',
    tags=['silver:class_comms_events']
) }}

SELECT
    tenant_id,
    userPrincipalName AS user_email,
    sendCount AS emails_sent,
    reportRefreshDate AS activity_date,
    'ms365' AS source
FROM {{ source('bronze_example_tenant', 'email_activity') }}
