//! Error types for the `ClickHouse` client.

/// Errors returned by the Insight `ClickHouse` client.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// `ClickHouse` client/protocol error.
    #[error("clickhouse error: {0}")]
    Clickhouse(#[from] clickhouse::error::Error),

    /// Query timed out.
    #[error("query timed out")]
    Timeout,

    /// Invalid query parameters.
    #[error("invalid query: {0}")]
    InvalidQuery(String),
}
