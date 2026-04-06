/*
  Integration test for snapshot + fields_history macros with raw_data support.

  Flow:
    1. Build snapshot from seed v1 (initial load — 2 employees)
    2. Build snapshot from seed v2 (Alice: department, jobTitle, customTeamRD changed; Bob: unchanged)
    3. Build fields_history from snapshot
    4. Assert expected change records

  This test returns rows on FAILURE (dbt data test convention).
  Empty result = PASS.
*/

WITH snapshot_v1 AS (
    -- Simulate first snapshot run: all v1 rows get a hash and tracked_at
    SELECT
        *,
        cityHash64(
            ifNull(toString(displayName), '__null__'),
            ifNull(toString(firstName), '__null__'),
            ifNull(toString(lastName), '__null__'),
            ifNull(toString(workEmail), '__null__'),
            ifNull(toString(employeeNumber), '__null__'),
            ifNull(toString(jobTitle), '__null__'),
            ifNull(toString(department), '__null__'),
            ifNull(toString(division), '__null__'),
            ifNull(toString(status), '__null__'),
            ifNull(toString(employmentHistoryStatus), '__null__'),
            ifNull(toString(supervisorEId), '__null__'),
            ifNull(toString(supervisorEmail), '__null__'),
            ifNull(toString(location), '__null__'),
            ifNull(toString(country), '__null__'),
            ifNull(toString(city), '__null__'),
            ifNull(toString(hireDate), '__null__'),
            ifNull(toString(terminationDate), '__null__'),
            JSONExtractString(ifNull(toString(raw_data), '{}'), 'customTeamRD'),
            JSONExtractString(ifNull(toString(raw_data), '{}'), 'customProjects')
        ) AS _row_hash,
        toDateTime('2024-01-01 00:00:00') AS _tracked_at
    FROM {{ ref('fake_employees_v1') }}
),

snapshot_v2_candidates AS (
    -- Simulate second snapshot run: compute hash for v2
    SELECT
        *,
        cityHash64(
            ifNull(toString(displayName), '__null__'),
            ifNull(toString(firstName), '__null__'),
            ifNull(toString(lastName), '__null__'),
            ifNull(toString(workEmail), '__null__'),
            ifNull(toString(employeeNumber), '__null__'),
            ifNull(toString(jobTitle), '__null__'),
            ifNull(toString(department), '__null__'),
            ifNull(toString(division), '__null__'),
            ifNull(toString(status), '__null__'),
            ifNull(toString(employmentHistoryStatus), '__null__'),
            ifNull(toString(supervisorEId), '__null__'),
            ifNull(toString(supervisorEmail), '__null__'),
            ifNull(toString(location), '__null__'),
            ifNull(toString(country), '__null__'),
            ifNull(toString(city), '__null__'),
            ifNull(toString(hireDate), '__null__'),
            ifNull(toString(terminationDate), '__null__'),
            JSONExtractString(ifNull(toString(raw_data), '{}'), 'customTeamRD'),
            JSONExtractString(ifNull(toString(raw_data), '{}'), 'customProjects')
        ) AS _row_hash,
        toDateTime('2024-01-02 00:00:00') AS _tracked_at
    FROM {{ ref('fake_employees_v2') }}
),

-- Only rows where hash changed (incremental logic)
snapshot_v2_new AS (
    SELECT s2.*
    FROM snapshot_v2_candidates s2
    INNER JOIN snapshot_v1 s1 ON s2.unique_key = s1.unique_key
    WHERE s2._row_hash != s1._row_hash
),

-- Combined snapshot: v1 + changed rows from v2
combined_snapshot AS (
    SELECT * FROM snapshot_v1
    UNION ALL
    SELECT * FROM snapshot_v2_new
),

-- ===== ASSERTION 1: snapshot row counts =====
assert_snapshot_total AS (
    SELECT 'snapshot_total_rows' AS test_name,
           count() AS actual,
           3 AS expected
    FROM combined_snapshot
),

assert_alice_versions AS (
    SELECT 'alice_has_2_versions' AS test_name,
           count() AS actual,
           2 AS expected
    FROM combined_snapshot WHERE id = '101'
),

assert_bob_versions AS (
    SELECT 'bob_has_1_version' AS test_name,
           count() AS actual,
           1 AS expected
    FROM combined_snapshot WHERE id = '102'
),

-- ===== fields_history from combined snapshot =====
versioned AS (
    SELECT
        unique_key,
        id AS entity_id,
        tenant_id,
        source_id,
        toString(displayName) AS displayName,
        toString(firstName) AS firstName,
        toString(lastName) AS lastName,
        toString(workEmail) AS workEmail,
        toString(employeeNumber) AS employeeNumber,
        toString(jobTitle) AS jobTitle,
        toString(department) AS department,
        toString(division) AS division,
        toString(status) AS status,
        toString(employmentHistoryStatus) AS employmentHistoryStatus,
        toString(supervisorEId) AS supervisorEId,
        toString(supervisorEmail) AS supervisorEmail,
        toString(location) AS location,
        toString(country) AS country,
        toString(city) AS city,
        toString(hireDate) AS hireDate,
        toString(terminationDate) AS terminationDate,
        JSONExtractString(ifNull(toString(raw_data), '{}'), 'customTeamRD') AS customTeamRD,
        JSONExtractString(ifNull(toString(raw_data), '{}'), 'customProjects') AS customProjects,
        _tracked_at AS updated_at,
        ROW_NUMBER() OVER (PARTITION BY unique_key ORDER BY _tracked_at) AS version_num
    FROM combined_snapshot
),

consecutive AS (
    SELECT
        curr.entity_id,
        curr.tenant_id,
        curr.source_id,
        curr.updated_at,
        curr.department AS curr_department, prev.department AS prev_department,
        curr.jobTitle AS curr_jobTitle, prev.jobTitle AS prev_jobTitle,
        curr.customTeamRD AS curr_customTeamRD, prev.customTeamRD AS prev_customTeamRD,
        curr.customProjects AS curr_customProjects, prev.customProjects AS prev_customProjects,
        curr.displayName AS curr_displayName, prev.displayName AS prev_displayName
    FROM versioned curr
    INNER JOIN versioned prev
        ON curr.unique_key = prev.unique_key
        AND curr.version_num = prev.version_num + 1
),

changes AS (
    SELECT 'department' AS field_name, prev_department AS old_value, curr_department AS new_value, entity_id
    FROM consecutive WHERE curr_department != prev_department
    UNION ALL
    SELECT 'jobTitle', prev_jobTitle, curr_jobTitle, entity_id
    FROM consecutive WHERE curr_jobTitle != prev_jobTitle
    UNION ALL
    SELECT 'customTeamRD', prev_customTeamRD, curr_customTeamRD, entity_id
    FROM consecutive WHERE curr_customTeamRD != prev_customTeamRD
    UNION ALL
    SELECT 'customProjects', prev_customProjects, curr_customProjects, entity_id
    FROM consecutive WHERE curr_customProjects != prev_customProjects
    UNION ALL
    SELECT 'displayName', prev_displayName, curr_displayName, entity_id
    FROM consecutive WHERE curr_displayName != prev_displayName
),

-- ===== ASSERTION 2: fields_history change counts =====
assert_total_changes AS (
    SELECT 'total_change_records' AS test_name,
           count() AS actual,
           3 AS expected
    FROM changes
),

assert_dept_change AS (
    SELECT 'department_change_detected' AS test_name,
           count() AS actual,
           1 AS expected
    FROM changes
    WHERE field_name = 'department'
      AND old_value = 'Engineering'
      AND new_value = 'Platform Engineering'
      AND entity_id = '101'
),

assert_title_change AS (
    SELECT 'jobTitle_change_detected' AS test_name,
           count() AS actual,
           1 AS expected
    FROM changes
    WHERE field_name = 'jobTitle'
      AND old_value = 'Engineer'
      AND new_value = 'Senior Engineer'
      AND entity_id = '101'
),

assert_custom_change AS (
    SELECT 'customTeamRD_change_detected' AS test_name,
           count() AS actual,
           1 AS expected
    FROM changes
    WHERE field_name = 'customTeamRD'
      AND old_value = 'Platform'
      AND new_value = 'Infra'
      AND entity_id = '101'
),

assert_no_false_positive AS (
    SELECT 'no_customProjects_false_positive' AS test_name,
           count() AS actual,
           0 AS expected
    FROM changes
    WHERE field_name = 'customProjects'
),

assert_no_displayname_change AS (
    SELECT 'no_displayName_false_positive' AS test_name,
           count() AS actual,
           0 AS expected
    FROM changes
    WHERE field_name = 'displayName'
),

-- Collect all assertions — return only failures
all_assertions AS (
    SELECT * FROM assert_snapshot_total
    UNION ALL SELECT * FROM assert_alice_versions
    UNION ALL SELECT * FROM assert_bob_versions
    UNION ALL SELECT * FROM assert_total_changes
    UNION ALL SELECT * FROM assert_dept_change
    UNION ALL SELECT * FROM assert_title_change
    UNION ALL SELECT * FROM assert_custom_change
    UNION ALL SELECT * FROM assert_no_false_positive
    UNION ALL SELECT * FROM assert_no_displayname_change
)

-- dbt data test: any row returned = failure
SELECT test_name, actual, expected
FROM all_assertions
WHERE actual != expected
