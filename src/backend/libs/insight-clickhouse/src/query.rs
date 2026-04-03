//! Tenant-scoped, parameterized query builder.
//!
//! All values are passed via bind parameters — no string interpolation.
//! The builder always starts with `WHERE tenant_id = ?` to enforce tenant isolation.

use std::time::Duration;

use clickhouse::Row;
use uuid::Uuid;

use crate::{Client, Error};

/// A parameterized query builder that enforces tenant isolation.
///
/// Created via [`Client::tenant_query`]. Automatically scopes all queries
/// to a single tenant and applies query timeout.
///
/// # Example
///
/// ```rust,ignore
/// let rows: Vec<Metric> = client
///     .tenant_query("gold.pr_cycle_time", tenant_id)
///     .filter("org_unit_id = ?", org_unit_id)
///     .filter("metric_date >= ?", start_date)
///     .order_by("metric_date DESC")
///     .limit(100)
///     .fetch_all()
///     .await?;
/// ```
pub struct QueryBuilder {
    client: Client,
    table: String,
    tenant_id: Uuid,
    filters: Vec<String>,
    bind_values: Vec<BindValue>,
    order_by: Option<String>,
    limit: Option<u64>,
    offset: Option<u64>,
    select: Option<String>,
    query_timeout: Option<Duration>,
}

/// Internal enum for bind values.
/// The `clickhouse` crate uses typed `.bind()`, so we store them
/// and apply in order during query construction.
enum BindValue {
    Uuid(Uuid),
    String(String),
    I64(i64),
    F64(f64),
}

impl QueryBuilder {
    pub(crate) fn new(
        client: Client,
        table: &str,
        tenant_id: Uuid,
        query_timeout: Option<Duration>,
    ) -> Self {
        Self {
            client,
            table: table.to_owned(),
            tenant_id,
            filters: Vec::new(),
            bind_values: Vec::new(),
            order_by: None,
            limit: None,
            offset: None,
            select: None,
            query_timeout,
        }
    }

    /// Adds a filter condition. The condition **must** use `?` for values.
    ///
    /// Appended as `AND {condition}` after the automatic `tenant_id` filter.
    #[must_use]
    pub fn filter_uuid(mut self, condition: &str, value: Uuid) -> Self {
        self.filters.push(condition.to_owned());
        self.bind_values.push(BindValue::Uuid(value));
        self
    }

    /// Adds a string filter condition.
    #[must_use]
    pub fn filter_str(mut self, condition: &str, value: impl Into<String>) -> Self {
        self.filters.push(condition.to_owned());
        self.bind_values.push(BindValue::String(value.into()));
        self
    }

    /// Adds an integer filter condition.
    #[must_use]
    pub fn filter_i64(mut self, condition: &str, value: i64) -> Self {
        self.filters.push(condition.to_owned());
        self.bind_values.push(BindValue::I64(value));
        self
    }

    /// Adds a float filter condition.
    #[must_use]
    pub fn filter_f64(mut self, condition: &str, value: f64) -> Self {
        self.filters.push(condition.to_owned());
        self.bind_values.push(BindValue::F64(value));
        self
    }

    /// Sets the ORDER BY clause. Value is used as-is (column names only,
    /// no user input).
    #[must_use]
    pub fn order_by(mut self, clause: &str) -> Self {
        self.order_by = Some(clause.to_owned());
        self
    }

    /// Sets the LIMIT.
    #[must_use]
    pub fn limit(mut self, n: u64) -> Self {
        self.limit = Some(n);
        self
    }

    /// Sets the OFFSET.
    #[must_use]
    pub fn offset(mut self, n: u64) -> Self {
        self.offset = Some(n);
        self
    }

    /// Sets the SELECT columns. Default is `*`.
    #[must_use]
    pub fn select(mut self, columns: &str) -> Self {
        self.select = Some(columns.to_owned());
        self
    }

    /// Builds the SQL string (for debugging). Values are shown as `?`.
    #[must_use]
    pub fn to_sql(&self) -> String {
        use std::fmt::Write;

        let select = self.select.as_deref().unwrap_or("*");
        let mut sql = format!("SELECT {select} FROM {} WHERE tenant_id = ?", self.table);

        for filter in &self.filters {
            let _ = write!(sql, " AND {filter}");
        }

        if let Some(order) = &self.order_by {
            let _ = write!(sql, " ORDER BY {order}");
        }

        if let Some(limit) = self.limit {
            let _ = write!(sql, " LIMIT {limit}");
        }

        if let Some(offset) = self.offset {
            let _ = write!(sql, " OFFSET {offset}");
        }

        sql
    }

    /// Executes the query and returns all matching rows.
    ///
    /// # Errors
    ///
    /// Returns [`Error`] if the query fails or times out.
    pub async fn fetch_all<T>(self) -> Result<Vec<T>, Error>
    where
        T: Row + for<'a> Row<Value<'a> = T> + for<'de> serde::Deserialize<'de> + 'static,
    {
        let sql = self.to_sql();
        tracing::debug!(sql = %sql, "executing tenant-scoped query");

        let mut query = self.client.inner().query(&sql);

        if let Some(timeout) = self.query_timeout {
            query = query.with_option("max_execution_time", timeout.as_secs().to_string());
        }

        // Bind tenant_id first (always the first `?`)
        query = query.bind(self.tenant_id);

        // Bind additional filter values in order
        for value in self.bind_values {
            query = match value {
                BindValue::Uuid(v) => query.bind(v),
                BindValue::String(v) => query.bind(v.as_str()),
                BindValue::I64(v) => query.bind(v),
                BindValue::F64(v) => query.bind(v),
            };
        }

        let rows = query.fetch_all().await?;
        Ok(rows)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Config;

    fn test_client() -> Client {
        Client::new(Config::new("http://localhost:8123", "test_db"))
    }

    fn test_tenant_id() -> Uuid {
        Uuid::parse_str("11111111-1111-1111-1111-111111111111")
            .unwrap_or_else(|e| panic!("invalid test UUID: {e}"))
    }

    #[test]
    fn bare_query_has_tenant_filter() {
        let sql = test_client()
            .tenant_query("gold.metrics", test_tenant_id())
            .to_sql();

        assert_eq!(sql, "SELECT * FROM gold.metrics WHERE tenant_id = ?");
    }

    #[test]
    fn select_columns() {
        let sql = test_client()
            .tenant_query("gold.metrics", test_tenant_id())
            .select("name, value, created_at")
            .to_sql();

        assert_eq!(
            sql,
            "SELECT name, value, created_at FROM gold.metrics WHERE tenant_id = ?"
        );
    }

    #[test]
    fn single_uuid_filter() {
        let org_id = Uuid::parse_str("22222222-2222-2222-2222-222222222222")
            .unwrap_or_else(|e| panic!("invalid test UUID: {e}"));

        let sql = test_client()
            .tenant_query("silver.class_commits", test_tenant_id())
            .filter_uuid("org_unit_id = ?", org_id)
            .to_sql();

        assert_eq!(
            sql,
            "SELECT * FROM silver.class_commits WHERE tenant_id = ? AND org_unit_id = ?"
        );
    }

    #[test]
    fn multiple_filters_appended_with_and() {
        let org_id = Uuid::parse_str("22222222-2222-2222-2222-222222222222")
            .unwrap_or_else(|e| panic!("invalid test UUID: {e}"));

        let sql = test_client()
            .tenant_query("gold.pr_cycle_time", test_tenant_id())
            .filter_uuid("org_unit_id = ?", org_id)
            .filter_str("metric_date >= ?", "2026-01-01")
            .filter_str("metric_date < ?", "2026-04-01")
            .to_sql();

        assert_eq!(
            sql,
            "SELECT * FROM gold.pr_cycle_time WHERE tenant_id = ? \
             AND org_unit_id = ? AND metric_date >= ? AND metric_date < ?"
        );
    }

    #[test]
    fn order_by_clause() {
        let sql = test_client()
            .tenant_query("gold.metrics", test_tenant_id())
            .order_by("created_at DESC")
            .to_sql();

        assert_eq!(
            sql,
            "SELECT * FROM gold.metrics WHERE tenant_id = ? ORDER BY created_at DESC"
        );
    }

    #[test]
    fn limit_and_offset() {
        let sql = test_client()
            .tenant_query("gold.metrics", test_tenant_id())
            .limit(25)
            .offset(50)
            .to_sql();

        assert_eq!(
            sql,
            "SELECT * FROM gold.metrics WHERE tenant_id = ? LIMIT 25 OFFSET 50"
        );
    }

    #[test]
    fn full_query_with_all_clauses() {
        let org_id = Uuid::parse_str("33333333-3333-3333-3333-333333333333")
            .unwrap_or_else(|e| panic!("invalid test UUID: {e}"));

        let sql = test_client()
            .tenant_query("gold.pr_cycle_time", test_tenant_id())
            .select("person_id, avg_hours, metric_date")
            .filter_uuid("org_unit_id = ?", org_id)
            .filter_str("metric_date >= ?", "2026-01-01")
            .filter_i64("avg_hours > ?", 48)
            .order_by("avg_hours DESC")
            .limit(100)
            .offset(0)
            .to_sql();

        assert_eq!(
            sql,
            "SELECT person_id, avg_hours, metric_date \
             FROM gold.pr_cycle_time WHERE tenant_id = ? \
             AND org_unit_id = ? AND metric_date >= ? AND avg_hours > ? \
             ORDER BY avg_hours DESC LIMIT 100 OFFSET 0"
        );
    }

    #[test]
    fn tenant_id_is_always_first_filter() {
        // Even with no additional filters, tenant_id is present
        let sql = test_client()
            .tenant_query("silver.class_people", test_tenant_id())
            .to_sql();

        assert!(sql.contains("WHERE tenant_id = ?"));
        // tenant_id should be the ONLY condition
        assert!(!sql.contains("AND"));
    }

    #[test]
    fn float_filter() {
        let sql = test_client()
            .tenant_query("gold.metrics", test_tenant_id())
            .filter_f64("value > ?", 99.5)
            .to_sql();

        assert_eq!(
            sql,
            "SELECT * FROM gold.metrics WHERE tenant_id = ? AND value > ?"
        );
    }

    #[test]
    fn limit_only_no_offset() {
        let sql = test_client()
            .tenant_query("gold.metrics", test_tenant_id())
            .limit(10)
            .to_sql();

        assert_eq!(
            sql,
            "SELECT * FROM gold.metrics WHERE tenant_id = ? LIMIT 10"
        );
        assert!(!sql.contains("OFFSET"));
    }

    #[test]
    fn order_before_limit() {
        let sql = test_client()
            .tenant_query("gold.metrics", test_tenant_id())
            .order_by("name ASC")
            .limit(50)
            .to_sql();

        let order_pos = sql.find("ORDER BY").unwrap_or_else(|| panic!("missing ORDER BY"));
        let limit_pos = sql.find("LIMIT").unwrap_or_else(|| panic!("missing LIMIT"));
        assert!(order_pos < limit_pos, "ORDER BY must come before LIMIT");
    }

    #[test]
    fn different_tables_produce_different_sql() {
        let tenant = test_tenant_id();
        let client = test_client();

        let sql_silver = client.tenant_query("silver.class_commits", tenant).to_sql();
        let sql_gold = client.tenant_query("gold.pr_cycle_time", tenant).to_sql();

        assert!(sql_silver.contains("silver.class_commits"));
        assert!(sql_gold.contains("gold.pr_cycle_time"));
        assert_ne!(sql_silver, sql_gold);
    }
}
