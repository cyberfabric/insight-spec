-- Silver layer: unified identity input events from all connectors.
-- Appends new rows from staging.{connector}__identity_input models; ReplacingMergeTree
-- on _version keeps runs idempotent.
--
-- Run: dbt run --select identity_input

-- depends_on: {{ ref('bamboohr__identity_input') }}
-- depends_on: {{ ref('zoom__identity_input') }}

{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='silver',
    engine='ReplacingMergeTree(_version)',
    order_by='(insight_tenant_id, source_type, source_id, profile_id, field_type, observed_at)',
    settings={'allow_nullable_key': 1},
    tags=['silver']
) }}

SELECT * FROM (
    {{ union_by_tag('identity:input') }}
)
{% if is_incremental() %}
WHERE _version > (SELECT max(_version) FROM {{ this }})
{% endif %}
