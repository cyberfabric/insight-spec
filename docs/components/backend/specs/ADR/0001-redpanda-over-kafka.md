---
status: accepted
date: 2026-03-31
---

# ADR-0001: Use Redpanda over Apache Kafka for Event Streaming

**ID**: `cpt-insightspec-adr-be-redpanda-over-kafka`

<!-- toc -->

- [Context and Problem Statement](#context-and-problem-statement)
- [Decision Drivers](#decision-drivers)
- [Considered Options](#considered-options)
- [Decision Outcome](#decision-outcome)
  - [Consequences](#consequences)
  - [Confirmation](#confirmation)
- [Pros and Cons of the Options](#pros-and-cons-of-the-options)
  - [Apache Kafka](#apache-kafka)
  - [Redpanda](#redpanda)
  - [NATS JetStream](#nats-jetstream)
  - [RabbitMQ](#rabbitmq)
- [More Information](#more-information)
- [Traceability](#traceability)

<!-- /toc -->

## Context and Problem Statement

The backend requires a reliable event streaming platform for audit events, email delivery requests, cache invalidation, and connector status updates across seven microservices. Which message broker should be used given that the product is deployed as a standalone installation on customer Kubernetes clusters with varying resource budgets?

## Decision Drivers

* Kafka-compatible API -- all services use the `rdkafka` crate and must be able to switch to Apache Kafka without code changes
* Resource footprint -- standalone product bundled via Helm; customers may have limited cluster capacity
* Operational simplicity -- customers manage their own clusters; fewer moving parts reduce support burden
* Reliability -- audit events and email requests must not be lost; at-least-once delivery required
* Migration path -- if future requirements outgrow Redpanda, switching to Kafka must be a deployment change, not a code rewrite

## Considered Options

* Apache Kafka
* Redpanda
* NATS JetStream
* RabbitMQ

## Decision Outcome

Chosen option: "Redpanda", because it provides full Kafka API compatibility with significantly lower resource requirements and operational complexity, while preserving a zero-code-change migration path to Apache Kafka.

### Consequences

* Good, because single binary deployment -- no JVM, no ZooKeeper/KRaft controller quorum
* Good, because all services use `rdkafka` crate which works identically with Kafka and Redpanda
* Good, because Redpanda Helm chart is simpler to configure and maintain than Kafka operator
* Good, because lower memory and CPU requirements reduce minimum cluster sizing for customer deployments
* Bad, because Redpanda community is smaller than Kafka; fewer third-party integrations and tooling
* Bad, because Redpanda has less battle-testing at extreme scale (billions of messages/day), though this is not expected for Insight workloads

### Confirmation

* All services connect to Redpanda using `rdkafka` with standard Kafka protocol -- confirmed by integration tests
* No Redpanda-specific APIs used anywhere in codebase -- confirmed by code search for Redpanda imports
* Migration test: swap Redpanda Helm subchart for Kafka (Strimzi/Bitnami) in staging and run full integration suite

## Pros and Cons of the Options

### Apache Kafka

Industry-standard distributed event streaming platform. JVM-based, requires ZooKeeper (legacy) or KRaft controller quorum.

* Good, because largest ecosystem, most tooling, widest community support
* Good, because proven at extreme scale (LinkedIn, Uber, Netflix)
* Good, because Kafka Connect and Kafka Streams ecosystem
* Bad, because JVM-based -- higher memory footprint (minimum 2-4 GB heap per broker)
* Bad, because requires ZooKeeper or KRaft controller quorum -- additional operational complexity
* Bad, because Helm deployment is complex (Strimzi operator or Bitnami chart with many moving parts)
* Bad, because heavier minimum resource requirements increase customer cluster sizing

### Redpanda

Kafka API-compatible event streaming platform. Single C++ binary, no JVM, no external dependencies.

* Good, because full Kafka API compatibility -- `rdkafka` works without configuration changes
* Good, because single binary -- no JVM, no ZooKeeper, no controller quorum
* Good, because lower resource requirements (starts at 256 MB, typical production 1-2 GB)
* Good, because simpler Helm chart with fewer configuration parameters
* Good, because built-in Schema Registry and HTTP Proxy (if needed later)
* Neutral, because Redpanda console provides basic monitoring UI
* Bad, because smaller community and ecosystem than Kafka
* Bad, because less proven at extreme scale (though sufficient for Insight volumes)

### NATS JetStream

Lightweight messaging system with built-in persistence. Pure Go, single binary.

* Good, because smallest footprint (~20 MB binary, minimal memory)
* Good, because pure Rust async-nats client is well-maintained
* Good, because built-in request/reply patterns useful for inter-service calls
* Bad, because NOT Kafka API-compatible -- switching to Kafka later requires code changes
* Bad, because different consumer group model -- would need application-level adaptation
* Bad, because smaller ecosystem for stream processing and monitoring

### RabbitMQ

Mature message broker with AMQP protocol. Erlang-based, supports multiple messaging patterns (queues, topics, routing).

* Good, because mature and battle-tested in enterprise environments
* Good, because rich routing patterns (direct, topic, fanout, headers exchanges)
* Good, because built-in management UI and extensive plugin ecosystem
* Good, because `lapin` Rust crate provides async AMQP client
* Bad, because NOT Kafka API-compatible -- switching to Kafka later requires code changes and architecture rework
* Bad, because AMQP is a different paradigm (message queues) vs event streaming (log-based) -- not suitable for event replay or consumer offset management
* Bad, because Erlang runtime adds operational complexity (BEAM VM tuning, clustering)
* Bad, because no native log compaction or stream replay -- audit events and cache invalidation patterns require log semantics

## More Information

Redpanda topic catalog is defined in the [Backend DESIGN](../DESIGN.md) section 3.8. Topics handle all async communication: audit events, email requests, cache invalidation, connector status, identity resolution, transform status, and alert events.

The `rdkafka` crate configuration is identical for Redpanda and Kafka. Migration involves only Helm subchart swap and broker URL change in Sealed Secrets.

## Traceability

- **PRD**: [PRD.md](../PRD.md)
- **DESIGN**: [DESIGN.md](../DESIGN.md)

This decision directly addresses the following requirements or design elements:

* `cpt-insightspec-fr-be-audit-trail` -- Audit events flow through Redpanda topics to Audit Service
* `cpt-insightspec-fr-be-email-delivery` -- Email requests published to Redpanda, consumed by Email Service
* `cpt-insightspec-fr-be-business-alerts` -- Alert-fired events and email requests via Redpanda
* `cpt-insightspec-nfr-be-graceful-shutdown` -- Redpanda consumer offset commits during shutdown
* `cpt-insightspec-nfr-be-retry-resilience` -- rdkafka producer retries on broker unavailability
* `cpt-insightspec-constraint-be-redpanda` -- This ADR is the basis for the Redpanda constraint
