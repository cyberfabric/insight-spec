{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['bitbucket-cloud', 'silver:class_git_pull_requests']
) }}

SELECT
    tenant_id,
    source_id,
    unique_key,
    COALESCE(workspace, '') AS project_key,
    COALESCE(repo_slug, '') AS repo_slug,
    COALESCE(id, 0) AS pr_id,
    COALESCE(id, 0) AS pr_number,
    COALESCE(title, '') AS title,
    COALESCE(description, '') AS description,
    multiIf(
        state = 'SUPERSEDED', 'DECLINED',
        COALESCE(state, '')
    ) AS state,
    COALESCE(author_display_name, '') AS author_name,
    '' AS author_email,
    COALESCE(source_branch, '') AS source_branch,
    COALESCE(destination_branch, '') AS destination_branch,
    parseDateTimeBestEffortOrNull(created_on) AS created_on,
    parseDateTimeBestEffortOrNull(updated_on) AS updated_on,
    parseDateTimeBestEffortOrNull(if(state IN ('MERGED', 'DECLINED', 'SUPERSEDED'), toString(updated_on), '')) AS closed_on,
    COALESCE(merge_commit_hash, '') AS merge_commit_hash,
    0 AS files_changed,
    0 AS lines_added,
    0 AS lines_removed,
    'insight_bitbucket_cloud' AS data_source,
    toUnixTimestamp64Milli(now64()) AS _version,
    _airbyte_extracted_at
FROM {{ source('bronze_bitbucket_cloud', 'pull_requests') }}
{% if is_incremental() %}
WHERE _airbyte_extracted_at > (SELECT max(_airbyte_extracted_at) FROM {{ this }})
{% endif %}
