{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='staging',
    tags=['slack', 'identity', 'identity:input']
) }}

{{ identity_input_from_history(
    fields_history_ref=ref('slack__users_fields_history'),
    source_type='slack',
    identity_fields=[
        {'field': 'email', 'field_type': 'email', 'field_path': 'bronze_slack.users_details.email_address'},
    ],
    deactivation_condition="field_name = 'is_billable_seat' AND new_value = 'false'"
) }}
