-- Identity input: unified view over all connector identity_input models.
-- Each connector writes its own staging.{connector}__identity_input table,
-- this view unions them all by tag.
--
-- Run: dbt run --select identity_input

{{ config(
    materialized='view',
    schema='identity',
    tags=['identity']
) }}

-- depends_on: {{ ref('bamboohr__identity_input') }}
-- depends_on: {{ ref('zoom__identity_input') }}

{{ union_by_tag('identity:input') }}
