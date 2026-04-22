{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='staging',
    tags=['cursor', 'identity', 'identity:input']
) }}

{{ identity_input_from_history(
    fields_history_ref=ref('cursor__members_history'),
    source_type='cursor',
    identity_fields=[
        {'field': 'email', 'field_type': 'email', 'field_path': 'bronze_cursor.cursor_members.email'},
        {'field': 'name', 'field_type': 'display_name', 'field_path': 'bronze_cursor.cursor_members.name'},
    ],
    deactivation_condition="field_name = 'isRemoved' AND new_value = 'true'"
) }}
