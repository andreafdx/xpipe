# ADR-002: Parquet as Canonical Storage Format

**Date**: 2026-04-01 (approx.)
**Status**: Accepted
**Decider**: Andrea Fidecicchi

## Context

Each pipeline layer needs a persistent, typed storage format for tabular
data. The choice of format affects read performance, schema enforcement,
interoperability with other tools (Python, DuckDB), and file size.

## Decision

Use Apache Parquet (via the R `arrow` package) as the canonical on-disk
format for all layers (Batch, Bronze, and Silver).

## Alternatives Considered

- **CSV**: universal but untyped; no schema, slow for large files, no
  column pruning. Unsuitable for an analytical pipeline.
- **RDS**: fast in R, but R-only. Useless from Python or DuckDB.
  Not a viable interoperability format.
- **SQLite/DuckDB database file**: powerful query engine but introduces
  a database process dependency. Harder to inspect, share, or back up
  individual records.
- **Arrow IPC (Feather)**: good for in-memory transfer, less optimal for
  long-term storage and cross-platform use than Parquet.

## Consequences

- Column types are preserved without parsing overhead.
- Files are readable from Python (`pandas`, `polars`), DuckDB, Spark,
  and any other Parquet-capable tool.
- The Silver layer can be implemented with DuckDB SQL over Parquet files
  without loading everything into R memory.
- File sizes are compact due to columnar compression.
- Parquet files are not human-readable; inspection requires tooling
  (`arrow::read_parquet`, DuckDB, `parquet-tools`).
