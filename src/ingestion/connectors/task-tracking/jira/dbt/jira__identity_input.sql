{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='staging',
    tags=['jira', 'identity', 'identity:input']
) }}

{{ identity_input_from_history(
    fields_history_ref=ref('jira__users_fields_history'),
    source_type='jira',
    identity_fields=[
        {'field': 'email', 'field_type': 'email', 'field_path': 'bronze_jira.jira_user.email'},
        {'field': 'display_name', 'field_type': 'display_name', 'field_path': 'bronze_jira.jira_user.display_name'},
    ],
    deactivation_condition="field_name = 'active' AND new_value = 'false'"
) }}
