-- Bronze → Silver step 1: Claude Admin programmatic API usage → class_ai_api_usage
--
-- Source: bronze_claude_admin.claude_admin_messages_usage — daily token usage
-- from /v1/organizations/usage_report/messages, grouped by
-- (date, model, api_key_id, workspace_id, service_tier, context_window).
--
-- email is always NULL here: programmatic API calls authenticate via API keys
-- and Anthropic cannot attribute consumption to individual users at request
-- time. Per-user attribution comes via Silver Step 2 (Identity Resolution) by
-- treating api_key_id as an identity key — when the organisation provisions
-- one API key per developer (common practice), api_key_id → person_id is a
-- clean 1:1 mapping. Fallback per-user attribution via Enterprise engagement
-- (claude_enterprise_users.chat_*) in claude_enterprise__ai_api_usage.
--
-- channel = 'api' for all rows produced here.
{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['claude-admin', 'silver:class_ai_api_usage']
) }}

SELECT
    tenant_id                                       AS insight_tenant_id,
    insight_source_id                               AS source_id,
    concat(
        tenant_id, '-',
        insight_source_id, '-',
        'ws:', coalesce(workspace_id, '__null__'), '-',
        toString(toDate(date)), '-',
        'anthropic-api-',
        coalesce(model, '__null__'), '-',
        coalesce(api_key_id, '__null__'), '-',
        coalesce(service_tier, '__null__'), '-',
        coalesce(context_window, '__null__')
    )                                               AS unique_key,
    CAST(NULL AS Nullable(String))                  AS email,
    api_key_id,
    workspace_id,
    toDate(date)                                    AS day,
    'anthropic'                                     AS provider,
    'api'                                           AS channel,
    CAST(NULL AS Nullable(UInt32))                  AS conversation_count,
    CAST(NULL AS Nullable(UInt32))                  AS message_count,
    toUInt64(coalesce(uncached_input_tokens, 0)
           + coalesce(cache_read_tokens, 0)
           + coalesce(cache_creation_5m_tokens, 0)
           + coalesce(cache_creation_1h_tokens, 0)) AS input_tokens,
    toUInt64(coalesce(output_tokens, 0))            AS output_tokens,
    toUInt64(coalesce(cache_read_tokens, 0))        AS cache_read_tokens,
    toUInt64(coalesce(cache_creation_5m_tokens, 0)
           + coalesce(cache_creation_1h_tokens, 0)) AS cache_creation_tokens,
    CAST(NULL AS Nullable(Decimal(18, 4)))          AS cost_amount,
    CAST(NULL AS Nullable(String))                  AS cost_currency,
    'claude_admin'                                  AS source,
    'insight_claude_admin'                          AS data_source,
    CAST(parseDateTime64BestEffortOrNull(coalesce(collected_at, ''), 3) AS Nullable(DateTime64(3))) AS collected_at
FROM {{ source('bronze_claude_admin', 'claude_admin_messages_usage') }}
{% if is_incremental() %}
WHERE toDate(date) > (
    SELECT coalesce(max(day), toDate('1970-01-01')) - INTERVAL 3 DAY
    FROM {{ this }}
)
{% endif %}
