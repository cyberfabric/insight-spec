{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='staging',
    tags=['zoom', 'identity', 'identity:input']
) }}

{{ identity_input_from_history(
    fields_history_ref=ref('zoom__users_fields_history'),
    source_type='zoom',
    identity_fields=[
        {'field': 'email', 'field_type': 'email', 'field_path': 'bronze_zoom.users.email'},
        {'field': 'employee_unique_id', 'field_type': 'employee_id', 'field_path': 'bronze_zoom.users.employee_unique_id'},
        {'field': 'display_name', 'field_type': 'display_name', 'field_path': 'bronze_zoom.users.display_name'},
    ],
    deactivation_condition="field_name = 'status' AND new_value = 'inactive'"
) }}
