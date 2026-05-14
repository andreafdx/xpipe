# ADR-006: Domain Time (Anchor) Partitioning in Bronze

**Date**: 2026-04-15 (approx.)
**Status**: Accepted
**Decider**: Andrea Fidecicchi

## Context

Bronze data must be physically partitioned on disk to support efficient
time-range queries. The question is whether to partition by the time
the data was ingested (processing time / batch creation time) or by
the clinical event date (domain time / anchor time).

## Decision

Partition Bronze by **domain time** (the date derived from the method's
`partition_column` in the anchor table), not by ingestion time.

A 2026 batch containing SDO records from 2024 is written to
`year=2024/`, not `year=2026/`. Late arrivals append to historical
partitions.

## Alternatives Considered

- **Partition by ingestion time (batch creation time)**: simpler to
  implement — no anchor join required. But it means that a 2024 SDO
  delivered late in 2026 ends up in the 2026 partition, making any
  time-range analysis over clinical event dates require a full scan.
  Not chosen.
- **Dual partitioning (domain + ingestion)**: would double storage and
  complicate the layout. Over-engineered for this scale. Not chosen.

## Consequences

- Historical partitions can be appended to by any future batch; there
  is no guarantee that a partition is "closed" simply because time has
  passed.
- Anchor-time derivation requires a join between secondary tables and
  the anchor table on `identity_keys`. If a row in a secondary table
  cannot be matched to the anchor, promotion aborts.
- Downstream queries on Bronze can filter by `year=` partition efficiently
  when the clinical event date is the query dimension.
- Late-arriving data is handled naturally without special logic.
