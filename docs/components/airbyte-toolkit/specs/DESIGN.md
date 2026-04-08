# Technical Design — Airbyte Toolkit


<!-- toc -->

- [1. Architecture Overview](#1-architecture-overview)
  - [1.1 Architectural Vision](#11-architectural-vision)
  - [1.2 Architecture Drivers](#12-architecture-drivers)
  - [1.3 Architecture Layers](#13-architecture-layers)
- [2. Principles & Constraints](#2-principles--constraints)
  - [2.1 Design Principles](#21-design-principles)
  - [2.2 Constraints](#22-constraints)
- [3. Technical Architecture](#3-technical-architecture)
  - [3.1 Domain Model](#31-domain-model)
  - [3.2 Component Model](#32-component-model)
  - [3.3 API Contracts](#33-api-contracts)
  - [3.4 Internal Dependencies](#34-internal-dependencies)
  - [3.5 External Dependencies](#35-external-dependencies)
  - [3.6 Interactions & Sequences](#36-interactions--sequences)
  - [3.7 Database schemas & tables](#37-database-schemas--tables)
  - [3.8 Deployment Topology](#38-deployment-topology)
- [4. Additional context](#4-additional-context)
  - [Migration from old scripts](#migration-from-old-scripts)
  - [State library API](#state-library-api)
- [5. Traceability](#5-traceability)

<!-- /toc -->

- [ ] `p3` - **ID**: `cpt-insightspec-design-airbyte-toolkit`
## 1. Architecture Overview

### 1.1 Architectural Vision

Airbyte Toolkit is a self-contained module within `src/ingestion/airbyte-toolkit/` that owns all Airbyte API interactions and resource state. It exposes shell scripts as the public interface and stores state in a single hierarchical YAML file.

The design prioritizes deterministic state access: every Airbyte resource ID is reachable via a fixed YAML path known at call time, with no string concatenation, prefix matching, or naming convention translation. The module auto-detects its runtime environment (host vs in-cluster) and resolves API endpoints and credentials accordingly.

All operations are idempotent. Creating a resource that already exists in state updates it; deleting a resource not found in Airbyte cleans the stale state entry. This makes the toolkit safe to call repeatedly from CI/CD or manual recovery flows.

### 1.2 Architecture Drivers

#### Functional Drivers

| Requirement | Design Response |
|-------------|------------------|
| `cpt-insightspec-fr-single-state` | One file at `airbyte-toolkit/state.yaml`, all scripts read/write it |
| `cpt-insightspec-fr-hierarchical-state` | YAML tree with separate levels for connector name and source-id |
| `cpt-insightspec-fr-tenant-key` | Tenant key stored as-is from config filename |
| `cpt-insightspec-fr-idempotent` | All commands use create-or-update pattern with state-tracked IDs |
| `cpt-insightspec-fr-register-definitions` | `register.sh` writes to `definitions.{connector}.id` |
| `cpt-insightspec-fr-create-connections` | `connect.sh` writes to `tenants.{tenant}.connectors.{connector}.{source_id}` |

#### NFR Allocation

| NFR ID | NFR Summary | Allocated To | Design Response | Verification Approach |
|--------|-------------|--------------|-----------------|----------------------|
| `cpt-insightspec-nfr-dual-runtime` | Host and in-cluster execution | `lib/env.sh` | Auto-detect via service account token presence; set API URL and auth accordingly | Manual test on host + in-cluster job |

### 1.3 Architecture Layers

```
src/ingestion/airbyte-toolkit/
├── state.yaml          ← single state file (gitignored)
├── lib/
│   ├── state.sh        ← state read/write library
│   └── env.sh          ← environment resolution (API URL, JWT, workspace)
├── register.sh         ← register source definitions
├── connect.sh          ← create sources + connections per tenant
├── sync-state.sh       ← rebuild state from Airbyte API
└── cleanup.sh          ← delete resources by state
```

- [ ] `p3` - **ID**: `cpt-insightspec-tech-toolkit-layout`

| Layer | Responsibility | Technology |
|-------|---------------|------------|
| CLI | User-facing scripts, argument parsing | Bash |
| Library | State I/O, environment resolution, API helpers | Bash + Python (inline) |
| State | Persistent storage of Airbyte resource IDs | YAML file + K8s ConfigMap |
| External | Airbyte REST API, K8s API | HTTP/JSON, kubectl |

## 2. Principles & Constraints

### 2.1 Design Principles

#### Deterministic access paths

- [ ] `p2` - **ID**: `cpt-insightspec-principle-deterministic-paths`

Every resource ID in the state file is accessed via a path that can be constructed from the operation's input parameters alone. No searching, no iteration, no pattern matching.

#### No string concatenation for keys

- [ ] `p2` - **ID**: `cpt-insightspec-principle-no-concat`

Composite identity (connector + source-id, connector + tenant) is expressed as nested YAML levels, never as concatenated strings. `bamboohr.bamboohr-main` is two map levels, not `bamboohr-bamboohr-main` as one key.

#### State as source of truth

- [ ] `p2` - **ID**: `cpt-insightspec-principle-state-truth`

Scripts identify Airbyte resources by UUID from state — never by name. If the UUID returns 404 from Airbyte, the stale entry is removed and the resource is recreated.

### 2.2 Constraints

#### Single workspace

- [ ] `p2` - **ID**: `cpt-insightspec-constraint-single-workspace`

The toolkit assumes one Airbyte workspace per cluster (the default workspace created by the Helm chart). Multi-workspace support is not planned.

#### Shared destination

- [ ] `p2` - **ID**: `cpt-insightspec-constraint-shared-dest`

All connections use a single shared ClickHouse destination. Per-connector Bronze databases are controlled via `namespaceFormat` on the connection, not via separate destinations.

## 3. Technical Architecture

### 3.1 Domain Model

**Core Entities**:

| Entity | Description | Identity |
|--------|-------------|----------|
| Definition | Registered connector type in Airbyte | `definitions.{connector}.id` |
| Source | Configured connector instance with credentials | `tenants.{tenant}.connectors.{connector}.{source_id}.source_id` |
| Connection | Source-to-destination link with stream selection | `tenants.{tenant}.connectors.{connector}.{source_id}.connection_id` |
| Destination | Shared ClickHouse target | `destinations.{name}.id` |

**Relationships**:
- Definition 1→N Source: each source references a definition
- Source 1→1 Connection: each source has exactly one connection
- Connection N→1 Destination: all connections share one destination

### 3.2 Component Model

#### State Manager

- [ ] `p2` - **ID**: `cpt-insightspec-component-state-manager`

##### Why this component exists

Provides atomic read/write access to the state file. All other components use it instead of accessing the file directly.

##### Responsibility scope

- Read/write individual values by YAML path.
- Read entire state for iteration.
- Persist to file and (optionally) K8s ConfigMap.
- Initialize empty state file if missing.

##### Responsibility boundaries

- Does NOT interact with Airbyte API.
- Does NOT validate that IDs exist in Airbyte.

##### Related components (by ID)

None — State Manager is a leaf dependency used by all other components.

#### Environment Resolver

- [ ] `p2` - **ID**: `cpt-insightspec-component-env-resolver`

##### Why this component exists

Centralizes runtime detection and credential resolution. Eliminates duplicated env resolution across scripts.

##### Responsibility scope

- Detect host vs in-cluster runtime.
- Read Airbyte auth secrets from K8s.
- Mint JWT token for API access.
- Resolve workspace ID.
- Export: `AIRBYTE_API`, `AIRBYTE_TOKEN`, `WORKSPACE_ID`.

##### Responsibility boundaries

- Does NOT manage state.
- Does NOT create Airbyte resources.

##### Related components (by ID)

- `cpt-insightspec-component-state-manager` — depends on (reads `workspace_id` from state for caching)

#### Definition Registrar

- [ ] `p2` - **ID**: `cpt-insightspec-component-registrar`

##### Why this component exists

Registers connector manifests as Airbyte source definitions.

##### Responsibility scope

- Read `connector.yaml` manifests from `connectors/` directory.
- Create or update Airbyte source definitions via API.
- Store `definition_id` in state via State Manager.

##### Responsibility boundaries

- Does NOT create sources or connections.
- Does NOT read tenant configs.

##### Related components (by ID)

- `cpt-insightspec-component-state-manager` — depends on (writes definition IDs)
- `cpt-insightspec-component-env-resolver` — depends on (API credentials)

#### Connection Manager

- [ ] `p2` - **ID**: `cpt-insightspec-component-connection-mgr`

##### Why this component exists

Creates and updates sources, destinations, and connections for a tenant.

##### Responsibility scope

- Read tenant config (`connections/{tenant}.yaml`).
- Discover K8s Secrets for connector credentials.
- Create/update shared ClickHouse destination.
- Create/update sources (one per connector + source-id).
- Discover schema from source.
- Create/update connections with stream selection.
- Store all IDs in state via State Manager.
- Create Bronze databases in ClickHouse.

##### Responsibility boundaries

- Does NOT register definitions (assumes they exist in state).
- Does NOT manage Argo workflows.

##### Related components (by ID)

- `cpt-insightspec-component-state-manager` — depends on (reads definitions, writes sources/connections)
- `cpt-insightspec-component-env-resolver` — depends on (API credentials)
- `cpt-insightspec-component-registrar` — depends on (definition IDs must exist)

### 3.3 API Contracts

- [ ] `p2` - **ID**: `cpt-insightspec-interface-state-yaml`

- **Contracts**: `cpt-insightspec-contract-airbyte-api`
- **Technology**: YAML file (state format)

**State file schema** (`airbyte-toolkit/state.yaml`):

```yaml
workspace_id: "<uuid>"

destinations:
  clickhouse:
    id: "<uuid>"

definitions:
  m365:
    id: "<uuid>"
  zoom:
    id: "<uuid>"
  bamboohr:
    id: "<uuid>"

tenants:
  example-tenant:                     # matches connections/example-tenant.yaml filename
    connectors:
      m365:                           # connector name from descriptor.yaml
        m365-main:                    # source-id from K8s Secret annotation
          source_id: "<uuid>"
          connection_id: "<uuid>"
      zoom:
        zoom-main:
          source_id: "<uuid>"
          connection_id: "<uuid>"
      bamboohr:
        bamboohr-main:
          source_id: "<uuid>"
          connection_id: "<uuid>"
```

**Access paths** (all deterministic, no search):

| What | Path | Inputs |
|------|------|--------|
| Workspace | `workspace_id` | none |
| Destination | `destinations.clickhouse.id` | none |
| Definition | `definitions.{connector}.id` | connector name |
| Source | `tenants.{tenant}.connectors.{connector}.{source_id}.source_id` | tenant, connector, source_id |
| Connection | `tenants.{tenant}.connectors.{connector}.{source_id}.connection_id` | tenant, connector, source_id |
| All connections for tenant | `tenants.{tenant}.connectors` | tenant |

### 3.4 Internal Dependencies

| Dependency Module | Interface Used | Purpose |
|-------------------|----------------|----------|
| `connectors/*/descriptor.yaml` | File read | Connector name, schedule, streams config |
| `connectors/*/connector.yaml` | File read | Airbyte manifest for definition registration |
| `connections/*.yaml` | File read | Tenant config (tenant_id) |

### 3.5 External Dependencies

#### Airbyte API

| Dependency Module | Interface Used | Purpose |
|-------------------|---------------|---------|
| Airbyte Server | REST API (`/api/v1/*`) | CRUD for definitions, sources, destinations, connections |

#### Kubernetes API

| Dependency Module | Interface Used | Purpose |
|-------------------|---------------|---------|
| K8s Secrets | `kubectl get secret` | Read Airbyte auth credentials, connector credentials, ClickHouse password |
| K8s ConfigMap | `kubectl create configmap` | Persist state in-cluster |

#### ClickHouse

| Dependency Module | Interface Used | Purpose |
|-------------------|---------------|---------|
| ClickHouse | `kubectl exec clickhouse-client` | Create Bronze databases (`CREATE DATABASE IF NOT EXISTS`) |

### 3.6 Interactions & Sequences

#### Register connector definitions

**ID**: `cpt-insightspec-seq-register`

**Use cases**: `cpt-insightspec-usecase-new-connector`

**Actors**: `cpt-insightspec-actor-platform-engineer`

```
Engineer -> register.sh: register.sh m365
register.sh -> env.sh: source (resolve API, token)
register.sh -> connectors/: read connector.yaml
register.sh -> Airbyte API: POST /source_definitions/create (or update)
Airbyte API --> register.sh: definition_id
register.sh -> state.sh: write definitions.m365.id
```

#### Create connections for tenant

**ID**: `cpt-insightspec-seq-connect`

**Use cases**: `cpt-insightspec-usecase-new-connector`

**Actors**: `cpt-insightspec-actor-platform-engineer`

```
Engineer -> connect.sh: connect.sh example-tenant
connect.sh -> env.sh: source (resolve API, token)
connect.sh -> state.sh: read definitions (verify registered)
connect.sh -> K8s API: discover Secrets by label
connect.sh -> ClickHouse: CREATE DATABASE IF NOT EXISTS bronze_{connector}
connect.sh -> Airbyte API: create/update destination
connect.sh -> state.sh: write destinations.clickhouse.id
  for each connector+source_id:
    connect.sh -> Airbyte API: create/update source
    connect.sh -> Airbyte API: discover schema
    connect.sh -> Airbyte API: create/update connection
    connect.sh -> state.sh: write tenants.{tenant}.connectors.{connector}.{source_id}
```

### 3.7 Database schemas & tables

Not applicable. The toolkit manages Airbyte resources, not database schemas. Bronze databases are created as empty databases; table creation is handled by Airbyte sync.

### 3.8 Deployment Topology

The toolkit is not deployed as a service. It is a set of scripts invoked from:
- **Host**: during `init.sh`, manual operations, CI/CD.
- **In-cluster**: K8s Job running the toolbox image (future, currently host-only after refactor).

State persistence:
- **Host**: `airbyte-toolkit/state.yaml` (local file).
- **In-cluster**: K8s ConfigMap `airbyte-state` in namespace `data` (synced on write).

## 4. Additional context

### Migration from old scripts

Old scripts to delete after toolkit is operational:

| Old script | Replaced by |
|------------|-------------|
| `scripts/airbyte-state.sh` | `airbyte-toolkit/lib/state.sh` |
| `scripts/sync-airbyte-state.sh` | `airbyte-toolkit/sync-state.sh` |
| `scripts/resolve-airbyte-env.sh` | `airbyte-toolkit/lib/env.sh` |
| `scripts/upload-manifests.sh` | `airbyte-toolkit/register.sh` |
| `scripts/apply-connections.sh` | `airbyte-toolkit/connect.sh` |

State files to delete:
- `connections/.airbyte-state.yaml`
- `connections/.state/` directory

Consumers to update:

| Consumer | Change |
|----------|--------|
| `run-sync.sh` | Read `tenants.{tenant}.connectors.{connector}.{source_id}.connection_id` from `airbyte-toolkit/state.yaml` |
| `sync-flows.sh` | Iterate `tenants.{tenant}.connectors` from `airbyte-toolkit/state.yaml` |
| `run-init.sh` | Call toolkit scripts instead of old scripts |
| `update-connectors.sh` | Call `airbyte-toolkit/register.sh` |
| `update-connections.sh` | Call `airbyte-toolkit/connect.sh` |
| `cleanup.sh` | Delete `airbyte-toolkit/state.yaml` instead of old files |
| `.gitignore` | Update paths |
| `.dockerignore` | Update paths |
| `README.md` | Update documentation |
| Connector SKILL.md | Update references |

### State library API

`lib/state.sh` exposes these functions when sourced:

| Function | Arguments | Description |
|----------|-----------|-------------|
| `state_get <path>` | Dot-separated YAML path | Returns value at path (empty string if missing) |
| `state_set <path> <value>` | Dot-separated YAML path, value | Sets value at path, creates intermediate maps |
| `state_delete <path>` | Dot-separated YAML path | Removes key at path |
| `state_list <path>` | Dot-separated YAML path to a map | Returns keys of the map |
| `state_dump` | none | Returns full state YAML |

All write operations persist to file and (if in-cluster) to ConfigMap atomically.

## 5. Traceability

- **PRD**: [PRD.md](./PRD.md)
- **ADRs**: [ADR/](./ADR/)
