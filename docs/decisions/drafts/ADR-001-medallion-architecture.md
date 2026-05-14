# ADR-001: Medallion Architecture (Batch → Bronze → Silver)

**Date**: 2026-04-01 (approx.)
**Status**: Accepted
**Decider**: Andrea Fidecicchi

## Context

The pipeline ingests healthcare administrative data (SDO and others) from
heterogeneous proprietary sources (Access MDB, XML files). The same source
data may be corrected and re-submitted over time, representing multiple
versions of the same logical record.

A single flat ingestion layer would conflate raw extraction, historical
preservation, and identity resolution into one operation, making the
system fragile and difficult to audit.

## Decision

Adopt a Medallion architecture with three explicit layers:

- **Batch** — atomic, immutable ingestion events (raw → canonical)
- **Bronze** — append-only historical ledger, partitioned by domain time
- **Silver** — current-state view with identity resolution (planned)

Each layer has a written contract, distinct responsibilities, and clear
guarantees to downstream consumers. No layer may read from a layer above
it.

## Alternatives Considered

- **Single flat layer**: simpler, but conflates concerns and makes
  historical replay impossible.
- **Two layers (raw + current)**: loses the immutable ledger that makes
  audit and reprocessing safe.
- **Full data warehouse (star schema)**: over-engineered for the scale
  and team size; requires significant infrastructure.

## Consequences

- Adding a new data flow requires configuration only (no code change).
- Errors in ingestion do not corrupt historical data; bad batches remain
  pending and can be re-processed.
- Silver layer complexity is pushed downstream, keeping Batch and Bronze
  simple and auditable.
- Three separate storage roots must be managed and backed up.
