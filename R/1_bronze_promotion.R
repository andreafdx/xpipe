# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 1. bronze_promotion.R
#
# Promotes materialized batches to the Bronze layer.
#
# Approach: Appends rows to the Bronze layer as an immutable ledger,
# deriving time partitions from anchor tables and enriching rows with metadata.
#
# Public API:  promote_to_bronze()
# Internals:   .get_bronze_state(), .save_bronze_state(), .identify_pending_batches(),
#              .validate_anchor_definitions(), .prepare_bronze_promotion_preview(),
#              .apply_bronze_promotion(), .now_iso(), .make_key(),
#              .promoted_batch_ids(), .make_promotion_event(),
#              .print_bronze_preview(), .confirm_bronze_promotion()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Error Class Taxonomy --------------------------------------------------------
#
#   xpipe_error
#   └── xpipe_bronze_error
#       ├── xpipe_bronze_state       # layer.json missing, invalid format, or bad write
#       ├── xpipe_bronze_anchor      # anchor table/column/key definition or join failure
#       ├── xpipe_bronze_partition   # unsupported partition granularity
#       ├── xpipe_bronze_append_only # shard already exists, refusing to overwrite
#       └── xpipe_bronze_abort       # user declined confirmation prompt

# Public API --------------------------------------------------------------

#' Promote materialized batches to the Bronze layer
#'
#' @description
#' Promotes immutable Batch artifacts into the Bronze layer as an
#' append-only, historical ledger.
#'
#' Each promotion:
#' \itemize{
#'   \item Appends rows only (no deletes, updates, or rewrites)
#'   \item Derives domain time from a single anchor table per batch
#'   \item Enriches all rows with mandatory Bronze metadata
#'   \item Partitions data by anchor-derived time (year or month)
#' }
#'
#' Bronze promotion preserves full history and lineage and does not
#' attempt deduplication, identity resolution, or "current state"
#' determination. These responsibilities are explicitly deferred to
#' the Silver layer.
#'
#' @section Preview and safety:
#' By default, Bronze promotion prints a preview showing:
#' \itemize{
#'   \item Batches to be promoted
#'   \item Anchor source used for time derivation
#'   \item Affected partition years
#'   \item Tables that will be appended
#' }
#'
#' Use \code{dry_run = TRUE} to perform validation and preview only,
#' without writing any data and without updating Bronze state.
#'
#' @section Storage layout:
#' Bronze is written as immutable Parquet shards per promoted batch:
#' \itemize{
#'   \item \code{bronze/<stream>__<method>/year=YYYY/<table>__<batch_id>.parquet}
#' }
#' Promotion refuses to overwrite an existing shard file.
#'
#' @section Anchor inheritance:
#' Anchor time is derived from the method anchor table only. Secondary tables
#' inherit \code{__anchor_time} by joining to the anchor table using
#' \code{identity_keys}. If required keys are missing or if rows cannot be matched,
#' promotion aborts for that batch.
#'
#' @section Immutability:
#' Bronze promotion is irreversible. Once rows are appended (written as shards),
#' they are never modified or removed.
#'
#' @param config xacc_config object.
#' @param stream Optional stream filter. If provided, only batches
#'   for the specified stream are considered.
#' @param dry_run Logical. If TRUE, performs validation and preview
#'   only. No files are written and no state is updated.
#' @param confirm Logical. If TRUE (default in interactive sessions),
#'   asks for confirmation before committing changes.
#'
#' @return Invisibly TRUE on success.
#'
#' @export
promote_to_bronze <- function(
    config = get_xpipe_config(),
    stream = NULL,
    dry_run = FALSE,
    confirm = interactive()
) {
  checkmate::assert_class(config, "xpipe_config")
  checkmate::assert_string(stream, null.ok = TRUE)
  checkmate::assert_flag(dry_run)
  checkmate::assert_flag(confirm)


}

# Helpers -----------------------------------------------------------------

## Pipeline ---------------------------------------------------------------



#' Open a DuckDB connection for the Bronze layer
#'
#' Opens (or creates, if missing) the DuckDB database file associated
#' with a given stream in the Bronze layer.
#'
#' The database file is located at:
#'   {bronze_root}/{stream_id}.duckdb
#'
#' This function does not create tables and does not perform any writes
#' by itself. It only establishes a DBI connection.
#'
#' DuckDB runs in-process. The returned connection points to a single
#' physical file on disk and must be explicitly closed by the caller
#' using DBI::dbDisconnect().
#'
#' @param bronze_root Character scalar. Path to the Bronze layer root directory.
#' @param stream_id Character scalar. Stream identifier (used as file name).
#' @param read_only Logical. If TRUE, opens the database in read-only mode.
#'
#' @return A DBI connection to the DuckDB database for the given stream.
#'
#' @examples
#' \dontrun{
#' con <- .open_bronze_conn("data/bronze", "sdo")
#' DBI::dbDisconnect(con, shutdown = TRUE)
#' }
#'
#' @keywords internal
.open_bronze_conn <- function(bronze_root, stream_id, read_only = FALSE) {
  checkmate::assert_string(bronze_root)
  checkmate::assert_string(stream_id)
  checkmate::assert_flag(read_only)

  db_path <- fs::path(bronze_root, paste0(stream_id, ".duckdb"))

  DBI::dbConnect(
    duckdb::duckdb(),
    dbdir = as.character(db_path),
    read_only = read_only
  )
}


#' Ensure Bronze promotion log table exists
#'
#' Creates the authoritative Bronze promotion log table
#' if it does not already exist.
#'
#' The promotion log records only successful promotions.
#' A batch is considered promoted if and only if its batch_id
#' appears in this table.
#'
#' This function is idempotent and safe to call multiple times.
#' It performs no inserts and does not start or end transactions.
#'
#' @param con A live DBI connection to a Bronze DuckDB database.
#'
#' @return Invisibly TRUE.
#'
#' @keywords internal
.ensure_bronze_promotion_log <- function(con) {
  checkmate::assert_class(con, "DBIConnection")

  sql <- "
    CREATE TABLE IF NOT EXISTS __promotion_log (
      batch_id         TEXT PRIMARY KEY,
      stream_id        TEXT NOT NULL,
      method_id        TEXT NOT NULL,
      promoted_at      TIMESTAMP NOT NULL,
      batch_created_at TIMESTAMP,
      anchor_source    TEXT,
      tables           TEXT,
      tool             TEXT,
      tool_version     TEXT
    )
  "

  DBI::dbExecute(con, sql)

  invisible(TRUE)
}




#' Promote one Batch table into Bronze (DuckDB, minimal transaction)
#'
#' Promotes a single Parquet table from a materialized Batch directory into the
#' Bronze DuckDB database for the corresponding stream.
#'
#' This is the minimal atomic promotion step:
#' it proves that Bronze promotion can be done transactionally and that the
#' authoritative promotion state lives inside DuckDB (`__promotion_log`).
#'
#' What it does:
#' - Reads batch metadata from `<batch_dir>/_batch_metadata.json`
#' - Opens (or creates) `data/bronze/<stream_id>.duckdb`
#' - Ensures `__promotion_log` exists
#' - Starts a transaction
#' - Checks `__promotion_log` for `batch_id` (append-only collision check)
#' - Creates the target Bronze table if missing (schema from Parquet + metadata cols)
#' - Inserts rows from Parquet via DuckDB `read_parquet()` (no R materialization)
#' - Inserts one row into `__promotion_log`
#' - Commits (or rolls back on any error)
#'
#' Currentness semantics:
#' - This function records `__batch_created_at` from batch metadata.
#' - It also records `promoted_at` in `__promotion_log` for operational audit.
#' - Silver must use `__batch_created_at` (plus `__batch_id` as tie-breaker)
#'   to order versions, not Bronze promotion time.
#'
#' @param batch_dir Character scalar. Path to a single batch directory.
#' @param source_table Character scalar. Name of the table inside the batch
#'   (Parquet file is expected as `<source_table>.parquet`).
#' @param config xpipe_config. Used to locate `paths$bronze`.
#'
#' @return Invisibly TRUE on success, otherwise aborts with xpipe error classes.
#'
#' @examples
#' \dontrun{
#' cfg <- get_xpipe_config()
#' .promote_one_table_to_bronze("data/batch/20260501T000850.993_sdo_xml_campania_2026",
#'                                    "anagrafica",
#'                                    cfg)
#' }
#'
#' @keywords internal
.promote_one_table_to_bronze <- function(batch_dir, source_table, config) {
  checkmate::assert_string(batch_dir)
  checkmate::assert_string(source_table)
  checkmate::assert_class(config, "xpipe_config")

  meta <- "_batch_metadata.json"
  meta_path <- fs::path(batch_dir, meta)
  if (!fs::file_exists(meta_path)) {
    cli::cli_abort(
      c(
        "Batch metadata not found",
        "x" = "Missing file: {.val {meta}} in {.file {batch_dir}}"
      ),
      class = c("xpipe_batch_metadata", "xpipe_batch_error", "xpipe_error")
    )
  }

  meta <- rlang::try_fetch(
    jsonlite::fromJSON(meta_path, simplifyVector = FALSE),
    error = function(e) cli::cli_abort(
      c(
        "Invalid batch metadata JSON",
        "x" = "Failed to parse {.val {meta}} in {.file {batch_dir}}"
      ),
      parent = e,
      class = c("xpipe_batch_metadata", "xpipe_batch_error", "xpipe_error")
    )
  )

  batch_id <- meta$batch_id %||% NA_character_
  stream_id <- meta$stream$id %||% NA_character_
  method_id <- meta$method$id %||% NA_character_
  batch_created_at <- meta$execution$created_at %||% NA_character_
  tool <- meta$execution$tool %||% NA_character_
  tool_version <- meta$execution$tool_version %||% NA_character_

  if (!checkmate::test_string(batch_id, min.chars = 1) ||
      !checkmate::test_string(stream_id, min.chars = 1) ||
      !checkmate::test_string(method_id, min.chars = 1) ||
      !checkmate::test_string(batch_created_at, min.chars = 1)) {
    cli::cli_abort(
      c(
        "Batch metadata missing required fields",
        "x" = "Required: batch_id, stream.id, method.id, execution.created_at",
        "i" = "Batch metadata file in {.file {meta_path}}"
      ),
      class = c("xpipe_batch_metadata", "xpipe_batch_error", "xpipe_error")
    )
  }

  parquet_path <- fs::path(batch_dir, paste0(source_table, ".parquet"))
  if (!fs::file_exists(parquet_path)) {
    cli::cli_abort(
      c(
        "Batch table parquet not found",
        "x" = "Missing file: {.val {source_table}}.parquet in {.path {batch_dir}}"
      ),
      class = c("xpipe_batch_materialization", "xpipe_batch_error", "xpipe_error")
    )
  }

  bronze_root <- config$local$paths$bronze
  if (!checkmate::test_string(bronze_root, min.chars = 1)) {
    cli::cli_abort(
      c(
        "Bronze path not configured",
        "x" = "Expected config$local$paths$bronze to be set"
      ),
      class = c("xpipe_bronze_state", "xpipe_bronze_error", "xpipe_error")
    )
  }

  con <- .open_bronze_conn(bronze_root, stream_id, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  .ensure_bronze_promotion_log(con)

  quote_ident <- function(x) DBI::dbQuoteIdentifier(con, x)
  promoted_at <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

  bronze_table <- paste0(stream_id, "__", method_id, "__", source_table)

  DBI::dbBegin(con)

  rlang::try_fetch(
    {
      exists_in_log <- DBI::dbGetQuery(
        con,
        "SELECT COUNT(*) AS n FROM __promotion_log WHERE batch_id = ?",
        params = list(batch_id)
      )$n[[1]] > 0

      if (isTRUE(exists_in_log)) {
        cli::cli_abort(
          c(
            "Append-only violation",
            "x" = "Batch {.val {batch_id}} is already recorded in __promotion_log"
          ),
          class = c("xpipe_bronze_append_only", "xpipe_bronze_error", "xpipe_error")
        )
      }

      create_sql <- paste0(
        "CREATE TABLE IF NOT EXISTS ", quote_ident(bronze_table), " AS ",
        "SELECT ",
        "  t.*, ",
        "  CAST(NULL AS TEXT) AS __batch_id, ",
        "  CAST(NULL AS TEXT) AS __stream_id, ",
        "  CAST(NULL AS TEXT) AS __method_id, ",
        "  CAST(NULL AS TIMESTAMP) AS __batch_created_at ",
        "FROM read_parquet(?) t ",
        "WHERE 1=0"
      )

      DBI::dbExecute(con, create_sql, params = list(as.character(parquet_path)))

      insert_sql <- paste0(
        "INSERT INTO ", quote_ident(bronze_table), " ",
        "SELECT ",
        "  t.*, ",
        "  ? AS __batch_id, ",
        "  ? AS __stream_id, ",
        "  ? AS __method_id, ",
        "  CAST(? AS TIMESTAMP) AS __batch_created_at ",
        "FROM read_parquet(?) t"
      )

      DBI::dbExecute(
        con,
        insert_sql,
        params = list(
          batch_id,
          stream_id,
          method_id,
          batch_created_at,
          as.character(parquet_path)
        )
      )

      tables_json <- jsonlite::toJSON(c(bronze_table), auto_unbox = TRUE)

      DBI::dbExecute(
        con,
        "INSERT INTO __promotion_log (batch_id, stream_id, method_id, promoted_at, batch_created_at, anchor_source, tables, tool, tool_version)
         VALUES (?, ?, ?, CAST(? AS TIMESTAMP), CAST(? AS TIMESTAMP), ?, ?, ?, ?)",
        params = list(
          batch_id,
          stream_id,
          method_id,
          promoted_at,
          batch_created_at,
          NA_character_,
          tables_json,
          tool,
          tool_version
        )
      )

      DBI::dbCommit(con)
      invisible(TRUE)
    },
    error = function(e) {
      DBI::dbRollback(con)
      cli::cli_abort(
        c(
          "Bronze promotion failed and was rolled back",
          "x" = "No partial data should remain for batch {.val {batch_id}}"
        ),
        parent = e,
        class = c("xpipe_bronze_error", "xpipe_error")
      )
    }
  )
}



#' Promote an entire Batch into Bronze (DuckDB) with anchor propagation
#'
#' Promotes all Parquet tables found in a Batch directory into the Bronze DuckDB
#' database for the stream, computing anchor metadata from the method's
#' anchor table and propagating it to secondary tables via identity keys.
#'
#' Key guarantees:
#' - Atomic promotion: all inserts and the promotion log entry commit together.
#' - Append-only: a batch_id already present in __promotion_log aborts promotion.
#' - Anchor semantics:
#'   - __anchor_source is "<anchor_table>.<partition_column>"
#'   - __anchor_time is derived from the anchor table partition column
#'   - __anchor_year is derived from __anchor_time
#'   - Secondary tables must match anchor rows on identity keys, otherwise abort
#'
#' SQL (plain description):
#' - We read Parquet files directly using DuckDB read_parquet('file.parquet').
#' - We create empty DuckDB tables with the right schema using:
#'   CREATE TABLE IF NOT EXISTS ... AS SELECT ... FROM read_parquet(...) WHERE 1=0
#' - We insert rows using INSERT INTO ... SELECT ... with computed metadata columns.
#' - For secondary tables we join read_parquet(secondary) with read_parquet(anchor)
#'   on identity keys to inherit anchor_time and anchor_year.
#'
#' @param batch_dir Character scalar. Path to a batch directory containing
#'   _batch_metadata.json and one or more .parquet files.
#' @param config xpipe_config. Must contain local paths and methods/streams contracts.
#'
#' @return Invisibly TRUE on success, otherwise aborts with xpipe error classes.
#'
#' @keywords internal
.promote_batch_to_bronze <- function(batch_dir, config) {
  checkmate::assert_string(batch_dir)
  checkmate::assert_class(config, "xpipe_config")

  meta_path <- fs::path(batch_dir, "_batch_metadata.json")
  if (!fs::file_exists(meta_path)) {
    cli::cli_abort(
      c(
        "Batch metadata not found",
        "x" = "Missing file: {.file {meta_path}}"
      ),
      class = c("xpipe_batch_metadata", "xpipe_batch_error", "xpipe_error")
    )
  }

  meta <- rlang::try_fetch(
    jsonlite::fromJSON(meta_path, simplifyVector = FALSE),
    error = function(e) cli::cli_abort(
      c(
        "Invalid batch metadata JSON",
        "x" = "Failed to parse {.file {meta_path}}"
      ),
      parent = e,
      class = c("xpipe_batch_metadata", "xpipe_batch_error", "xpipe_error")
    )
  )

  batch_id <- meta$batch_id %||% NA_character_
  stream_id <- meta$stream$id %||% NA_character_
  method_id <- meta$method$id %||% NA_character_
  batch_created_at <- meta$execution$created_at %||% NA_character_
  tool <- meta$execution$tool %||% NA_character_
  tool_version <- meta$execution$tool_version %||% NA_character_

  if (!checkmate::test_string(batch_id, min.chars = 1) ||
      !checkmate::test_string(stream_id, min.chars = 1) ||
      !checkmate::test_string(method_id, min.chars = 1) ||
      !checkmate::test_string(batch_created_at, min.chars = 1)) {
    cli::cli_abort(
      c(
        "Batch metadata missing required fields",
        "x" = "Required: batch_id, stream.id, method.id, execution.created_at"
      ),
      class = c("xpipe_batch_metadata", "xpipe_batch_error", "xpipe_error")
    )
  }

  method_cfg <- config$methods[[method_id]]
  if (is.null(method_cfg)) {
    cli::cli_abort(
      c(
        "Unknown method in batch metadata",
        "x" = "Method {.val {method_id}} not found in methods contract"
      ),
      class = c("xpipe_methods_error", "xpipe_error")
    )
  }

  anchor_table <- method_cfg$anchor_table %||% NA_character_
  partition_column <- method_cfg$partition_column %||% NA_character_
  identity_keys <- method_cfg$identity_keys %||% character(0)

  if (!checkmate::test_string(anchor_table, min.chars = 1) ||
      !checkmate::test_string(partition_column, min.chars = 1) ||
      !checkmate::test_character(identity_keys, min.len = 1)) {
    cli::cli_abort(
      c(
        "Invalid method anchor definition",
        "x" = "Method must define anchor_table, partition_column, identity_keys"
      ),
      class = c("xpipe_bronze_anchor", "xpipe_bronze_error", "xpipe_error")
    )
  }

  anchor_source <- paste0(anchor_table, ".", partition_column)

  parquet_files <- fs::dir_ls(batch_dir, glob = "*.parquet")
  if (length(parquet_files) == 0) {
    cli::cli_abort(
      c(
        "No parquet tables found in batch directory",
        "x" = "Expected one or more *.parquet files in {.file {batch_dir}}"
      ),
      class = c("xpipe_batch_materialization", "xpipe_batch_error", "xpipe_error")
    )
  }

  table_names <- fs::path_ext_remove(fs::path_file(parquet_files))
  if (!(anchor_table %in% table_names)) {
    cli::cli_abort(
      c(
        "Anchor table parquet not found in batch",
        "x" = "Expected anchor table {.val {anchor_table}}.parquet in batch directory",
        "i" = "Found tables: {.val {table_names}}"
      ),
      class = c("xpipe_bronze_anchor", "xpipe_bronze_error", "xpipe_error")
    )
  }

  bronze_root <- config$local$paths$bronze
  if (!checkmate::test_string(bronze_root, min.chars = 1)) {
    cli::cli_abort(
      c(
        "Bronze path not configured",
        "x" = "Expected config$local$paths$bronze to be set"
      ),
      class = c("xpipe_bronze_state", "xpipe_bronze_error", "xpipe_error")
    )
  }

  con <- .open_bronze_conn(bronze_root, stream_id, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  .ensure_bronze_promotion_log(con)

  quote_ident <- function(x) DBI::dbQuoteIdentifier(con, x)
  promoted_at <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

  anchor_path <- fs::path(batch_dir, paste0(anchor_table, ".parquet"))

  DBI::dbBegin(con)

  rlang::try_fetch(
    {
      already_promoted <- DBI::dbGetQuery(
        con,
        "SELECT COUNT(*) AS n FROM __promotion_log WHERE batch_id = ?",
        params = list(batch_id)
      )$n[[1]] > 0

      if (isTRUE(already_promoted)) {
        cli::cli_abort(
          c(
            "Append-only violation",
            "x" = "Batch {.val {batch_id}} is already recorded in __promotion_log"
          ),
          class = c("xpipe_bronze_append_only", "xpipe_bronze_error", "xpipe_error")
        )
      }

      key_expr <- paste0("concat_ws('\r', ", paste(sprintf("CAST(%s AS VARCHAR)", DBI::dbQuoteIdentifier(con, identity_keys)), collapse = ", "), ")")
      dup_sql <- paste0(
        "SELECT ",
        "  COUNT(*) AS n, ",
        "  COUNT(DISTINCT ", key_expr, ") AS nd ",
        "FROM read_parquet(?)"
      )
      dup_res <- DBI::dbGetQuery(con, dup_sql, params = list(as.character(anchor_path)))
      if (nrow(dup_res) == 1 && dup_res$n[[1]] != dup_res$nd[[1]]) {
        cli::cli_abort(
          c(
            "Anchor keys are not unique in this batch",
            "x" = "Cannot inherit anchor_time deterministically from anchor table",
            "i" = "Anchor table: {.val {anchor_table}}",
            "i" = "Keys: {.val {identity_keys}}"
          ),
          class = c("xpipe_bronze_anchor", "xpipe_bronze_error", "xpipe_error")
        )
      }

      for (tbl in table_names) {

        parquet_path <- fs::path(batch_dir, paste0(tbl, ".parquet"))
        bronze_table <- paste0(stream_id, "__", method_id, "__", tbl)

        create_sql <- paste0(
          "CREATE TABLE IF NOT EXISTS ", quote_ident(bronze_table), " AS ",
          "SELECT ",
          "  t.*, ",
          "  CAST(NULL AS TEXT) AS __batch_id, ",
          "  CAST(NULL AS TEXT) AS __stream_id, ",
          "  CAST(NULL AS TEXT) AS __method_id, ",
          "  CAST(NULL AS TIMESTAMP) AS __batch_created_at, ",
          "  CAST(NULL AS TIMESTAMP) AS __anchor_time, ",
          "  CAST(NULL AS INTEGER) AS __anchor_year, ",
          "  CAST(NULL AS TEXT) AS __anchor_source ",
          "FROM read_parquet(?) t ",
          "WHERE 1=0"
        )
        DBI::dbExecute(con, create_sql, params = list(as.character(parquet_path)))

        if (identical(tbl, anchor_table)) {
          insert_anchor_sql <- paste0(
            "INSERT INTO ", quote_ident(bronze_table), " ",
            "SELECT ",
            "  t.*, ",
            "  ? AS __batch_id, ",
            "  ? AS __stream_id, ",
            "  ? AS __method_id, ",
            "  CAST(? AS TIMESTAMP) AS __batch_created_at, ",
            "  try_cast(t.", DBI::dbQuoteIdentifier(con, partition_column), " AS TIMESTAMP) AS __anchor_time, ",
            "  EXTRACT(year FROM try_cast(t.", DBI::dbQuoteIdentifier(con, partition_column), " AS TIMESTAMP))::INTEGER AS __anchor_year, ",
            "  ? AS __anchor_source ",
            "FROM read_parquet(?) t"
          )
          DBI::dbExecute(
            con,
            insert_anchor_sql,
            params = list(
              batch_id, stream_id, method_id,
              batch_created_at,
              anchor_source,
              as.character(parquet_path)
            )
          )
        } else {
          total_sql <- "SELECT COUNT(*) AS n FROM read_parquet(?)"
          total_n <- DBI::dbGetQuery(con, total_sql, params = list(as.character(parquet_path)))$n[[1]]

          join_on <- paste(sprintf("d.%s = a.%s", DBI::dbQuoteIdentifier(con, identity_keys), DBI::dbQuoteIdentifier(con, identity_keys)), collapse = " AND ")

          matched_sql <- paste0(
            "SELECT COUNT(*) AS n ",
            "FROM read_parquet(?) d ",
            "INNER JOIN read_parquet(?) a ",
            "ON ", join_on
          )
          matched_n <- DBI::dbGetQuery(con, matched_sql, params = list(as.character(parquet_path), as.character(anchor_path)))$n[[1]]

          if (!identical(total_n, matched_n)) {
            cli::cli_abort(
              c(
                "Secondary table contains rows that do not match anchor table keys",
                "x" = "Refusing to promote inconsistent batch",
                "i" = "Secondary table: {.val {tbl}}",
                "i" = "Total rows: {.val {total_n}}",
                "i" = "Matched rows: {.val {matched_n}}"
              ),
              class = c("xpipe_bronze_anchor", "xpipe_bronze_error", "xpipe_error")
            )
          }

          insert_secondary_sql <- paste0(
            "INSERT INTO ", quote_ident(bronze_table), " ",
            "SELECT ",
            "  d.*, ",
            "  ? AS __batch_id, ",
            "  ? AS __stream_id, ",
            "  ? AS __method_id, ",
            "  CAST(? AS TIMESTAMP) AS __batch_created_at, ",
            "  try_cast(a.", DBI::dbQuoteIdentifier(con, partition_column), " AS TIMESTAMP) AS __anchor_time, ",
            "  EXTRACT(year FROM try_cast(a.", DBI::dbQuoteIdentifier(con, partition_column), " AS TIMESTAMP))::INTEGER AS __anchor_year, ",
            "  ? AS __anchor_source ",
            "FROM read_parquet(?) d ",
            "INNER JOIN read_parquet(?) a ",
            "ON ", join_on
          )

          DBI::dbExecute(
            con,
            insert_secondary_sql,
            params = list(
              batch_id, stream_id, method_id,
              batch_created_at,
              anchor_source,
              as.character(parquet_path),
              as.character(anchor_path)
            )
          )
        }
      }

      tables_json <- jsonlite::toJSON(paste0(stream_id, "__", method_id, "__", table_names), auto_unbox = TRUE)

      DBI::dbExecute(
        con,
        "INSERT INTO __promotion_log (batch_id, stream_id, method_id, promoted_at, batch_created_at, anchor_source, tables, tool, tool_version)
         VALUES (?, ?, ?, CAST(? AS TIMESTAMP), CAST(? AS TIMESTAMP), ?, ?, ?, ?)",
        params = list(
          batch_id, stream_id, method_id,
          promoted_at, batch_created_at,
          anchor_source, tables_json,
          tool, tool_version
        )
      )

      DBI::dbCommit(con)
      invisible(TRUE)
    },
    error = function(e) {
      DBI::dbRollback(con)
      cli::cli_abort(
        c(
          "Bronze promotion failed and was rolled back",
          "x" = "No partial data should remain for batch {.val {batch_id}}"
        ),
        parent = e,
        class = c("xpipe_bronze_error", "xpipe_error")
      )
    }
  )
}










## CLI --------------------------------------------------------------------



#' Confirm Bronze promotion
#'
#' @param confirm Logical. If TRUE, prompt user before writing.
#' @keywords internal
#' @noRd
.confirm_bronze_promotion <- function(confirm) {

  if (!isTRUE(confirm)) {
    return(invisible(TRUE))
  }

  answer <- readline("Proceed with Bronze promotion? [y/N]: ")

  if (!nzchar(answer) || tolower(substr(answer, 1, 1)) != "y") {
    cli::cli_abort(
      "Bronze promotion aborted by user.",
      class = c("xpipe_bronze_abort", "xpipe_bronze_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}
