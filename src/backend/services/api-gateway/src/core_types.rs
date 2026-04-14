//! Core GTS types registration module.
//!
//! Replaces the unpublished `types` module from cyberfabric-core.
//! Registers the base GTS schemas (embedded in `modkit`) with the types-registry
//! so that plugin modules can register their instances.
//!
//! Dependency chain: `types-registry` → `core-types` → plugin modules

use async_trait::async_trait;
use modkit::contracts::SystemCapability;
use modkit::gts::get_core_gts_schemas;
use modkit::{Module, ModuleCtx};
use tracing::info;
use types_registry_sdk::TypesRegistryClient;

/// Core types registration module.
///
/// Registers `BaseModkitPluginV1` and other core GTS schemas that
/// all plugin modules depend on.
#[modkit::module(
    name = "core-types",
    deps = ["types-registry"],
    capabilities = [system]
)]
pub struct CoreTypes;

impl Default for CoreTypes {
    fn default() -> Self {
        Self
    }
}

#[async_trait]
impl Module for CoreTypes {
    async fn init(&self, ctx: &ModuleCtx) -> anyhow::Result<()> {
        let registry = ctx.client_hub().get::<dyn TypesRegistryClient>()?;

        let core_schemas = get_core_gts_schemas()?;
        registry
            .register(core_schemas)
            .await
            .map_err(|e| anyhow::anyhow!("failed to register core GTS schemas: {e}"))?;

        info!("core GTS schemas registered");
        Ok(())
    }
}

#[async_trait]
impl SystemCapability for CoreTypes {}
