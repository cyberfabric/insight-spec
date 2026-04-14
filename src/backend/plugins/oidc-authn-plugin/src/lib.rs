//! OIDC/JWT authentication plugin for cyberfabric `authn-resolver`.
//!
//! Validates JWT bearer tokens against an OIDC provider (Okta, Keycloak, Auth0, etc.)
//! using JWKS key discovery and standard JWT claims validation.
//!
//! Implements `AuthNResolverPluginClient` trait from `authn-resolver-sdk`.

pub mod config;
pub mod domain;
pub mod module;

pub use module::OidcAuthnPlugin;
