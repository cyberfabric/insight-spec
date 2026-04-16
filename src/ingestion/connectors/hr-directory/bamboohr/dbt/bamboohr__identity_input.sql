{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='staging',
    tags=['bamboohr', 'identity', 'identity:input']
) }}

{{ identity_input_from_history(
    fields_history_ref=ref('bamboohr__employees_fields_history'),
    source_type='bamboohr',
    identity_fields=[
        {'field': 'workEmail', 'field_type': 'email', 'field_path': 'bronze_bamboohr.employees.workEmail'},
        {'field': 'employeeNumber', 'field_type': 'employee_id', 'field_path': 'bronze_bamboohr.employees.employeeNumber'},
        {'field': 'displayName', 'field_type': 'display_name', 'field_path': 'bronze_bamboohr.employees.displayName'},
    ],
    deactivation_condition="field_name = 'status' AND new_value IN ('Inactive', 'Terminated')"
) }}
