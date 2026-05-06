# DuckDB Migration Plan — Bronze and Silver Layers

**Branch**: `duck`  
**Status**: Planning  
**Date**: 2026-05-06

---

## Why This Change

The original Bronze implementation stored data as Hive-partitioned Parquet
shards — one file per batch per table per year. This design worked for
the initial prototype but has two structural problems that become real at
the volumes this pipeline will process:

### 1. Small Files Problem

Streams like *File C* (5M+ rows/year, monthly batches) produce 12 shards
per year per table. After 5 years: 60+ shard files per table, each
holding ~400K rows. When queried via a DuckDB glob, this means:

- Opening 60+ files
- Reading 60+ Parquet footers for statistics
- Marginal benefit from predicate pushdown on small per-file row groups

This is not a theoretical concern — it is the documented failure mode of
Parquet-based data lakes at scale ("the small files problem").

### 2. Lack of ACID Safety on Promotion

Parquet is immutable. Appending data means writing a new file. A promotion
that writes 3 table files and crashes before the 4th leaves Bronze in a
permanently inconsistent state: those 3 shards exist but the batch is
"pending" in `layer.json`. Re-running immediately hits the collision guard
on the already-written files. There is no safe recovery path without manual
intervention.

### 3. Silver at Scale Requires DuckDB Anyway

The Silver window function (latest-wins per entity) over 25M+ rows of
Bronze cannot be done in R memory. DuckDB is not optional for Silver at
this volume. Since `duckdb` is therefore a required dependency, using it
for Bronze storage too costs nothing in terms of dependencies and buys
ACID safety and performance.

### 4. Silver Storage Consistency

If Bronze and Silver are both DuckDB, the Silver computation is a direct
SQL query from one DuckDB file to another — no format translation, no
`read_parquet` globs, no intermediate Arrow datasets in R memory.

---

## What Changes and What Stays

| Layer | Current | Target | Reason |
|---|---|---|---|
| **Batch** | Parquet + JSON | Parquet + JSON | No change. Isolated events, no accumulation, no ACID requirement. |
| **Bronze** | Hive-partitioned Parquet shards | DuckDB native (`.duckdb` per stream) | ACID appends, no shard proliferation, consistent query interface. |
| **Silver** | Not yet implemented | DuckDB native (`.duckdb` per stream) | Window functions at 25M+ rows, multiple result tables per stream, already a dependency. |

---

## New Physical Layout

### Bronze

```
data/bronze/
  sdo.duckdb
  farmaceutica.duckdb
```

One DuckDB database per stream. Each database contains one table per
method-table combination, e.g.:

```sql
-- inside sdo.duckdb
CREATE TABLE sdo__sdo_hosp_xml__TblScheda ( ... );
CREATE TABLE sdo__sdo_hosp_xml__TblDiagnosi ( ... );
```

Table naming convention: `{stream_id}__{method_id}__{table_name}`.

> **Note**: method is included in the table name because two methods for
> the same stream may produce incompatible schemas, as in the current
> Parquet layout where `stream__method/` is the top-level namespace.

### Silver

```
data/silver/
  sdo.duckdb
  farmaceutica.duckdb
```

Each stream database contains:

```sql
-- inside sdo.duckdb
CREATE TABLE current     ( ... );  -- latest-wins per entity
CREATE TABLE harmonized  ( ... );  -- analytical form of current
```

---

## Required Code Changes

### Phase 1 — Bronze (implement now, on `duck` branch)

**Step 1: Add `duckdb` to `DESCRIPTION` Imports**

```r
# DESCRIPTION
Imports:
  duckdb,
  DBI,
  ...
```

**Step 2: Create `.open_bronze_conn()` helper in `1_bronze_promotion.R`**

Opens (or creates) the DuckDB file for a given stream. Returns a DBI
connection. Caller is responsible for disconnecting.

```r
.open_bronze_conn <- function(bronze_root, stream_id) {
  db_path <- fs::path(bronze_root, paste0(stream_id, ".duckdb"))
  DBI::dbConnect(duckdb::duckdb(), dbdir = db_path)
}
```

**Step 3: Create `.ensure_bronze_table()` helper**

Creates the table for a given stream/method/source-table combination if it
does not already exist, using the schema of the first promoted batch.
Must add all mandatory metadata columns.

**Step 4: Refactor `.apply_bronze_promotion()`**

Replace the current `arrow::write_parquet()` call with:

1. Open Bronze DuckDB connection
2. For each enriched data frame:
   a. Derive the table name from `stream_id__method_id__table_name`
   b. Call `.ensure_bronze_table()` (no-op if already exists)
   c. **Collision check**: `SELECT COUNT(*) FROM table WHERE __batch_id = ?`
      — if > 0, abort with `xpipe_bronze_append_only`
   d. `DBI::dbAppendTable(con, table_name, df)` inside a transaction
3. Commit the transaction
4. Disconnect

**Step 5: Update `.read_bronze_state()` and `.write_bronze_state()`**

`layer.json` is still the right format for the promotion log — it tracks
*which batches* were promoted and when. This does not need to change; it is
a metadata record separate from the data itself.

**Step 6: Update `inspect_bronze()` in `layers_inspect.R`**

Currently lists `.parquet` files. Should instead list tables in the DuckDB
file and report row counts, batch IDs present, and date range.

**Step 7: Update tests**

- `test-bronze_helpers.R`: mock DuckDB connections instead of temp Parquet
  files
- `test-inspect_layer.R`: update expectations for DuckDB-backed Bronze

---

### Phase 2 — Silver (implement when Silver layer begins)

This section outlines the planned Silver compute and storage approach,
to be detailed in a separate implementation plan when work begins.

**Compute**: DuckDB SQL window functions over Bronze DuckDB tables.

```sql
-- Silver-current for SDO
CREATE OR REPLACE TABLE current AS
SELECT * EXCLUDE (rn)
FROM (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY id_nosologico
      ORDER BY __batch_created_at DESC
    ) AS rn
  FROM sdo__sdo_hosp_xml__TblScheda
  WHERE __anchor_year >= year(current_date) - 2
)
WHERE rn = 1;
```

**Storage**: Results written into `data/silver/{stream_id}.duckdb` as
named tables (`current`, `harmonized`).

**Export**: On-demand Parquet export for external consumers:

```r
DBI::dbExecute(con, "
  COPY current TO 'export/sdo_current.parquet' (FORMAT PARQUET)
")
```

---

## Contracts That Need Updating

### ✅ Batch Contract — No changes needed
Batch stays Parquet. The contract is accurate.

### ⚠️ Bronze Contract — Needs updating

The following sections reference Parquet or filesystem layout and must be
revised:

| Section | Current text | Required change |
|---|---|---|
| **Physical Layout** | `bronze/stream__method/year=YYYY/{.parquet}` | Replace with `bronze/{stream_id}.duckdb` layout |
| **Promotion Semantics** | Step 5 appends to a Parquet path | Replace with DuckDB `INSERT INTO` inside a transaction |
| **Append-Only Guarantee** | Collision detected by checking if file exists | Collision detected by checking if `__batch_id` exists in the table |
| **State Tracking** | Brief mention of `layer.json` | Clarify that `layer.json` remains for the promotion event log; data lives in DuckDB |

Core invariants (append-only, immutable batches, domain-time first,
self-describing rows) are **unchanged** — they are semantic rules, not
storage rules.

The mandatory metadata columns table is **unchanged**.

### ⚠️ Silver Contract — Minor update needed

The Silver contract is written at a high semantic level and largely does
not mention storage format — which is good. The one section that needs
updating:

| Section | Issue |
|---|---|
| **Persistence and physical layout** (§Silver-current) | States Silver "may be physically partitioned by year". With DuckDB storage this is no longer a filesystem partition but a `WHERE __anchor_year >= ...` filter. The semantic meaning is the same but the physical description should be updated. |

All other Silver contract content (versioning model, version selection,
secondary table behavior, Silver-harmonized rules) is storage-format
neutral and does not need changing.

### ✅ Privacy Contract — No changes needed

Pseudonymization happens in the Batch phase, in memory, before any
write. The storage format of Bronze and Silver has no bearing on this.

### ✅ Configuration Contract — No changes needed

`local.json`'s `paths.bronze` and `paths.silver` remain directory paths.
DuckDB files live inside those directories. No schema change required.

### ✅ Error Taxonomy — No changes needed

New errors may be added for DuckDB connection failures, but the hierarchy
and existing classes are unaffected.

---

## Test Strategy

The existing test suite uses `withr::with_tempdir()` to create filesystem
sandboxes. This approach extends naturally to DuckDB:

```r
withr::with_tempdir({
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = "test_bronze.duckdb")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # ... test promotion logic ...
})
```

Each test gets a fresh, temporary DuckDB file that is destroyed on exit.
No mocking of DuckDB itself is required.

---

## Rollback Plan

The `duck` branch is isolated. The `main` branch retains the Parquet
implementation. If the migration is abandoned, `duck` is simply not merged.

Existing Batch data (Parquet) on disk is unaffected — the Bronze DuckDB
files are new artifacts, not replacements for anything already written.
