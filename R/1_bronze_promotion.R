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

  batch_root <- config$local$paths$batch
  checkmate::assert_string(batch_root)

  batch_dirs <- fs::dir_ls(batch_root, type = "directory", recurse = FALSE)
  if (length(batch_dirs) == 0) return(invisible(TRUE))

  # filtra batch validi (con metadata) e, se richiesto, per stream
  candidates <- character(0)
  metas <- list()

  for (bd in batch_dirs) {
    meta_path <- fs::path(bd, "_batch_metadata.json")
    if (!fs::file_exists(meta_path)) next

    meta <- rlang::try_fetch(jsonlite::fromJSON(meta_path, simplifyVector = FALSE),
                             error = function(e) NULL)
    if (is.null(meta)) next
    if (!is.null(stream) && !identical(meta$stream$id, stream)) next

    candidates <- c(candidates, bd)
    metas[[bd]] <- meta
  }

  if (length(candidates) == 0) return(invisible(TRUE))

  if (isTRUE(dry_run)) {
    for (bd in candidates) {
      cli::cli_inform("Would promote batch {.val {metas[[bd]]$batch_id}}")
    }
    return(invisible(TRUE))
  }

  # conferma una sola volta
  .confirm_bronze_promotion(confirm)

  for (bd in candidates) {
    meta <- metas[[bd]]

    tryCatch(
      .promote_batch_to_bronze(batch_dir = bd, config = config),
      xpipe_bronze_append_only = function(e) {
        cli::cli_inform("Skipping already promoted batch {.val {meta$batch_id}}")
        invisible(NULL)
      }
    )
  }

  invisible(TRUE)
}


# Helpers -----------------------------------------------------------------
#' Execute a statement and always clear the DBI result
#' @keywords internal
.db_exec <- function(con, sql, params = NULL) {
  res <- NULL
  on.exit({
    if (!is.null(res)) try(DBI::dbClearResult(res), silent = TRUE)
  }, add = TRUE)

  res <- DBI::dbSendStatement(con, sql, params = params)
  invisible(DBI::dbGetRowsAffected(res))
}

#' Fetch a query and always clear the DBI result
#' @keywords internal
.db_query <- function(con, sql, params = NULL) {
  res <- NULL
  on.exit({
    if (!is.null(res)) try(DBI::dbClearResult(res), silent = TRUE)
  }, add = TRUE)

  res <- DBI::dbSendQuery(con, sql, params = params)
  DBI::dbFetch(res)
}

#' Fetch a single scalar (first row/col) and clear the result
#' @keywords internal
.db_scalar <- function(con, sql, params = NULL) {
  out <- .db_query(con, sql, params = params)
  if (nrow(out) == 0 || ncol(out) == 0) return(NA)
  out[[1]][[1]]
}

#' Return TRUE if a Parquet file has at least one column
#' @keywords internal
.parquet_has_columns <- function(con, parquet_path) {
  pq_lit <- DBI::dbQuoteLiteral(con, as.character(parquet_path))
  n_cols <- .db_scalar(con,
                       paste0("SELECT COUNT(*) FROM parquet_schema(", pq_lit, ")")
  )
  isTRUE(!is.na(n_cols) && n_cols > 0)
}

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




#' Promote one Batch table into Bronze (DuckDB)
#'
#' Appends a single Parquet table from a materialized Batch directory into the
#' Bronze DuckDB database for the corresponding stream, using an atomic
#' transaction and an authoritative promotion log.
#'
#' The batch is considered promoted if and only if its `batch_id` is recorded
#' in `__promotion_log`.
#'
#' @param batch_dir Character scalar. Path to a Batch directory.
#' @param source_table Character scalar. Table name inside the batch
#'   (expects `<source_table>.parquet`).
#' @param config xpipe_config. Used to locate `paths$bronze`.
#'
#' @return Invisibly TRUE on success; aborts on error.
#' @keywords internal
.promote_one_table_to_bronze <- function(batch_dir, source_table, config) {
  checkmate::assert_string(batch_dir)
  checkmate::assert_string(source_table)
  checkmate::assert_class(config, "xpipe_config")

  meta_file <- "_batch_metadata.json"
  meta_path <- fs::path(batch_dir, meta_file)
  if (!fs::file_exists(meta_path)) {
    cli::cli_abort(
      c("Batch metadata not found",
        "x" = "Missing file: {.val {meta_file}} in {.file {batch_dir}}"),
      class = c("xpipe_batch_metadata", "xpipe_batch_error", "xpipe_error")
    )
  }

  meta <- rlang::try_fetch(
    jsonlite::fromJSON(meta_path, simplifyVector = FALSE),
    error = function(e) cli::cli_abort(
      c("Invalid batch metadata JSON",
        "x" = "Failed to parse {.val {meta_file}} in {.file {batch_dir}}"),
      parent = e,
      class = c("xpipe_batch_metadata", "xpipe_batch_error", "xpipe_error")
    )
  )

  batch_id         <- meta$batch_id %||% NA_character_
  stream_id        <- meta$stream$id %||% NA_character_
  method_id        <- meta$method$id %||% NA_character_
  batch_created_at <- meta$execution$created_at %||% NA_character_
  tool             <- meta$execution$tool %||% NA_character_
  tool_version     <- meta$execution$tool_version %||% NA_character_

  if (!checkmate::test_string(batch_id, min.chars = 1) ||
      !checkmate::test_string(stream_id, min.chars = 1) ||
      !checkmate::test_string(method_id, min.chars = 1) ||
      !checkmate::test_string(batch_created_at, min.chars = 1)) {
    cli::cli_abort(
      c("Batch metadata missing required fields",
        "x" = "Required: batch_id, stream.id, method.id, execution.created_at",
        "i" = "Batch metadata file in {.file {meta_path}}"),
      class = c("xpipe_batch_metadata", "xpipe_batch_error", "xpipe_error")
    )
  }

  parquet_path <- fs::path(batch_dir, paste0(source_table, ".parquet"))
  if (!fs::file_exists(parquet_path)) {
    cli::cli_abort(
      c("Batch table parquet not found",
        "x" = "Missing file: {.val {source_table}}.parquet in {.path {batch_dir}}"),
      class = c("xpipe_batch_materialization", "xpipe_batch_error", "xpipe_error")
    )
  }

  bronze_root <- config$local$paths$bronze
  if (!checkmate::test_string(bronze_root, min.chars = 1)) {
    cli::cli_abort(
      c("Bronze path not configured",
        "x" = "Expected config$local$paths$bronze to be set"),
      class = c("xpipe_bronze_state", "xpipe_bronze_error", "xpipe_error")
    )
  }

  con <- .open_bronze_conn(bronze_root, stream_id, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  .ensure_bronze_promotion_log(con)

  bronze_table <- paste0(stream_id, "__", method_id, "__", source_table)
  tbl_ident <- DBI::dbQuoteIdentifier(con, bronze_table)
  pq_lit <- DBI::dbQuoteLiteral(con, as.character(parquet_path))

  promoted_at <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

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
          c("Append-only violation",
            "x" = "Batch {.val {batch_id}} is already recorded in __promotion_log"),
          class = c("xpipe_bronze_append_only", "xpipe_bronze_error", "xpipe_error")
        )
      }

      DBI::dbExecute(
        con,
        paste0(
          "CREATE TABLE IF NOT EXISTS ", tbl_ident, " AS
           SELECT
             t.*,
             CAST(NULL AS TEXT)      AS __batch_id,
             CAST(NULL AS TEXT)      AS __stream_id,
             CAST(NULL AS TEXT)      AS __method_id,
             CAST(NULL AS TIMESTAMP) AS __batch_created_at,
             CAST(NULL AS TIMESTAMP) AS __bronze_promoted_at
           FROM read_parquet(", pq_lit, ") t
           WHERE 1=0"
        )
      )

      DBI::dbExecute(
        con,
        paste0(
          "INSERT INTO ", tbl_ident, "
           SELECT
             t.*,
             ? AS __batch_id,
             ? AS __stream_id,
             ? AS __method_id,
             CAST(? AS TIMESTAMP) AS __batch_created_at,
             CAST(? AS TIMESTAMP) AS __bronze_promoted_at
           FROM read_parquet(", pq_lit, ") t"
        ),
        params = list(batch_id, stream_id, method_id, batch_created_at, promoted_at)
      )

      DBI::dbExecute(
        con,
        "INSERT INTO __promotion_log
         (batch_id, stream_id, method_id, promoted_at, batch_created_at,
          anchor_source, tables, tool, tool_version)
         VALUES (?, ?, ?, CAST(? AS TIMESTAMP), CAST(? AS TIMESTAMP), ?, ?, ?, ?)",
        params = list(
          batch_id, stream_id, method_id,
          promoted_at, batch_created_at,
          NA_character_,
          jsonlite::toJSON(bronze_table, auto_unbox = TRUE),
          tool, tool_version
        )
      )

      DBI::dbCommit(con)
      invisible(TRUE)
    },
    error = function(e) {
      DBI::dbRollback(con)
      if (inherits(e, "xpipe_bronze_append_only")) stop(e)
      cli::cli_abort(
        c("Bronze promotion failed and was rolled back",
          "x" = "No partial data should remain for batch {.val {batch_id}}"),
        parent = e,
        class = c("xpipe_bronze_error", "xpipe_error")
      )
    }
  )
}


#' Promote an entire Batch into Bronze (DuckDB)
#'
#' Promotes all Parquet tables in a materialized Batch directory into the
#' Bronze DuckDB database for the corresponding stream, using a single
#' atomic transaction and a single authoritative promotion log entry.
#'
#' A batch is considered promoted if and only if its `batch_id` is present
#' in `__promotion_log`.
#'
#' @param batch_dir Character scalar. Path to a Batch directory.
#' @param config xpipe_config. Used to locate `paths$bronze`.
#'
#' @return Invisibly TRUE on success; aborts on error.
#' @keywords internal
.promote_batch_to_bronze <- function(batch_dir, config) {
  checkmate::assert_string(batch_dir)
  checkmate::assert_class(config, "xpipe_config")

  meta_file <- "_batch_metadata.json"
  meta_path <- fs::path(batch_dir, meta_file)
  if (!fs::file_exists(meta_path)) {
    cli::cli_abort(
      c("Batch metadata not found",
        "x" = "Missing file: {.val {meta_file}} in {.file {batch_dir}}"),
      class = c("xpipe_batch_metadata", "xpipe_batch_error", "xpipe_error")
    )
  }

  meta <- rlang::try_fetch(
    jsonlite::fromJSON(meta_path, simplifyVector = FALSE),
    error = function(e) cli::cli_abort(
      c("Invalid batch metadata JSON",
        "x" = "Failed to parse {.val {meta_file}} in {.file {batch_dir}}"),
      parent = e,
      class = c("xpipe_batch_metadata", "xpipe_batch_error", "xpipe_error")
    )
  )

  batch_id         <- meta$batch_id %||% NA_character_
  stream_id        <- meta$stream$id %||% NA_character_
  method_id        <- meta$method$id %||% NA_character_
  batch_created_at <- meta$execution$created_at %||% NA_character_
  tool             <- meta$execution$tool %||% NA_character_
  tool_version     <- meta$execution$tool_version %||% NA_character_

  if (!checkmate::test_string(batch_id, min.chars = 1) ||
      !checkmate::test_string(stream_id, min.chars = 1) ||
      !checkmate::test_string(method_id, min.chars = 1) ||
      !checkmate::test_string(batch_created_at, min.chars = 1)) {
    cli::cli_abort(
      c("Batch metadata missing required fields",
        "x" = "Required: batch_id, stream.id, method.id, execution.created_at",
        "i" = "Batch metadata file in {.file {meta_path}}"),
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

  anchor_tbl <- method_cfg$anchor_table %||% NA_character_

  if (!checkmate::test_string(anchor_tbl, min.chars = 1)) {
    cli::cli_abort(
      c(
        "Invalid method configuration",
        "x" = "Method {.val {method_id}} must define anchor_table"
      ),
      class = c("xpipe_bronze_anchor", "xpipe_bronze_error", "xpipe_error")
    )
  }


  parquet_files <- fs::dir_ls(batch_dir, glob = "*.parquet")
  if (length(parquet_files) == 0) {
    cli::cli_abort(
      c("No Parquet tables found in batch",
        "x" = "Expected one or more *.parquet files in {.file {batch_dir}}"),
      class = c("xpipe_batch_materialization", "xpipe_batch_error", "xpipe_error")
    )
  }

  source_tables <- fs::path_ext_remove(fs::path_file(parquet_files))
  # anchor table must exist in batch
  if (!(anchor_tbl %in% source_tables)) {
    cli::cli_abort(
      c(
        "Invalid batch for Bronze promotion",
        "x" = "Anchor table {.val {anchor_tbl}} is missing in batch {.val {batch_id}}"
      ),
      class = c("xpipe_bronze_anchor", "xpipe_bronze_error", "xpipe_error")
    )
  }


  bronze_root <- config$local$paths$bronze
  if (!checkmate::test_string(bronze_root, min.chars = 1)) {
    cli::cli_abort(
      c("Bronze path not configured",
        "x" = "Expected config$local$paths$bronze to be set"),
      class = c("xpipe_bronze_state", "xpipe_bronze_error", "xpipe_error")
    )
  }

  con <- .open_bronze_conn(bronze_root, stream_id, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  .ensure_bronze_promotion_log(con)

  promoted_at <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  promoted_tables <- character(0)

  DBI::dbBegin(con)

  rlang::try_fetch(
    {
      exists_in_log <- .db_scalar(
        con,
        "SELECT COUNT(*) AS n FROM __promotion_log WHERE batch_id = ?",
        params = list(batch_id)
      ) > 0

      if (isTRUE(exists_in_log)) {
        cli::cli_abort(
          c("Append-only violation",
            "x" = "Batch {.val {batch_id}} is already recorded in __promotion_log"),
          class = c("xpipe_bronze_append_only", "xpipe_bronze_error", "xpipe_error")
        )
      }

      for (tbl in source_tables) {
        parquet_path <- fs::path(batch_dir, paste0(tbl, ".parquet"))

        if (!fs::file_exists(parquet_path)) {
          cli::cli_warn("Skipping missing parquet for table {.val {tbl}} in batch {.val {batch_id}}")
          next
        }

        if (!.parquet_has_columns(con, parquet_path)) {
          cli::cli_warn("Skipping {.file {basename(parquet_path)}}: Parquet has zero columns.")
          next
        }

        pq_lit <- DBI::dbQuoteLiteral(con, as.character(parquet_path))

        bronze_table <- paste0(stream_id, "__", method_id, "__", tbl)
        tbl_ident <- DBI::dbQuoteIdentifier(con, bronze_table)

        .db_exec(
          con,
          paste0(
            "CREATE TABLE IF NOT EXISTS ", tbl_ident, " AS
           SELECT
             t.*,
             CAST(NULL AS TEXT)      AS __batch_id,
             CAST(NULL AS TEXT)      AS __stream_id,
             CAST(NULL AS TEXT)      AS __method_id,
             CAST(NULL AS TIMESTAMP) AS __batch_created_at,
             CAST(NULL AS TIMESTAMP) AS __bronze_promoted_at
           FROM read_parquet(", pq_lit, ") t
           WHERE 1=0"
          )
        )

        .db_exec(
          con,
          paste0(
            "INSERT INTO ", tbl_ident, "
           SELECT
             t.*,
             ? AS __batch_id,
             ? AS __stream_id,
             ? AS __method_id,
             CAST(? AS TIMESTAMP) AS __batch_created_at,
             CAST(? AS TIMESTAMP) AS __bronze_promoted_at
           FROM read_parquet(", pq_lit, ") t"
          ),
          params = list(batch_id, stream_id, method_id, batch_created_at, promoted_at)
        )

        promoted_tables <- c(promoted_tables, bronze_table)
      }

      .db_exec(
        con,
        "INSERT INTO __promotion_log
       (batch_id, stream_id, method_id, promoted_at, batch_created_at,
        anchor_source, tables, tool, tool_version)
       VALUES (?, ?, ?, CAST(? AS TIMESTAMP), CAST(? AS TIMESTAMP), ?, ?, ?, ?)",
        params = list(
          batch_id, stream_id, method_id,
          promoted_at, batch_created_at,
          NA_character_,
          jsonlite::toJSON(promoted_tables, auto_unbox = TRUE),
          tool, tool_version
        )
      )

      DBI::dbCommit(con)
      invisible(TRUE)
    },
    error = function(e) {
      try(.db_exec(con, "ROLLBACK"), silent = TRUE)
      if (inherits(e, "xpipe_bronze_append_only")) stop(e)
      cli::cli_abort(
        c("Bronze batch promotion failed",
          "x" = "Promotion did not complete; no partial state should remain."),
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
