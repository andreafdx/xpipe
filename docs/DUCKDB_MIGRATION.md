# DuckDB Migration Plan — Bronze and Silver Layers

**Branch**: `duck`  
**Status**: Planning (revised)  
**Date**: 2026-05-06

---

## Why This Change

The original Bronze implementation stored data as Hive-partitioned Parquet
shards — one file per batch per table per year. This design worked for
the initial prototype but has structural problems that become real at the
volumes this pipeline will process.

### 1. Small Files Problem

Streams like *File C* (5M+ rows/year, monthly batches) produce 12 shards
per year per table. After 5 years: 60+ shard files per table, each
holding ~400K rows. When queried via a DuckDB glob:

- Opening 60+ files
- Reading 60+ Parquet footers for statistics
- Marginal benefit from predicate pushdown on small per-file row groups

This is the documented failure mode of Parquet-based data lakes at scale.

### 2. Lack of ACID Safety on Promotion

Parquet is immutable. Appending data means writing a new file. A promotion
that writes 3 table files and crashes before the 4th leaves Bronze in a
permanently inconsistent state: those 3 shards exist but the batch is
`"pending"` in `layer.json`. Re-running immediately hits the collision
guard on the already-written files. There is no safe recovery path without
manual intervention.

### 3. Promotion Log Split-Brain

Under the current design, promotion has two separate write targets: Parquet
files on disk and `layer.json`. These are not atomic. A crash between the
last Parquet write and the `layer.json` update leaves data present but
state inconsistent. Moving to DuckDB without also moving the promotion log
into the same transaction would only shift this failure window, not
eliminate it.

### 4. Silver at Scale Requires DuckDB Anyway

The Silver window function (latest-wins per entity) over 25M+ rows of
Bronze cannot be done in R memory. `duckdb` is therefore a required
dependency regardless. Using it for Bronze storage costs nothing additional
and buys ACID safety and performance.

### 5. Silver Storage Consistency

If Bronze and Silver are both DuckDB, the Silver computation is a direct
SQL query from one DuckDB file to another — no format translation, no
`read_parquet` globs, no intermediate Arrow datasets in R memory.

---

## What Changes and What Stays

| Layer | Current | Target | Reason |
|---|---|---|---|
| **Batch** | Parquet + JSON | Parquet + JSON | No change. Isolated events, no accumulation, no ACID requirement. |
| **Bronze** | Hive-partitioned Parquet shards | DuckDB native (`.duckdb` per stream) | ACID appends, no shard proliferation, atomic promotion log. |
| **Silver** | Not yet implemented | DuckDB native (`.duckdb` per stream) | Window functions at 25M+ rows, multi-table family per stream. |

---

## New Physical Layout

### Bronze

```
data/bronze/
  sdo.duckdb
  farmaceutica.duckdb
```

One DuckDB database per stream. Each database contains:

- One data table per method-source-table combination
- One authoritative promotion log table: `__promotion_log`

**Table naming convention**: `{stream_id}__{method_id}__{source_table_name}`

The method segment is included because two methods for the same stream
may produce incompatible schemas (e.g. MDB extraction vs. XML extraction
for the same SDO stream), matching the `stream__method/` namespace of the
old Parquet layout.

Example for SDO with method `sdo_hosp_xml`:

```sql
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
  farmaceutica.duckdb
```

Silver is a **multi-table family** per stream, not a single flat table.
Version selection applies to the anchor table; secondary tables are
filtered to retain only rows from the selected anchor version.

**Table naming convention**: `{phase}__{source_table_name}`

```sql
-- inside sdo.duckdb
CREATE TABLE current__TblScheda   (...);  -- latest-wins anchor
CREATE TABLE current__TblDiagnosi (...);  -- filtered to current anchor version
CREATE TABLE current__TblProcedure (...);

CREATE TABLE harmonized__TblScheda   (...);  -- analytical form
CREATE TABLE harmonized__TblDiagnosi (...);
CREATE TABLE harmonized__TblProcedure (...);
```

A stream that has only one table will still follow this naming for
consistency: `current__<table>`, not a bare `current`.

---

## Concurrency and Writer Model

DuckDB in file-backed mode supports multiple concurrent readers (read-only
connections) but requires exclusive access for writers.

> **Bronze promotion assumes a single writer per stream database.**  
> Concurrent writes to the same `.duckdb` file are not supported and must
> not be attempted.

Analysts may query Bronze or Silver in read-only mode while no promotion
is running without issue:

```r
con <- DBI::dbConnect(duckdb::duckdb(), dbdir = "data/bronze/sdo.duckdb",
                      read_only = TRUE)
```

Scheduling two promotion jobs for the same stream concurrently is
undefined behavior and must be prevented at the orchestration level.

---

## Required Code Changes

### Phase 1 — Bronze (implement now, on `duck` branch)

**Step 1: Add `duckdb` and `DBI` to `DESCRIPTION` Imports**

Both are already available in the R ecosystem. `DBI` is the database
interface abstraction; `duckdb` provides the driver.

---

**Step 2: Create `.open_bronze_conn()` helper**

Opens (or creates) the stream DuckDB file. Returns a DBI connection.
Caller is responsible for disconnecting.

```r
.open_bronze_conn <- function(bronze_root, stream_id, read_only = FALSE) {
  db_path <- fs::path(bronze_root, paste0(stream_id, ".duckdb"))
  DBI::dbConnect(duckdb::duckdb(), dbdir = as.character(db_path),
                 read_only = read_only)
}
```

---

**Step 3: Create `__promotion_log` table (authoritative promotion state)**

This table replaces `layer.json` as the authoritative source of truth for
promoted batches. It is created on first use and is committed atomically
with the data inserts.

```sql
CREATE TABLE IF NOT EXISTS __promotion_log (
  batch_id         TEXT PRIMARY KEY,
  stream_id        TEXT NOT NULL,
  method_id        TEXT NOT NULL,
  status           TEXT NOT NULL,        -- 'promoted'
  promoted_at      TIMESTAMP NOT NULL,
  batch_created_at TIMESTAMP,
  anchor_source    TEXT,
  tables           TEXT,                 -- JSON array of table names
  tool             TEXT,
  tool_version     TEXT
);
```

`layer.json` may be retained as a non-authoritative, human-readable
summary written after a successful promotion (a convenience cache for
quick inspection without opening DuckDB). It must not be used as the
source of truth for batch state.

---

**Step 4: Create `.ensure_bronze_table()` helper**

Creates the data table if it does not yet exist, using the schema of the
incoming data frame plus mandatory metadata columns. All domain columns are
created as `VARCHAR DEFAULT NULL` when type is unknown; see Step 5 for type
handling.

All domain columns are nullable by default. Only metadata columns have
constraints.

---

**Step 5: Create `.reconcile_bronze_schema()` — Schema Evolution Policy**

This is a critical component with no equivalent in the Parquet design.

DuckDB tables are strictly typed. When a source delivers a new column
(e.g. the Ministry updates the SDO tracciato), or drops a column, the
Bronze table must be reconciled before the INSERT. This runs inside the
same transaction as the INSERT.

The policy:

| Scenario | Action |
|---|---|
| **New column in source, absent from Bronze table** | `ALTER TABLE ADD COLUMN <name> <type> DEFAULT NULL` + `cli_warn()`. Historical rows get NULL. |
| **Column absent from source, present in Bronze table** | INSERT NULL (naturally handled by name-based INSERT). Log a warning. |
| **Type widening** (`INT → BIGINT`, `DATE → TIMESTAMP`) | Allow. `ALTER TABLE ALTER COLUMN TYPE`. |
| **Incompatible type change** (`DATE → VARCHAR`, `INTEGER → BOOLEAN`) | Hard abort: `xpipe_bronze_schema_evolution`. Manual intervention required. |
| **Identity key column missing or null** | Hard abort regardless of schema policy. This is a source data failure, not schema evolution. |
| **Column reordering in source** | Harmless. INSERT is always name-based. |
| **All-NA column in source** | DuckDB may infer as `INTEGER`. Coerce to `VARCHAR` as a safe default; log a warning. |

```r
.reconcile_bronze_schema <- function(con, table_name, incoming_df, identity_keys) {
  existing_cols  <- DBI::dbListFields(con, table_name)
  incoming_cols  <- names(incoming_df)

  # Identity keys must be present
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
    DBI::dbExecute(con,
      glue::glue("ALTER TABLE {table_name} ADD COLUMN IF NOT EXISTS \"{col}\" {dtype} DEFAULT NULL")
    )
  }

  # Dropped columns: log only (INSERT will handle with NULLs)
  dropped_cols <- setdiff(
    setdiff(existing_cols, .bronze_metadata_cols()),
    incoming_cols
  )
  if (length(dropped_cols) > 0) {
    cli::cli_warn("Column(s) absent from this batch, NULL will be inserted: {.val {dropped_cols}}")
  }

  invisible(NULL)
}
```

---

**Step 6: Refactor `.apply_bronze_promotion()`**

Replace the current `arrow::write_parquet()` approach with a fully atomic
DuckDB transaction:

```r
# Pseudo-code — actual implementation will handle error classes and CLI output

con <- .open_bronze_conn(bronze_root, stream_id)
on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

DBI::dbBegin(con)

tryCatch({

  for (each enriched data frame) {
    table_name <- glue("{stream_id}__{method_id}__{source_table}")

    # Create table if it doesn't exist
    .ensure_bronze_table(con, table_name, df, metadata_cols)

    # Reconcile schema (adds missing columns, detects incompatible types)
    .reconcile_bronze_schema(con, table_name, df, identity_keys)

    # Collision check: has this batch already been promoted?
    n <- DBI::dbGetQuery(con,
      "SELECT COUNT(*) FROM {table_name} WHERE __batch_id = ?",
      params = list(batch_id)
    )[[1]]
    if (n > 0) cli::cli_abort(..., class = "xpipe_bronze_append_only")

    # INSERT from Parquet directly — no R data frame materialization
    # for large production batches
    DBI::dbExecute(con, glue("
      INSERT INTO {table_name}
      SELECT
        *,
        '{batch_id}'   AS __batch_id,
        '{stream_id}'  AS __stream_id,
        '{method_id}'  AS __method_id,
        '{promoted_at}' AS __bronze_promoted_at
        -- ... other metadata cols
      FROM read_parquet('{parquet_path}')
    "))
  }

  # Insert promotion event into authoritative log (same transaction)
  DBI::dbExecute(con,
    "INSERT INTO __promotion_log VALUES (?, ?, ?, 'promoted', ?, ?, ?, ?, ?, ?)",
    params = list(batch_id, stream_id, method_id, promoted_at, ...)
  )

  DBI::dbCommit(con)

}, error = function(e) {
  DBI::dbRollback(con)
  stop(e)
})
```

> **Key principle**: `read_parquet()` in DuckDB SQL reads the Batch Parquet
> file directly from disk. No R data frame materialization is needed for
> production batches. This keeps memory bounded regardless of batch size.
> `dbAppendTable()` with a pre-loaded data frame remains valid for unit
> tests with small fixtures.

---

**Step 7: Update `inspect_bronze()` in `layers_inspect.R`**

Currently lists `.parquet` files. Must instead:

- List tables in the DuckDB file (`DBI::dbListTables()`)
- Report row counts per table
- Report distinct `__batch_id` values present
- Report anchor year range
- Optionally: query `__promotion_log` for promotion history

---

**Step 8: Update tests**

- `test-bronze_helpers.R`: use `withr::with_tempdir()` + a temporary
  DuckDB file instead of temp Parquet files
- `test-inspect_layer.R`: update expectations for DuckDB-backed Bronze
- Add tests specifically for schema evolution: new column, dropped column,
  incompatible type change, missing identity key

```r
withr::with_tempdir({
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = "test_bronze.duckdb")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # ... test promotion, collision, schema evolution ...
})
```

---

### Phase 2 — Silver (implement when Silver layer begins)

Silver compute and storage, to be detailed in a separate plan. Summary:

**Compute**: DuckDB SQL window functions, reading from Bronze DuckDB.

```sql
-- Silver-current: anchor table (version selection)
CREATE OR REPLACE TABLE current__TblScheda AS
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

-- Silver-current: secondary tables
-- Filtered to retain only rows belonging to the selected anchor version
CREATE OR REPLACE TABLE current__TblDiagnosi AS
SELECT d.*
FROM sdo__sdo_hosp_xml__TblDiagnosi d
INNER JOIN current__TblScheda s
  USING (id_nosologico, __batch_id);
```

**Storage**: `data/silver/{stream_id}.duckdb`, tables named
`current__<table>` and `harmonized__<table>`.

**Export**: On-demand Parquet export if external consumers require it:

```r
DBI::dbExecute(con,
  "COPY current__TblScheda TO 'export/sdo_current.parquet' (FORMAT PARQUET)"
)
```

---

## Contracts That Need Updating

### ✅ Batch Contract — No changes needed

Batch stays Parquet. The contract is accurate.

### ⚠️ Bronze Contract — Significant update needed

| Section | Required change |
|---|---|
| **Physical Layout** | Replace `bronze/stream__method/year=YYYY/` with `bronze/{stream_id}.duckdb` layout and table naming convention |
| **Promotion Semantics** | Replace Parquet write steps with DuckDB `BEGIN TRANSACTION ... INSERT INTO ... COMMIT` |
| **Append-Only Guarantee** | Collision detection moves from "file exists on disk" to "`__batch_id` present in `__promotion_log`" |
| **State Tracking** | Replace `layer.json` as authoritative source with `__promotion_log` table inside DuckDB; `layer.json` demoted to non-authoritative cache |
| **New section: Transaction Boundary** | "A Bronze promotion is committed atomically. All table inserts and the promotion log entry must succeed in the same DuckDB transaction. If any operation fails, the entire transaction is rolled back and the batch remains unpromoted." |
| **New section: Schema Evolution** | Document the column-level evolution policy (new columns → ALTER TABLE; dropped columns → NULL; incompatible types → abort; identity key absence → abort) |
| **New section: Writer Model** | "Bronze promotion assumes a single writer per stream database. Concurrent writes are not supported." |

Core semantic invariants (append-only, immutable batches, domain-time
first, self-describing rows) are **unchanged**. The mandatory metadata
columns table is **unchanged**.

### ⚠️ Silver Contract — Wording update needed

The Silver contract is largely storage-format neutral, which is good.
One section needs updating:

**Current** (`§Silver-current, Persistence and physical layout`):
> "Silver-current may be physically partitioned by year according to the
> stream configuration..."

**Replace with**:
> "Silver-current may maintain physical or logical optimization structures
> based on stream anchor time, such as filtering on `__anchor_year`, to
> support incremental rebuilds and bounded recomputation. These structures
> are implementation details and do not alter dataset semantics."

Also add a note on multi-table structure:
> "For multi-table streams, Silver-current is a consistent table family,
> not a single table. Version selection is applied to the anchor table;
> all secondary tables retain only rows belonging to the selected anchor
> version."

### ✅ Privacy Contract — No changes needed

Pseudonymization happens in the Batch phase, in memory, before any write.
Storage format is irrelevant.

### ✅ Configuration Contract — No changes needed

`local.json`'s `paths.bronze` and `paths.silver` remain directory paths.
DuckDB files live inside those directories.

### ✅ Error Taxonomy — Additions only

One new error class is needed:

```
xpipe_bronze_schema_evolution    # incompatible type change detected during
                                  # schema reconciliation; manual migration required
```

Fits under `xpipe_bronze_error → xpipe_error`.

---

## Test Strategy

```r
withr::with_tempdir({
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = "test_bronze.duckdb")
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # --- schema evolution tests ---

  # New column added to source
  df_v1 <- data.frame(id = 1L, val = "a")
  df_v2 <- data.frame(id = 2L, val = "b", new_col = "x")  # new column

  # First promotion creates the table
  .promote_df(con, "test__method__tbl", df_v1, batch_id = "b001", ...)

  # Second promotion should ALTER TABLE and succeed
  expect_no_error(
    .promote_df(con, "test__method__tbl", df_v2, batch_id = "b002", ...)
  )
  expect_true("new_col" %in% DBI::dbListFields(con, "test__method__tbl"))

  # Historical row should have NULL for new_col
  res <- DBI::dbGetQuery(con, "SELECT new_col FROM test__method__tbl WHERE __batch_id = 'b001'")
  expect_true(is.na(res$new_col))

  # Incompatible type change should abort
  df_v3 <- data.frame(id = "not_an_integer", val = "c")  # type conflict
  expect_error(
    .promote_df(con, "test__method__tbl", df_v3, batch_id = "b003", ...),
    class = "xpipe_bronze_schema_evolution"
  )
})
```

---

## Rollback Plan

The `duck` branch is isolated. `main` retains the Parquet implementation.
If the migration is abandoned, `duck` is simply not merged.

Existing Batch Parquet files on disk are unaffected. Bronze DuckDB files
are new artifacts in `data/bronze/`, not replacements for anything already
written by the Parquet pipeline.
