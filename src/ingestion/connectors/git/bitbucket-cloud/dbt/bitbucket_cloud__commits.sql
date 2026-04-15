{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='staging',
    tags=['bitbucket-cloud', 'silver:class_git_commits']
) }}

SELECT
    c.tenant_id,
    c.source_id,
    c.unique_key,
    COALESCE(c.workspace, '') AS project_key,
    COALESCE(c.repo_slug, '') AS repo_slug,
    COALESCE(c.hash, '') AS commit_hash,
    COALESCE(c.branch_name, '') AS branch,
    COALESCE(c.author_name, '') AS author_name,
    COALESCE(c.author_email, '') AS author_email,
    '' AS committer_name,
    '' AS committer_email,
    COALESCE(c.message, '') AS message,
    parseDateTimeBestEffortOrNull(c.date) AS date,
    COALESCE(fc.files_changed, 0) AS files_changed,
    COALESCE(fc.lines_added, 0) AS lines_added,
    COALESCE(fc.lines_removed, 0) AS lines_removed,
    if(JSONLength(COALESCE(c.parent_hashes, '[]')) > 1, 1, 0) AS is_merge_commit,
    'insight_bitbucket_cloud' AS data_source,
    toUnixTimestamp64Milli(now64()) AS _version,
    c._airbyte_extracted_at
FROM {{ source('bronze_bitbucket_cloud', 'commits') }} AS c
LEFT JOIN (
    SELECT
        sha,
        count() AS files_changed,
        SUM(COALESCE(additions, 0)) AS lines_added,
        SUM(COALESCE(deletions, 0)) AS lines_removed
    FROM {{ source('bronze_bitbucket_cloud', 'file_changes') }}
    GROUP BY sha
) AS fc ON fc.sha = c.hash
{% if is_incremental() %}
WHERE c._airbyte_extracted_at > (SELECT max(_airbyte_extracted_at) FROM {{ this }})
{% endif %}
