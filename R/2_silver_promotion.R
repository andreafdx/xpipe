# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 2. silver_promotion.R
#
# Promotes Bronze data to the Silver layer.
#
# Approach:
# Builds Silver-current tables from Bronze DuckDB tables. Currentness is defined
# by the latest batch containing each entity, ordered by __batch_created_at and
# __batch_id. Secondary tables are filtered by joining to the current anchor
# table using identity keys plus __batch_id.
#
# Public API:
# Internals: .promote_to_silver_current(), .silver_exec(), .silver_query()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

#' Execute a Silver SQL statement and always clear the result
#'
#' @param con DBI connection.
#' @param sql SQL statement.
#' @param params Optional query parameters.
#'
#' @return Invisibly returns rows affected.
#' @keywords internal
.silver_exec <- function(con, sql, params = NULL) {
  res <- NULL
  on.exit({
    if (!is.null(res)) try(DBI::dbClearResult(res), silent = TRUE)
  }, add = TRUE)

  res <- DBI::dbSendStatement(con, sql, params = params)
  invisible(DBI::dbGetRowsAffected(res))
}

#' Run a Silver SQL query and always clear the result
#'
#' @param con DBI connection.
#' @param sql SQL query.
#' @param params Optional query parameters.
#'
#' @return A data.frame.
#' @keywords internal
.silver_query <- function(con, sql, params = NULL) {
  res <- NULL
  on.exit({
    if (!is.null(res)) try(DBI::dbClearResult(res), silent = TRUE)
  }, add = TRUE)

  res <- DBI::dbSendQuery(con, sql, params = params)
  DBI::dbFetch(res)
}

#' Promote Bronze data to Silver-current (DuckDB)
#'
#' Builds Silver-current tables for a given stream and method by selecting the
#' latest batch per entity from the anchor table and collecting secondary tables
#' via `(identity_keys + __batch_id)`.
#'
#' Currentness is defined by ingestion order:
#' `__batch_created_at DESC, __batch_id DESC`.
#'
#' @param stream_id Character scalar. Stream identifier.
#' @param method_id Character scalar. Method identifier.
#' @param config xpipe_config.
#'
#' @return Invisibly TRUE on success.
#' @keywords internal
.promote_to_silver_current <- function(stream_id, method_id, config) {
  checkmate::assert_string(stream_id)
  checkmate::assert_string(method_id)
  checkmate::assert_class(config, "xpipe_config")

  bronze_root <- config$local$paths$bronze
  silver_root <- config$local$paths$silver

  if (!checkmate::test_string(bronze_root, min.chars = 1) ||
      !checkmate::test_string(silver_root, min.chars = 1)) {
    cli::cli_abort(
      c(
        "Silver promotion failed",
        "x" = "Both paths$bronze and paths$silver must be configured"
      ),
      class = c("xpipe_silver_state", "xpipe_error")
    )
  }

  method_cfg <- config$methods[[method_id]]
  if (is.null(method_cfg)) {
    cli::cli_abort(
      c(
        "Unknown method",
        "x" = "Method {.val {method_id}} not found in methods contract"
      ),
      class = c("xpipe_methods_error", "xpipe_error")
    )
  }

  anchor_tbl <- method_cfg$anchor_table %||% NA_character_
  keys <- method_cfg$identity_keys %||% character(0)

  if (!checkmate::test_string(anchor_tbl, min.chars = 1) ||
      !checkmate::test_character(keys, min.len = 1)) {
    cli::cli_abort(
      c(
        "Invalid Silver configuration",
        "x" = "Method must define anchor_table and identity_keys"
      ),
      class = c("xpipe_silver_config", "xpipe_error")
    )
  }

  bronze_db <- fs::path(bronze_root, paste0(stream_id, ".duckdb"))
  silver_db <- fs::path(silver_root, paste0(stream_id, ".duckdb"))

  if (!fs::file_exists(bronze_db)) {
    cli::cli_abort(
      c(
        "Bronze database not found",
        "x" = "Expected {.file {bronze_db}} to exist"
      ),
      class = c("xpipe_bronze_state", "xpipe_error")
    )
  }

  fs::dir_create(silver_root, recurse = TRUE)

  con_s <- DBI::dbConnect(
    duckdb::duckdb(),
    dbdir = as.character(silver_db),
    read_only = FALSE
  )

  on.exit({
    try(.silver_exec(con_s, "DETACH bronze"), silent = TRUE)
    DBI::dbDisconnect(con_s, shutdown = TRUE)
  }, add = TRUE)

  try(.silver_exec(con_s, "DETACH bronze"), silent = TRUE)

  .silver_exec(
    con_s,
    paste0(
      "ATTACH ",
      DBI::dbQuoteLiteral(con_s, as.character(bronze_db)),
      " AS bronze (READ_ONLY)"
    )
  )

  prefix <- paste0(stream_id, "__", method_id, "__")
  anchor_full <- paste0(prefix, anchor_tbl)

  bronze_tables <- .silver_query(
    con_s,
    "SELECT table_name
     FROM duckdb_tables()
     WHERE database_name = 'bronze'
       AND schema_name = 'main'"
  )$table_name

  method_tables <- bronze_tables[startsWith(bronze_tables, prefix)]

  if (!(anchor_full %in% method_tables)) {
    cli::cli_abort(
      c(
        "Anchor table not found in Bronze",
        "x" = "Expected {.val {anchor_full}} to exist"
      ),
      class = c("xpipe_silver_anchor", "xpipe_error")
    )
  }

  current_anchor <- paste0("current__", anchor_tbl)

  key_cols <- DBI::dbQuoteIdentifier(con_s, keys)
  keys_sql <- paste(key_cols, collapse = ", ")

  bronze_anchor <- paste0(
    "bronze.main.",
    DBI::dbQuoteIdentifier(con_s, anchor_full)
  )

  DBI::dbBegin(con_s)

  rlang::try_fetch(
    {
      .silver_exec(
        con_s,
        paste0(
          "CREATE OR REPLACE TABLE ",
          DBI::dbQuoteIdentifier(con_s, current_anchor), " AS
           SELECT * EXCLUDE (rn)
           FROM (
             SELECT
               a.*,
               ROW_NUMBER() OVER (
                 PARTITION BY ", keys_sql, "
                 ORDER BY __batch_created_at DESC, __batch_id DESC
               ) AS rn
             FROM ", bronze_anchor, " a
           ) t
           WHERE rn = 1"
        )
      )

      for (bt in method_tables) {
        short <- sub(prefix, "", bt, fixed = TRUE)
        if (identical(short, anchor_tbl)) next

        bronze_sec <- paste0(
          "bronze.main.",
          DBI::dbQuoteIdentifier(con_s, bt)
        )

        current_sec <- paste0("current__", short)

        join_keys <- paste(
          paste0(
            "s.", DBI::dbQuoteIdentifier(con_s, keys),
            " = a.", DBI::dbQuoteIdentifier(con_s, keys)
          ),
          collapse = " AND "
        )

        .silver_exec(
          con_s,
          paste0(
            "CREATE OR REPLACE TABLE ",
            DBI::dbQuoteIdentifier(con_s, current_sec), " AS
             SELECT s.*
             FROM ", bronze_sec, " s
             INNER JOIN ", DBI::dbQuoteIdentifier(con_s, current_anchor), " a
               ON ", join_keys, "
              AND s.__batch_id = a.__batch_id"
          )
        )
      }

      DBI::dbCommit(con_s)
      invisible(TRUE)
    },
    error = function(e) {
      try(DBI::dbRollback(con_s), silent = TRUE)
      cli::cli_abort(
        c(
          "Silver-current promotion failed",
          "x" = "Silver tables were not rebuilt successfully."
        ),
        parent = e,
        class = c("xpipe_silver_error", "xpipe_error")
      )
    }
  )
}
