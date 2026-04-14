//! `AuthNResolverPluginClient` implementation for the OIDC plugin.

use std::sync::Arc;

use async_trait::async_trait;
use authn_resolver_sdk::error::AuthNResolverError;
use authn_resolver_sdk::models::{AuthenticationResult, ClientCredentialsRequest};
use authn_resolver_sdk::plugin_api::AuthNResolverPluginClient;

use super::service::OidcService;

/// Adapter implementing `AuthNResolverPluginClient` using the OIDC service.
pub struct OidcAuthnClient {
    service: Arc<OidcService>,
}

impl OidcAuthnClient {
    #[must_use]
    pub fn new(service: Arc<OidcService>) -> Self {
        Self { service }
    }
}

#[async_trait]
impl AuthNResolverPluginClient for OidcAuthnClient {
    async fn authenticate(
        &self,
        bearer_token: &str,
    ) -> Result<AuthenticationResult, AuthNResolverError> {
        let security_context = self
            .service
            .validate_token(bearer_token)
            .await
            .map_err(|e| {
                tracing::warn!(error = %e, "OIDC token validation failed");
                AuthNResolverError::Unauthorized(e.to_string())
            })?;

        Ok(AuthenticationResult { security_context })
    }

    async fn exchange_client_credentials(
        &self,
        _request: &ClientCredentialsRequest,
    ) -> Result<AuthenticationResult, AuthNResolverError> {
        // Client credentials flow not implemented for OIDC plugin.
        // S2S communication should use the static-authn-plugin or
        // a dedicated service account token.
        Err(AuthNResolverError::Unauthorized(
            "client_credentials flow not supported by OIDC plugin — use static-authn-plugin for S2S".to_owned(),
        ))
    }
}
