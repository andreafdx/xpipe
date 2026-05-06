# ADR-004: Append-Only Bronze Layer with Immutable Shards

**Date**: 2026-04-15 (approx.)
**Status**: Accepted
**Decider**: Andrea Fidecicchi

## Context

Bronze is the historical ledger. Once data is promoted, it should be
possible to replay the full history of ingested batches for any entity.
The design must prevent accidental overwrite of historical facts and make
the promotion operation safe and auditable.

## Decision

Bronze writes one Parquet file per batch per table per partition
(`table__batch_id.parquet`). Promotion refuses to overwrite an existing
shard (`xpipe_bronze_append_only` error). The state log (`layer.json`)
records only successful promotions and is never used to record partial
or failed states.

## Alternatives Considered

- **Upsert into a single Parquet file per partition**: technically
  possible with DuckDB or Arrow, but loses the ability to identify which
  batch each row came from without explicit metadata columns. Also makes
  the append-only invariant difficult to enforce without reading existing
  data. Not chosen.
- **Partition per batch (not per time)**: would make time-range queries
  across batches very expensive. Not chosen.
- **A database (DuckDB/SQLite) as the Bronze store**: good query
  performance but makes the layer opaque and harder to inspect, back up,
  or replicate. The Parquet-on-filesystem approach is portable and
  transparent. Not chosen.

## Consequences

- The collision guard makes double-promotion impossible without manual
  intervention.
- If a promotion fails mid-way, only successfully written shards exist.
  The batch remains "pending" in the state log and can be re-promoted
  safely (any already-written shards will trigger the collision guard
  and abort — a known limitation).
- Bronze is not queryable efficiently as a single table; it is a
  collection of shards. DuckDB or Arrow Dataset is required for
  multi-shard queries.
- Historical partitions can grow unboundedly; there is no current
  mechanism to prune or archive old shards.
