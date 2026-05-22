---
date: 2026-05-22
---

# Bronze Layer Contract

## Purpose

The Bronze layer is the durable, DuckDB-native historical layer of the
pipeline.

Its role is to preserve all promoted Batch data with full lineage, while
remaining append-oriented, auditable, and rebuildable from Batch.

Bronze does not determine current state, deduplicate entities, resolve
identity conflicts, or apply semantic harmonization. Those
responsibilities belong to Silver-current and later layers.

------------------------------------------------------------------------

## Core invariants

### Append-oriented historical storage

Bronze stores promoted Batch data as historical records.

Rows already promoted into Bronze must not be silently modified or
deleted as part of normal promotion.

A batch that has already been promoted must not be promoted again.
Re-processing an already promoted batch is either rejected or treated as
a no-op, based on the authoritative promotion log.

### Atomic promotion

Bronze promotion is atomic.

Either:

-   all Batch tables are promoted successfully, and
-   one corresponding `__promotion_log` entry is written

or nothing is committed.

Partial promotions are invalid.

### Promotion log authority

The authoritative state of Bronze promotion is stored inside the DuckDB
database in `__promotion_log`.

A batch is considered promoted if and only if its `batch_id` appears in
`__promotion_log`.

Filesystem state, physical table presence, or operator assumptions must
not override `__promotion_log`.

### Batch preservation

Bronze preserves what Batch materializes.

Bronze must not repair semantic typing, privacy handling, or extractor
output.

If a code, identifier, or privacy-sensitive value is wrong in Batch, the
fix belongs upstream in extraction, privacy application, or Batch type
enforcement, not in Bronze.

------------------------------------------------------------------------

## Physical layout

Bronze uses one DuckDB database per stream:

``` text
data/bronze/<stream_id>.duckdb
```

Inside each stream database, promoted Batch tables are stored as DuckDB
tables using the naming pattern:

``` text
<stream_id>__<method_id>__<source_table_name>
```

Example:

``` text
data/bronze/sdo.duckdb
  sdo__xml_campania_2026__ricovero
  sdo__xml_campania_2026__diagnosi
  sdo__xml_campania_2026__procedure
  __promotion_log
```

This layout preserves method-level schema separation and prevents
accidental mixing of incompatible methods for the same stream.

### Bronze table naming

Bronze table names must include:

1.  `stream_id`
2.  `method_id`
3.  source table name

Pattern: `{stream_id}__{method_id}__{source_table_name}`

This is required because multiple methods may exist for the same stream
and may produce incompatible schemas.

Bronze may store multiple methods for the same stream. Silver-current
decides which method is canonical through silver.json; Bronze does not
choose.

### Metadata columns

Every promoted Bronze data table must include lineage columns that
identify the Batch event and promotion context.

Required lineage columns include:

``` text
__batch_id
__stream_id
__method_id
__batch_created_at
__bronze_promoted_at
```

These columns are used for lineage, auditability, and Silver-current
version selection.

Silver-current uses `__batch_created_at` DESC, `__batch_id` DESC to
determine the latest version of an entity. Domain anchor time is not
used for Silver-current currentness.

------------------------------------------------------------------------

## Promotion Log

Each Bronze DuckDB database must contain an authoritative internal
table: `__promotion_log`. The promotion log records successful Batch
promotions. Required fields include:

``` text
batch_id
stream_id
method_id
promoted_at
```

The `tables` field records the set of Batch tables promoted in that
promotion event. The promotion log is the source of truth for whether a
Batch has been promoted.

## Promotion Semantics

Bronze promotion follows this conceptual sequence:

-   Read `_batch_metadata.json`
-   Validate required metadata fields
-   List physical Parquet files in the Batch directory
-   Ensure the method `anchor_table` is physically present
-   Open the stream DuckDB database
-   Start a transaction
-   Reconcile additive schema changes
-   Append Batch rows into Bronze tables
-   Insert one row into `__promotion_log`
-   Commit the transaction

If any step fails, the transaction must roll back.

No promotion log entry may exist without the corresponding table writes,
and no table writes may be considered promoted without a corresponding
log entry.

## Schema Evolution

Bronze handles additive schema evolution only.

Allowed:

-   new incoming columns may be added to an existing Bronze table
-   missing incoming columns may be inserted as `NULL`
-   column order changes are harmless

Not allowed silently:

-   incompatible type changes
-   semantic type degradation
-   implicit coercion that may alter meaning

Incompatible schema changes must abort rather than silently corrupt
Bronze.

------------------------------------------------------------------------

## Relationship to Batch

Batch is the semantic and artifact authority for promoted data.

Bronze promotion must use the physical Parquet files present in the
Batch directory as the source of materialized tables.

`_batch_metadata.json` is descriptive and provides lineage, timestamps,
method, stream, and materialization context. It must not be used to
promote a table if the corresponding Parquet file is absent.

## Relationship to Silver

Bronze does not define currentness.

Bronze stores all promoted history for all methods.

Silver-current builds a current table family from one canonical method
per stream, declared in `silver.json`.

Bronze must therefore preserve method lineage and Batch lineage
accurately, but must not select, merge, or harmonize methods.

------------------------------------------------------------------------

## Inspection requirements

Bronze inspection must be DuckDB-native. `inspect_bronze()` must report:

-   Bronze DuckDB path
-   physical tables
-   data tables excluding internal tables
-   row counts
-   `__promotion_log` history ordered by `promoted_at` DESC
-   tables listed in the log
-   log-referenced tables missing physically
-   physical tables not referenced by the log
-   tabular sanity checks with `OK`, `WARN`, and `FAIL`

Missing physical tables referenced by the promotion log are `FAIL`.

Physical tables not referenced by the promotion log are `WARN`, because
they may reflect legacy data, debugging artifacts, or manual recovery.

------------------------------------------------------------------------

## What Bronze explicitly does not do

Bronze does not:

-   determine the current version of an entity
-   deduplicate records
-   enforce entity uniqueness
-   choose among methods for the same stream
-   apply privacy rules
-   repair semantic typing
-   harmonize column names or code systems
-   derive analytical indicators
-   export consumer-facing datasets

These responsibilities belong upstream to Batch or downstream to Silver
and future harmonized layers.

## Guarantees for downstream layers

A valid Bronze layer guarantees:

-   promoted data is stored in DuckDB tables by stream, method, and
    source table
-   every successful promotion is recorded in `__promotion_log`
-   promotion state is authoritative inside DuckDB
-   promoted rows retain Batch lineage
-   additive schema evolution is handled consistently
-   incompatible schema changes abort
-   Silver-current can rebuild from Bronze using the canonical method
    declared in `silver.json`

Bronze does not guarantee that a record is current, deduplicated,
harmonized, or analytically standardized.
