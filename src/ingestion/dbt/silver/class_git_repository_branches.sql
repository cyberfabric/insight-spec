-- depends_on: {{ ref('github__repository_branches') }}
{{ config(
    materialized='incremental',
    unique_key='unique_key',
    schema='silver',
    tags=['silver']
) }}

{{ union_by_tag('silver:class_git_repository_branches') }}
