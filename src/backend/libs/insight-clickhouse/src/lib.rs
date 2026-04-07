//! Shared `ClickHouse` client for Insight backend services.
//!
//! Provides:
//! - [`Client`] — configured `ClickHouse` connection with tenant-scoped queries
//! - [`QueryBuilder`] — parameterized query builder (no string interpolation)
//! - [`Config`] — connection configuration
//! - [`Error`] — error types
//!
//! # Usage
//!
//! ```rust,ignore
//! use insight_clickhouse::{Client, Config};
//! use uuid::Uuid;
//!
//! let config = Config::new("http://localhost:8123", "insight");
//! let client = Client::new(config);
//!
//! let tenant_id = Uuid::now_v7();
//! let rows = client
//!     .query("SELECT ?fields FROM gold.pr_cycle_time WHERE tenant_id = ?")
//!     .bind(tenant_id)
//!     .fetch_all::<PrCycleTime>()
//!     .await?;
//! ```

pub mod config;
pub mod error;
pub mod query;

pub use config::Config;
pub use error::Error;
pub use query::QueryBuilder;

use clickhouse::Client as ChClient;

/// `ClickHouse` client wrapper with Insight-specific defaults.
///
/// Wraps the `clickhouse` crate client with:
/// - Preconfigured database and URL from [`Config`]
/// - Query timeout enforcement
/// - Tenant-scoped query builder via [`tenant_query`]
#[derive(Clone)]
pub struct Client {
    inner: ChClient,
    config: Config,
}

impl Client {
    /// Creates a new client from configuration.
    #[must_use]
    pub fn new(config: Config) -> Self {
        let mut inner = ChClient::default()
            .with_url(&config.url)
            .with_database(&config.database);

        if let Some(user) = &config.user {
            inner = inner.with_user(user);
        }
        if let Some(password) = &config.password {
            inner = inner.with_password(password);
        }

        Self { inner, config }
    }

    /// Returns a raw query handle for the given SQL.
    ///
    /// Use bind parameters (`?`) for all user-supplied values.
    /// **Never** interpolate values into the SQL string.
    ///
    /// # Errors
    ///
    /// Returns [`Error`] if the query fails.
    pub fn query(&self, sql: &str) -> clickhouse::query::Query {
        let mut q = self.inner.query(sql);
        if let Some(timeout) = self.config.query_timeout {
            q = q.with_option("max_execution_time", timeout.as_secs().to_string());
        }
        q
    }

    /// Returns a [`QueryBuilder`] scoped to the given tenant.
    ///
    /// The builder automatically adds `WHERE tenant_id = ?` and binds the
    /// tenant ID. All subsequent filters are appended with `AND`.
    ///
    /// # Errors
    ///
    /// Returns [`Error::InvalidQuery`] if the table name contains unsafe characters.
    pub fn tenant_query(&self, table: &str, tenant_id: uuid::Uuid) -> Result<QueryBuilder, Error> {
        QueryBuilder::new(self.clone(), table, tenant_id)
    }

    /// Returns the underlying `clickhouse` crate client for advanced usage.
    #[must_use]
    pub fn inner(&self) -> &ChClient {
        &self.inner
    }

    /// Returns the current configuration.
    #[must_use]
    pub fn config(&self) -> &Config {
        &self.config
    }
}
