---
editor_options: 
  markdown: 
    wrap: 72
---

# DuckDB Migration Plan — Bronze and Silver Layers

**Branch**: `duck`\
**Status**: Accepted — ready for implementation\
**Date**: 2026-05-06

------------------------------------------------------------------------

## Why This Change

The original Bronze implementation stored data as Hive-partitioned
Parquet shards — one file per batch per table per year. This design
worked for the initial prototype but has structural problems that become
real at the volumes this pipeline will process.

### 1. Small Files Problem

Streams like *File C* (5M+ rows/year, monthly batches) produce 12 shards
per year per table. After 5 years: 60+ shard files per table, each
holding \~400K rows. When queried via a DuckDB glob:

-   Opening 60+ files
-   Reading 60+ Parquet footers for statistics
-   Marginal benefit from predicate pushdown on small per-file row
    groups

This is the documented failure mode of Parquet-based data lakes at
scale.

### 2. Lack of ACID Safety on Promotion

Parquet is immutable. Appending data means writing a new file. A
promotion that writes 3 table files and crashes before the 4th leaves
Bronze in a permanently inconsistent state: those 3 shards exist but the
batch is `"pending"` in `layer.json`. Re-running immediately hits the
collision guard on the already-written files. There is no safe recovery
path without manual intervention.

### 3. Promotion Log Split-Brain

Under the current design, promotion has two separate write targets:
Parquet files on disk and `layer.json`. These are not atomic. A crash
between the last Parquet write and the `layer.json` update leaves data
present but state inconsistent. Moving to DuckDB without also moving the
promotion log into the same transaction would only shift this failure
window, not eliminate it.

### 4. Silver at Scale Requires DuckDB Anyway

The Silver window function (latest-wins per entity) over 25M+ rows of
Bronze cannot be done in R memory. `duckdb` is therefore a required
dependency regardless. Using it for Bronze storage costs nothing
additional and buys ACID safety and performance.

### 5. Silver Storage Consistency

If Bronze and Silver are both DuckDB, the Silver computation is a direct
SQL query from one DuckDB file to another — no format translation, no
`read_parquet` globs, no intermediate Arrow datasets in R memory.

------------------------------------------------------------------------

## What Changes and What Stays

| Layer | Current | Target | Reason |
|----|----|----|----|
| **Batch** | Parquet + JSON | Parquet + JSON | No change. Isolated events, no accumulation, no ACID requirement. |
| **Bronze** | Hive-partitioned Parquet shards | DuckDB native (`.duckdb` per stream) | ACID appends, no shard proliferation, atomic promotion log. |
| **Silver** | Not yet implemented | DuckDB native (`.duckdb` per stream) | Window functions at 25M+ rows, multi-table family per stream. |

------------------------------------------------------------------------

## New Physical Layout

### Bronze

```         
data/bronze/
  sdo.duckdb
  ps.duckdb
  filecint.duckdb
```

One DuckDB database per stream. Each database contains:

-   One data table per method-source-table combination
-   One authoritative promotion log table: `__promotion_log`

**Table naming convention**:
`{stream_id}__{method_id}__{source_table_name}`

The method segment is included because two methods for the same stream
may produce incompatible schemas (e.g. MDB extraction vs. XML extraction
for the same SDO stream), matching the `stream__method/` namespace of
the old Parquet layout.

Example for SDO with method `sdo_hosp_xml`:

``` sql
-- data tables
CREATE TABLE sdo__sdo_hosp_xml__TblScheda   (...);
CREATE TABLE sdo__sdo_hosp_xml__TblDiagnosi (...);
CREATE TABLE sdo__sdo_hosp_xml__TblProcedure (...);

-- promotion log
CREATE TABLE __promotion_log (...);
```

### Silver

```         
data/silver/
  sdo.duckdb
  ps.duckdb
  filecint.duckdb
```

Silver is a **multi-table family** per stream. Version selection applies
to the anchor table; secondary tables are filtered to retain only rows
belonging to the selected anchor version.

**Table naming convention**: `{phase}__{source_table_name}`

``` sql
-- inside sdo.duckdb
CREATE TABLE current__TblScheda   (...);  -- latest-wins anchor
CREATE TABLE current__TblDiagnosi (...);  -- filtered to current anchor version
CREATE TABLE current__TblProcedure (...);

CREATE TABLE harmonized__TblScheda   (...);
CREATE TABLE harmonized__TblDiagnosi (...);
CREATE TABLE harmonized__TblProcedure (...);
```

A stream that has only one table still follows this naming for
consistency: `current__<table>`, not a bare `current`.

------------------------------------------------------------------------

## Concurrency and Writer Model

DuckDB in file-backed mode supports multiple concurrent readers
(read-only connections) but requires exclusive access for writers.

> **Bronze promotion assumes a single writer per stream database.**\
> Concurrent writes to the same `.duckdb` file are not supported and
> must not be attempted.

Analysts may query Bronze or Silver in read-only mode while no promotion
is running:

``` r
con <- DBI::dbConnect(duckdb::duckdb(), dbdir = "data/bronze/sdo.duckdb",
                      read_only = TRUE)
```

Scheduling two promotion jobs for the same stream concurrently is
undefined behavior and must be prevented at the orchestration level.

------------------------------------------------------------------------

## Required Code Changes

### Phase 1 — Bronze (implement now, on `duck` branch)

#### Step 1: Add `duckdb` and `DBI` to `DESCRIPTION` Imports

Both are available in the R ecosystem. `DBI` is the database interface
abstraction; `duckdb` provides the driver.

------------------------------------------------------------------------

#### Step 2: Create `.open_bronze_conn()` helper

Opens (or creates) the stream DuckDB file. Returns a DBI connection.
Caller is responsible for disconnecting.

``` r
.open_bronze_conn <- function(bronze_root, stream_id, read_only = FALSE) {
  db_path <- fs::path(bronze_root, paste0(stream_id, ".duckdb"))
  DBI::dbConnect(duckdb::duckdb(), dbdir = as.character(db_path),
                 read_only = read_only)
}
```

------------------------------------------------------------------------

#### Step 3: Identifier quoting — never paste raw names into SQL

Table names like `sdo__sdo_hosp_xml__TblScheda` are mostly safe, but
source table names from Access MDB or XML may contain spaces, uppercase,
reserved words, or other characters that break unquoted SQL. Use DBI's
quoting helper everywhere:

``` r
.quote_ident <- function(con, x) DBI::dbQuoteIdentifier(con, x)
```

For string values (batch IDs, paths), always use parameterised queries
(`params = list(...)`) or `DBI::dbQuoteLiteral()`. Never `glue()` raw
batch IDs or file paths directly into SQL.

------------------------------------------------------------------------

#### Step 4: Create `__promotion_log` table (authoritative promotion state)

This table is the single source of truth for promoted batches. It
replaces `layer.json` in that role.

``` sql
CREATE TABLE IF NOT EXISTS __promotion_log (
  batch_id         TEXT PRIMARY KEY,
  stream_id        TEXT NOT NULL,
  method_id        TEXT NOT NULL,
  promoted_at      TIMESTAMP NOT NULL,
  batch_created_at TIMESTAMP,
  anchor_source    TEXT,
  tables           TEXT,       -- JSON array of promoted table names
  tool             TEXT,
  tool_version     TEXT
);
```

> **No `status` column.** `__promotion_log` records only successful
> promotions. A batch that is not in this table is not promoted, full
> stop. Logging failed attempts adds complexity with no benefit;
> failures are visible in the R error condition and the operator's
> console. A success-only ledger is simpler and unambiguous.

`layer.json` may be retained as a non-authoritative, human-readable
summary written after a successful promotion (a convenience cache for
quick inspection without opening DuckDB). It must not be used as the
source of truth for batch state.

------------------------------------------------------------------------

#### Step 5: Create `.ensure_bronze_table()` helper

Creates the data table on first use. Schema is derived from the Parquet
source file via DuckDB's native Parquet introspection — see Step 6 on
type policy.

------------------------------------------------------------------------

#### Step 6: Type inference policy — Parquet types, not VARCHAR by default

Domain columns are created using the types DuckDB infers directly from
the Batch Parquet file. Since Batch is already Parquet, DuckDB can read
the source schema without loading data into R:

``` sql
DESCRIBE SELECT * FROM read_parquet('path/to/batch/table.parquet')
```

This gives reliable type information. `VARCHAR` is used only as a safe
fallback when inference is genuinely unsafe (all-NA columns,
inconsistent type across row groups).

> **Rule**: preserve source types where stable; fall back to `VARCHAR`
> only for ambiguous columns. Do not use `VARCHAR` as a default.

Turning everything into `VARCHAR` avoids type conflicts at ingestion but
forces casts everywhere in Silver, degrades query performance, and
introduces subtle date/number bugs downstream.

------------------------------------------------------------------------

#### Step 7: Create `.reconcile_bronze_schema()` — Schema Evolution Policy

This runs **inside the same transaction** as the INSERT. DuckDB tables
are strictly typed; if the source schema changes between batches, the
Bronze table must be reconciled before insertion.

| Scenario | Action |
|----|----|
| **New column in source, absent from Bronze table** | `ALTER TABLE ADD COLUMN <name> <inferred_type> DEFAULT NULL` + `cli_warn()`. Historical rows get NULL. |
| **Column absent from source, present in Bronze table** | Insert NULL via name-based INSERT. Log warning. |
| **Type widening** (`INT → BIGINT`, `DATE → TIMESTAMP`) | Allow. `ALTER TABLE ALTER COLUMN TYPE`. |
| **Incompatible type change** (`DATE → VARCHAR`, `INT → BOOLEAN`) | Hard abort: `xpipe_bronze_schema_evolution`. Manual migration required. |
| **Identity key column missing or null in source** | Hard abort regardless of schema policy. This is a source data failure. |
| **Column reordering in source** | Harmless. INSERT is always name-based, never positional. |
| **All-NA column in source** | DuckDB may infer as INTEGER. Coerce to VARCHAR; log warning. |

``` r
.reconcile_bronze_schema <- function(con, table_name, incoming_df, identity_keys) {
  existing_cols <- DBI::dbListFields(con, table_name)
  incoming_cols <- names(incoming_df)

  # Identity keys must be present and non-null
  missing_keys <- setdiff(identity_keys, incoming_cols)
  if (length(missing_keys) > 0) {
    cli::cli_abort(
      "Identity key column(s) missing from batch: {.val {missing_keys}}",
      class = c("xpipe_bronze_schema_evolution", "xpipe_bronze_error", "xpipe_error")
    )
  }

  # New columns: add to table
  new_cols <- setdiff(incoming_cols, existing_cols)
  for (col in new_cols) {
    dtype <- .infer_duckdb_type(incoming_df[[col]])
    cli::cli_warn("Schema evolution: adding column '{col}' ({dtype}) to {table_name}")
    DBI::dbExecute(con, glue::glue(
      "ALTER TABLE {.quote_ident(con, table_name)} ",
      "ADD COLUMN IF NOT EXISTS {.quote_ident(con, col)} {dtype} DEFAULT NULL"
    ))
  }

  # Dropped columns: log only; INSERT handles with NULLs
  dropped <- setdiff(setdiff(existing_cols, .bronze_metadata_cols()), incoming_cols)
  if (length(dropped) > 0) {
    cli::cli_warn(
      "Column(s) absent from this batch, NULL will be inserted: {.val {dropped}}"
    )
  }

  invisible(NULL)
}
```

------------------------------------------------------------------------

#### Step 8: Refactor `.apply_bronze_promotion()` — Atomic Transaction

**Authoritative promotion sequence:**

```         
1. BEGIN TRANSACTION
2. Check __promotion_log for batch_id           ← primary collision check
   - if present: abort (already promoted)
3. For each data table:
   a. .ensure_bronze_table()
   b. .reconcile_bronze_schema()
   c. INSERT INTO <table> SELECT ... FROM read_parquet('<batch_path>')
   d. Check __batch_id presence in data table   ← corruption guard only
      (data present but log absent = prior failed migration state)
4. INSERT INTO __promotion_log
5. COMMIT
```

Step 2 is the authoritative collision check. If `__promotion_log` says
the batch exists, the batch is promoted — regardless of what the data
tables contain. A data table that contains `__batch_id` rows but has no
corresponding log entry indicates corruption (e.g. a partial promotion
from before the migration to DuckDB), not a normal duplicate — handle
separately with a warning, not the standard collision error.

``` r
# Pseudo-code — actual implementation will handle error classes and CLI output

con <- .open_bronze_conn(bronze_root, stream_id)
on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

DBI::dbBegin(con)

tryCatch({

  # 1. Authoritative collision check
  already_promoted <- DBI::dbGetQuery(
    con,
    "SELECT COUNT(*) FROM __promotion_log WHERE batch_id = ?",
    params = list(batch_id)
  )[[1]] > 0

  if (already_promoted) {
    cli::cli_abort(
      "Batch {.val {batch_id}} is already recorded in the promotion log.",
      class = c("xpipe_bronze_append_only", "xpipe_bronze_error", "xpipe_error")
    )
  }

  # 2. Insert each data table directly from Batch Parquet
  for (tbl in batch_tables) {
    table_name  <- glue("{stream_id}__{method_id}__{tbl$source_name}")
    parquet_path <- tbl$parquet_path

    .ensure_bronze_table(con, table_name, parquet_path)
    .reconcile_bronze_schema(con, table_name, tbl$df, identity_keys)

    # INSERT from Parquet directly — no R data frame materialization
    DBI::dbExecute(con, glue::glue("
      INSERT INTO {.quote_ident(con, table_name)}
      SELECT
        *,
        ? AS __batch_id,
        ? AS __stream_id,
        ? AS __method_id,
        ? AS __batch_created_at,
        ? AS __bronze_promoted_at,
        ? AS __anchor_time,
        ? AS __anchor_year,
        ? AS __anchor_source
      FROM read_parquet(?)
    "), params = list(
      batch_id, stream_id, method_id,
      batch_created_at, promoted_at,
      tbl$anchor_time, tbl$anchor_year, tbl$anchor_source,
      parquet_path
    ))
  }

  # 3. Insert promotion event into authoritative log (same transaction)
  DBI::dbExecute(con,
    "INSERT INTO __promotion_log VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
    params = list(
      batch_id, stream_id, method_id,
      promoted_at, batch_created_at,
      anchor_source, jsonlite::toJSON(names(batch_tables)),
      config$runtime$tool$name, config$runtime$tool$version
    )
  )

  DBI::dbCommit(con)

}, error = function(e) {
  DBI::dbRollback(con)
  cli::cli_abort(
    "Bronze promotion failed and was rolled back.",
    parent = e,
    class = c("xpipe_bronze_error", "xpipe_error")
  )
})
```

> **`INSERT INTO ... SELECT FROM read_parquet()`** reads the Batch
> Parquet file directly on disk. No R data frame is materialized for
> large production batches. Memory usage stays bounded regardless of
> batch size. `dbAppendTable()` with a pre-loaded data frame remains
> valid for unit tests with small fixtures.

------------------------------------------------------------------------

#### Step 9: Update `inspect_bronze()` in `layers_inspect.R`

Currently lists `.parquet` files. Must instead:

-   List tables in the DuckDB file (`DBI::dbListTables()`)
-   Report row counts per data table
-   Query `__promotion_log` for promotion history (what batches, when)
-   Report anchor year range

------------------------------------------------------------------------

#### Step 10: Update tests

``` r
withr::with_tempdir({
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = "test_bronze.duckdb")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Collision via __promotion_log (not data table)
  DBI::dbExecute(con, "CREATE TABLE __promotion_log (batch_id TEXT PRIMARY KEY, ...)")
  DBI::dbExecute(con, "INSERT INTO __promotion_log VALUES ('b001', ...)")

  expect_error(
    .promote_df(con, ..., batch_id = "b001"),
    class = "xpipe_bronze_append_only"
  )

  # Schema evolution: new column
  df_v2 <- data.frame(id = 2L, val = "b", new_col = "x")
  expect_no_error(.promote_df(con, ..., batch_id = "b002", df = df_v2))
  expect_true("new_col" %in% DBI::dbListFields(con, "test__method__tbl"))

  # Historical row has NULL for new_col
  res <- DBI::dbGetQuery(con, "SELECT new_col FROM test__method__tbl WHERE __batch_id = 'b001'")
  expect_true(is.na(res$new_col))

  # Incompatible type change aborts
  expect_error(
    .promote_df(con, ..., batch_id = "b003", df = data.frame(id = "not_an_int")),
    class = "xpipe_bronze_schema_evolution"
  )
})
```

------------------------------------------------------------------------

### Phase 2 — Silver (implement when Silver layer begins)

**Canonical version ordering**:

``` sql
ROW_NUMBER() OVER (
  PARTITION BY <identity_keys>
  ORDER BY __batch_created_at DESC, __batch_id DESC
)
```

`__batch_created_at` is when the Batch artifact was created — it
represents the source delivery time and is stable regardless of when
Bronze promotion happens. `__batch_id` provides a deterministic
tie-breaker when two batches were created at the same millisecond.

`__bronze_promoted_at` must **not** be used as the version ordering
column for Silver. It reflects when Bronze promotion ran, which could
vary if Bronze is rebuilt from Batch. The Silver contract should state
"batch creation time" (`__batch_created_at`) as the canonical version
marker.

**Compute example** (anchor table):

``` sql
CREATE OR REPLACE TABLE current__TblScheda AS
SELECT * EXCLUDE (rn)
FROM (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY id_nosologico
      ORDER BY __batch_created_at DESC, __batch_id DESC
    ) AS rn
  FROM sdo__sdo_hosp_xml__TblScheda
  WHERE __anchor_year >= year(current_date) - 2
)
WHERE rn = 1;
```

**Secondary tables** (filtered to anchor version):

``` sql
CREATE OR REPLACE TABLE current__TblDiagnosi AS
SELECT d.*
FROM sdo__sdo_hosp_xml__TblDiagnosi d
INNER JOIN current__TblScheda s
  USING (id_nosologico, __batch_id);
```

**Export on demand** (if external consumers require Parquet):

``` r
DBI::dbExecute(con,
  "COPY current__TblScheda TO 'export/sdo_current.parquet' (FORMAT PARQUET)"
)
```

------------------------------------------------------------------------

## Contracts That Need Updating

### ✅ Batch Contract — No changes needed

### ⚠️ Bronze Contract — Significant update needed

| Section | Required change |
|----|----|
| **Physical Layout** | Replace `bronze/stream__method/year=YYYY/` with `bronze/{stream_id}.duckdb` and table naming convention |
| **Promotion Semantics** | Replace Parquet write steps with transaction sequence (BEGIN → check log → INSERT data → INSERT log → COMMIT) |
| **Append-Only Guarantee** | Collision detection moves from "file exists" to "`batch_id` present in `__promotion_log`" |
| **State Tracking** | `__promotion_log` inside DuckDB is authoritative. `layer.json` is a non-authoritative convenience cache. |
| **New: Transaction Boundary** | "A Bronze promotion is committed atomically. All data inserts and the `__promotion_log` entry succeed in the same transaction or the entire operation rolls back." |
| **New: Schema Evolution** | Document the column-level policy table from Step 7. |
| **New: Writer Model** | "Bronze promotion assumes a single writer per stream database." |

Semantic invariants (append-only, immutable batches, domain-time first,
self-describing rows) and mandatory column definitions are
**unchanged**.

### ⚠️ Silver Contract — Wording update needed

**Replace** the physical partitioning sentence with:

> "Silver-current may maintain physical or logical optimization
> structures based on stream anchor time, such as filtering on
> `__anchor_year`, to support incremental rebuilds and bounded
> recomputation. These are implementation details and do not alter
> dataset semantics."

**Add** a note on multi-table structure:

> "For multi-table streams, Silver-current is a consistent table family.
> Version selection is applied to the anchor table; secondary tables
> retain only rows belonging to the selected anchor version."

**Add** a note on canonical version ordering:

> "The canonical version marker for determining 'current' is batch
> creation time (`__batch_created_at`), with `__batch_id` as the
> deterministic tie-breaker. Bronze promotion time
> (`__bronze_promoted_at`) must not be used as the version marker."

### ✅ Privacy Contract — No changes needed

### ✅ Configuration Contract — No changes needed

### ⚠️ Error Taxonomy — One addition

```         
xpipe_bronze_schema_evolution    # incompatible type change during schema
                                  # reconciliation; manual migration required
```

Fits under `xpipe_bronze_error → xpipe_error`.

------------------------------------------------------------------------

## Implementation Order

Do not implement all phases in one pass. The risk is not conceptual
anymore; it is implementing too much at once and mixing three distinct
hard problems: storage migration, schema evolution, and Silver logic.

**Recommended sequence:**

1.  Update `docs/contracts/bronze contract.Rmd` to reflect DuckDB
    semantics
2.  Update `docs/contracts/silver_contract.Rmd` with storage-neutral
    wording and multi-table clarification
3.  Add `duckdb` and `DBI` to `DESCRIPTION`
4.  Implement scaffolding only:
    -   `.open_bronze_conn()`
    -   `__promotion_log` creation
    -   `BEGIN` / `COMMIT` / `ROLLBACK` wrappers
    -   Collision check against `__promotion_log`
5.  Implement single-table promotion for a simple fixture (SDO anchor
    table) — with tests passing
6.  Add `.reconcile_bronze_schema()` and schema evolution tests
7.  Add secondary-table promotion with anchor join
8.  Update `inspect_bronze()`
9.  Silver planning and implementation is a separate branch/plan

------------------------------------------------------------------------

## Rollback Plan

The `duck` branch is isolated. `main` retains the Parquet
implementation. If the migration is abandoned, `duck` is simply not
merged.

Existing Batch Parquet files on disk are unaffected. Bronze DuckDB files
are new artifacts in `data/bronze/`, not replacements for anything
already written by the Parquet pipeline.
