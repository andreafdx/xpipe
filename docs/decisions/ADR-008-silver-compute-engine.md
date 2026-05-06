# ADR-008: Silver Compute Engine

**Date**: 2026-05-06
**Status**: Open — decision required before Silver implementation begins

## Context

Silver-current must perform identity resolution and "latest wins"
version selection over the Bronze layer. The Bronze layer is a
collection of Parquet shards, potentially spanning multiple years and
batches. The computation involves:

1. Reading all relevant Bronze shards for a stream
2. Grouping by `identity_keys`
3. Selecting the row (or set of rows) with the maximum version marker
   per entity

The question is which compute engine to use for this operation and
whether Silver is materialized or computed on-demand.

## Options Under Consideration

### Option A: DuckDB over Parquet files

Use DuckDB (via `DBI` + `duckdb` package) to execute SQL window
functions over the Bronze Parquet shards using a glob path.

```sql
SELECT * FROM read_parquet('bronze/sdo__method/year=*/*.parquet')
WHERE __batch_id = last_value(__batch_id) OVER (
  PARTITION BY id_nosologico
  ORDER BY __batch_created_at
)
```

**Pros**: scales beyond R memory; native Parquet support; no data
copying; exploits partition pruning.
**Cons**: adds `duckdb` as a dependency; SQL embedded in R is less
readable; error messages from DuckDB can be opaque.

### Option B: Arrow Dataset + dplyr

Use `arrow::open_dataset()` to create a lazy dataset over the Bronze
shards, then apply `dplyr` verbs with `slice_max()` for version selection.

**Pros**: stays within the existing dependency set (arrow + dplyr already
in Imports); familiar R idiom; type-safe.
**Cons**: large multi-year datasets may not fit in memory; Arrow's
`slice_max` over groups with collect() may be slow for very large
Bronze layers.

### Option C: Incremental R (partition-by-partition)

Process Bronze one year-partition at a time in R memory, build Silver
incrementally.

**Pros**: predictable memory usage; no new dependencies.
**Cons**: cross-partition entities (multi-year hospitalisations) require
special handling; complex to implement correctly; re-running the full
history is slow.

## Open Questions

- What is the expected size of the Bronze layer at steady state (rows per year)?
- Are there entities that legitimately span multiple year-partitions?
- Is Silver expected to be rebuilt from scratch on each run, or updated incrementally?
- Is Python interoperability at the Silver level a requirement?

## Recommendation (tentative)

DuckDB (Option A) is the most robust choice for a growing historical
ledger. The dependency is lightweight and the query model maps cleanly
to the version-selection problem. Worth evaluating Option B first given
zero new dependencies.
