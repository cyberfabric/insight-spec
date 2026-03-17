# Insight — Specification Repository

> Decision Intelligence Platform

This repository contains the full product specification for **Insight** — an extensible platform that collects operational metrics from across an organization's toolchain, resolves them to a unified data model, and delivers actionable analytics for productivity improvement, bottleneck detection, process performance tracking, and team health reviews.

<!-- toc -->

- [What Is Insight](#what-is-insight)
- [Architecture Overview](#architecture-overview)
- [Repository Structure](#repository-structure)
  - [docs/](#docs)
  - [inbox/](#inbox)
  - [cypilot/](#cypilot)
- [Connector Coverage](#connector-coverage)
- [Key Concepts](#key-concepts)
- [Working with This Repo](#working-with-this-repo)

<!-- /toc -->

---

## What Is Insight

Insight collects events and metrics from the tools teams already use — version control, task trackers, communication platforms, AI coding assistants, HR systems, and more — and unifies them into a single, identity-resolved data model.

**Primary use cases:**

| Use Case | Description |
|----------|-------------|
| **Process performance** | Cycle time, PR throughput, deployment frequency, task flow |
| **Productivity analytics** | Developer output, AI tool adoption, collaboration patterns |
| **Bottleneck detection** | Where work gets stuck across the delivery pipeline |
| **Team health** | Meeting load, async/sync balance, focus time |
| **Performance review** | Individual and team contribution signals across tools |
| **AI adoption tracking** | Usage, model distribution, and ROI across AI tools |

Insight is **not** a replacement for source systems — it reads from them, resolves identities, and provides a governed analytics layer on top.

---

## Architecture Overview

The platform has two independent layers:

```
┌─────────────────────────────────────────────────────────────┐
│                      Analytics Layer                         │
│   Dashboards · AI-powered exploration · Semantic governance  │
└────────────────────────┬────────────────────────────────────┘
                         │ data API
┌────────────────────────▼────────────────────────────────────┐
│                       Metrics Layer                          │
│                                                              │
│  Connectors → Bronze → Silver → Gold                         │
│                          ↑                                   │
│               Identity Resolution                            │
└──────────────────────────────────────────────────────────────┘
         ↑           ↑           ↑           ↑
      Git/VCS   Task Tracker  Comms/M365   AI Tools  ...
```

**Bronze → Silver → Gold pipeline:**

- **Bronze** — Raw, source-faithful tables. Field names and types preserved from the API. One table per entity type per source.
- **Silver Step 1** — Source tables unified into common schemas (e.g. `collab_chat_activity` merges Slack + Zulip + M365 Teams).
- **Silver Step 2** — Identity resolution: `email` / `login` / `user_id` resolved to canonical `person_id` via the Identity Manager.
- **Gold** — Aggregated, business-level metrics (cycle time, throughput, adoption rates, etc.).

---

## Repository Structure

### `docs/`

Canonical product and connector specifications.

```
docs/
├── CONNECTORS_REFERENCE.md       ← master Bronze schema reference for all sources
│
├── connectors/                   ← per-source connector specifications
│   ├── README.md                 ← connector index + unified streams table
│   ├── git/                      ← GitHub, Bitbucket Server, GitLab
│   ├── task-tracking/            ← YouTrack, Jira
│   ├── collaboration/            ← Microsoft 365, Slack, Zoom, Zulip
│   ├── wiki/                     ← Confluence, Outline
│   ├── support/                  ← Zendesk, Jira Service Management
│   ├── ai-dev/                   ← Cursor, Windsurf, GitHub Copilot, JetBrains
│   ├── ai/                       ← Claude API, Claude Team, OpenAI API, ChatGPT Team
│   ├── hr-directory/             ← BambooHR, Workday, LDAP / Active Directory
│   ├── crm/                      ← HubSpot, Salesforce
│   ├── ui-design/                ← Figma
│   └── testing/                  ← Allure TestOps
│
│   Each connector source follows this layout:
│     {source}/
│       specs/
│         PRD.md                  ← requirements (actors, FRs, NFRs — code-agnostic)
│         DESIGN.md               ← technical design (schemas, mappings, mechanics)
│         ADR/                    ← architecture decisions
│
├── connectors_orchestration/     ← connector orchestration layer specs
│   └── specs/ (PRD, DESIGN, ADR)
│
├── backend/                      ← backend service specs
│   └── specs/ (PRD, DESIGN, ADR)
│
└── frontend/                     ← frontend / UI specs
    └── specs/ (PRD, DESIGN, ADR)
```

### `inbox/`

Incoming documents pending triage and integration into `docs/`. Not yet canonical.

| Folder | Status | Intended destination |
|--------|--------|----------------------|
| `architecture/` | Draft | Various — identity resolution, permissions, product spec |
| `airbyte-declarative-standalone/` | Prototype | Connector implementation reference |
| `stats/backend/` | Draft ADRs | `docs/backend/specs/ADR/` |
| `stats/frontend/` | Draft | `docs/frontend/specs/` |
| `streams/` | Draft schemas | `docs/connectors/` — per-source stream definitions |

### `cypilot/`

This repo uses [Cypilot](https://github.com/cyberfabric/cyber-pilot) — an AI agent framework for spec authoring, validation, and traceability. The `cypilot/` directory contains the project-specific configuration (artifact registry, rules, kit bindings). The engine itself lives in the upstream repo.

---

## Connector Coverage

| Domain | Sources | Silver Stream |
|--------|---------|---------------|
| Version Control | GitHub, Bitbucket Server, GitLab | `class_commits`, `class_pr_activity` |
| Task Tracking | YouTrack, Jira | `class_task_tracker` |
| Collaboration | M365, Slack, Zoom, Zulip | `class_communication_metrics`, `class_document_metrics` |
| Wiki | Confluence, Outline | `class_wiki_pages`, `class_wiki_activity` |
| Support | Zendesk, JSM | `class_support_activity` |
| AI Dev Tools | Cursor, Windsurf, Copilot, JetBrains | `class_ai_dev_usage` |
| AI Tools | Claude API/Team, OpenAI API, ChatGPT Team | `class_ai_api_usage`, `class_ai_tool_usage` |
| HR / Directory | BambooHR, Workday, LDAP | `class_people`, `class_org_units` |
| CRM | HubSpot, Salesforce | TBD |
| Design Tools | Figma | `class_design_activity` |
| Quality / Testing | Allure TestOps | TBD |

---

## Key Concepts

**Identity Resolution** — Every Bronze table carries a source-native user identifier (`email`, `login`, `uuid`, etc.). The Identity Manager resolves these to a stable `person_id` in Silver Step 2, enabling cross-source analytics (e.g. joining a developer's git activity with their task tracker throughput and AI tool usage).

**Connector spec** — Each connector defines its Bronze table schemas, identity fields, Silver/Gold target streams, and open questions. The `{source}.md` file is the full technical spec; `specs/PRD.md` captures the code-agnostic requirements.

**Extendability** — Adding a new data source means: (1) defining Bronze tables, (2) mapping identity fields, (3) routing to an existing or new Silver stream. The architecture is designed to accommodate new connectors without changes to existing pipelines.

---

## Working with This Repo

- **Browse specs** — Start at [`docs/connectors/README.md`](docs/connectors/README.md) for the connector index, or [`docs/CONNECTORS_REFERENCE.md`](docs/CONNECTORS_REFERENCE.md) for the master Bronze schema reference.
- **Add a connector** — Follow the layout in any existing `docs/connectors/{domain}/{source}/` directory. Use `specs/PRD.md` for requirements and `specs/DESIGN.md` for table schemas and pipeline mappings.
- **Cypilot** — Run `cypilot on` in a supported AI agent to activate assisted spec authoring, validation, and traceability. Cypilot is sourced from [github.com/cyberfabric/cyber-pilot](https://github.com/cyberfabric/cyber-pilot).
- **Inbox** — Documents in `inbox/` are drafts awaiting review. Do not reference them as canonical sources.
