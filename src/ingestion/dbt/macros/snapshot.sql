{% macro snapshot(source_ref, unique_key_col, check_cols, check_raw_data_cols=[]) %}
{#
  Incremental append-only SCD2 snapshot.
  Appends a new row only when tracked columns change.

  Args:
    source_ref:           source() or ref() to the raw table
    unique_key_col:       column that uniquely identifies an entity
    check_cols:           list of top-level columns to monitor for changes
    check_raw_data_cols:  list of field names inside `raw_data` JSON column to monitor
                          (extracted via JSONExtractString; missing keys yield '')

  Adds columns:
    _row_hash    — cityHash64 of tracked columns (for comparison)
    _tracked_at  — timestamp when the version was captured
#}

WITH source_data AS (
    SELECT
        *,
        cityHash64(
            {% for col in check_cols %}
            ifNull(toString({{ col }}), '__null__'),
            {% endfor %}
            {% for col in check_raw_data_cols %}
            JSONExtractString(ifNull(toString(raw_data), '{}'), '{{ col }}'){{ ',' if not loop.last }}
            {% endfor %}
            {% if not check_raw_data_cols %}
            ''
            {% endif %}
        ) AS _row_hash
    FROM {{ source_ref }}
)

{% if is_incremental() %}

, latest AS (
    SELECT
        {{ unique_key_col }},
        argMax(_row_hash, _tracked_at) AS _row_hash
    FROM {{ this }}
    GROUP BY {{ unique_key_col }}
)

SELECT
    s.*,
    now() AS _tracked_at
FROM source_data s
LEFT JOIN latest l ON s.{{ unique_key_col }} = l.{{ unique_key_col }}
WHERE l.{{ unique_key_col }} IS NULL
   OR s._row_hash != l._row_hash

{% else %}

SELECT
    *,
    now() AS _tracked_at
FROM source_data

{% endif %}

{% endmacro %}
