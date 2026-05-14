# ADR-004: Append-Only Bronze Layer using DuckDB Native Format

**Date**: 2026-05-06
**Status**: Accepted
**Decider**: Andrea Fidecicchi

## Context

Bronze is the historical ledger. Once data is promoted, it should be
possible to replay the full history of ingested batches for any entity.
The design must prevent accidental overwrite of historical facts and make
the promotion operation safe and auditable.

The original design used Hive-partitioned Parquet shards, but this led to
a "small files problem" (one file per batch per month/year) and lacked
ACID atomicity during promotion (partial failures could leave orphan
shards).

## Decision

Use DuckDB native database files (`.duckdb`) as the storage format for
the Bronze layer, with one database file per stream (e.g., `bronze_sdo.duckdb`,
`bronze_farmaceutica.duckdb`).

- Promotion uses `INSERT INTO` operations which are true ACID transactions.
- The layer remains append-only by policy; batches are identified by a
  mandatory `__batch_id` column.
- Data is still logically partitioned by domain time within the table.

## Alternatives Considered

- **Hive-partitioned Parquet shards**: Portable and transparent, but
  suffers from shard proliferation and lacks transaction safety. If a
  promotion fails halfway, the filesystem is left in an inconsistent
  state.
- **Upsert into a single Parquet file per partition**: Impossible to do
  safely without a full rewrite of the file on every batch, which is
  slow and risky.
- **SQLite**: Supports ACID appends but lacks the columnar analytical
  performance required for Silver-layer window functions and Parquet
  interoperability.

## Consequences

- **ACID Safety**: Promotions are now atomic. A batch either lands
  completely or not at all. No more partial shards on disk.
- **Performance**: Querying the full history is significantly faster
  within DuckDB than scanning hundreds of small Parquet shards.
- **Simplified Layout**: One file per stream instead of thousands of
  nested directories and files.
- **Tooling dependency**: Reading Bronze now requires the `duckdb`
  package (already a dependency for Silver compute).
- **Interoperability**: While the native format is specific to DuckDB,
  it can export back to Parquet in a single command if external
  interoperability is required.

