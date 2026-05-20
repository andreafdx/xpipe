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
# Public API: promote_to_silver()
# Internals: .promote_to_silver_current(), .silver_exec(), .silver_query(),
#            .resolve_silver_canonical_method(), .is_silver_up_to_date(),
#            .confirm_silver_promotion()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


# Error Class Taxonomy ----------------------------------------------------



# Public API --------------------------------------------------------------

#' Promote data to Silver
#'
#' Uses silver.json to resolve canonical methods and build Silver-current tables.
#' Harmonized phase is intentionally not implemented in this branch.
#'
#' @param config xpipe_config.
#' @param stream Optional stream id. If NULL, promotes all enabled streams in silver.json.
#' @param phase Character. Only "current" is supported.
#' @param dry_run Logical. If TRUE, prints what would be done.
#' @param confirm Logical. Ask for confirmation before writing.
#'
#' @return Invisibly TRUE.
#' @export
promote_to_silver <- function(
    config = get_xpipe_config(),
    stream = NULL,
    phase = "current",
    dry_run = FALSE,
    confirm = interactive()
) {
  checkmate::assert_class(config, "xpipe_config")
  checkmate::assert_string(stream, null.ok = TRUE)
  checkmate::assert_string(phase)
  checkmate::assert_flag(dry_run)
  checkmate::assert_flag(confirm)

  if (is.null(config$silver) || length(config$silver) == 0) {
    cli::cli_abort(
      c(
        "Silver contract not loaded",
        "x" = "No silver streams found in config. Ensure data/shared/silver.json is present and valid."
      ),
      class = c("xpipe_config_error", "xpipe_error")
    )
  }

  if (!identical(phase, "current")) {
    cli::cli_abort(
      c(
        "Unsupported Silver phase",
        "x" = "Only {.val {'current'}} is supported in this branch."
      ),
      class = c("xpipe_silver_error", "xpipe_error")
    )
  }

  targets <- if (is.null(stream)) {
    # promote all streams with current.enabled = TRUE
    nms <- names(config$silver)
    nms[vapply(nms, function(sid) isTRUE(config$silver[[sid]]$current$enabled), logical(1))]
  } else {
    stream
  }

  unknown <- setdiff(targets, names(config$silver))
  if (length(unknown) > 0) {
    cli::cli_abort(
      c(
        "Invalid Silver stream",
        "x" = "Stream(s) not found in silver.json: {.val {unknown}}"
      ),
      class = c("xpipe_config_error", "xpipe_error")
    )
  }

  if (length(targets) == 0) {
    cli::cli_inform("No Silver-current streams enabled.")
    return(invisible(TRUE))
  }

  if (isTRUE(dry_run)) {
    for (sid in targets) {
      if (is.null(config$silver[[sid]])) {
        cli::cli_inform("Would SKIP stream {.val {sid}} (not in silver.json).")
        next
      }
      if (!isTRUE(config$silver[[sid]]$current$enabled)) {
        cli::cli_inform("Would SKIP stream {.val {sid}} (current.disabled).")
        next
      }
      mid <- .resolve_silver_canonical_method(sid, config)
      cli::cli_inform("Would promote Silver-current for stream {.val {sid}} using method {.val {mid}}.")
    }
    return(invisible(TRUE))
  }


  enabled <- targets[vapply(targets, function(sid) {
    isTRUE(config$silver[[sid]]$current$enabled)
  }, logical(1))]

  if (length(enabled) == 0) {
    cli::cli_inform("No Silver-current streams enabled.")
    return(invisible(TRUE))
  }

  # confirm once for the whole operation
  .confirm_silver_promotion(confirm)

  for (sid in enabled) {
    .promote_to_silver_current(
      stream_id = sid,
      config = config
    )
  }


  invisible(TRUE)
}

# Helpers -----------------------------------------------------------------


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

# Resolve canonical method for Silver-current
# @noRd
.resolve_silver_canonical_method <- function(stream_id, config) {
  if (is.null(config$silver[[stream_id]])) {
    cli::cli_abort(
      c(
        "Silver not configured for stream",
        "x" = "Stream {.val {stream_id}} not found in silver.json"
      ),
      class = c("xpipe_config_error", "xpipe_error")
    )
  }

  s <- config$silver[[stream_id]]

  if (!isTRUE(s$current$enabled)) {
    cli::cli_abort(
      c(
        "Silver-current disabled",
        "x" = "Silver-current is disabled for stream {.val {stream_id}}"
      ),
      class = c("xpipe_config_error", "xpipe_error")
    )
  }

  s$canonical_method
}

.is_silver_up_to_date <- function(con, stream_id, method_id, anchor_tbl) {

  latest_bronze <- .silver_query(
    con,
    paste0(
      "SELECT MAX(batch_id) AS batch_id
       FROM bronze.main.__promotion_log
       WHERE stream_id = ",
      DBI::dbQuoteLiteral(con, stream_id),
      " AND method_id = ",
      DBI::dbQuoteLiteral(con, method_id)
    )
  )$batch_id[[1]]

  current_anchor <- paste0("current__", anchor_tbl)

  silver_latest <- if (current_anchor %in% DBI::dbListTables(con)) {
    .silver_query(
      con,
      paste0(
        "SELECT MAX(__batch_id) AS batch_id
         FROM ", DBI::dbQuoteIdentifier(con, current_anchor)
      )
    )$batch_id[[1]]
  } else {
    NA_character_
  }


  if (is.na(latest_bronze) || is.na(silver_latest)) {
    return(FALSE)
  }

  identical(latest_bronze, silver_latest)

}

## Pipeline ----------------------------------------------------------------


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
.promote_to_silver_current <- function(stream_id, config) {


  # 1. Preconditions

  checkmate::assert_string(stream_id)
  checkmate::assert_class(config, "xpipe_config")

  method_id <- .resolve_silver_canonical_method(stream_id, config)

  method_cfg <- config$methods[[method_id]]
  if (is.null(method_cfg)) {
    cli::cli_abort(
      c(
        "Invalid Silver configuration",
        "x" = "Canonical method {.val {method_id}} not found in methods contract"
      ),
      class = c("xpipe_methods_error", "xpipe_error")
    )
  }
  anchor_tbl <- method_cfg$anchor_table
  keys <- method_cfg$identity_keys

  bronze_db <- fs::path(config$local$paths$bronze, paste0(stream_id, ".duckdb"))
  silver_db <- fs::path(config$local$paths$silver, paste0(stream_id, ".duckdb"))


  # 2. Open DuckDB and attach Bronze

  con <- DBI::dbConnect(duckdb::duckdb(), silver_db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  .silver_exec(
    con,
    paste0(
      "ATTACH ",
      DBI::dbQuoteLiteral(con, bronze_db),
      " AS bronze (READ_ONLY)"
    )
  )


  # 3. Up-to-date check + UX decision

  if (.is_silver_up_to_date(con, stream_id, method_id, anchor_tbl)) {

    answer <- readline(
      paste0(
        "Silver-current is already up to date for stream ",
        stream_id, ". Rebuild anyway? [y/N]: "
      )
    )

    if (!nzchar(answer) || tolower(substr(answer, 1, 1)) != "y") {
      cli::cli_inform(
        "Silver-current for stream {.val {stream_id}} left unchanged."
      )
      return(invisible(TRUE))
    }

    cli::cli_inform(
      "Rebuilding Silver-current for stream {.val {stream_id}} despite being up to date."
    )
  }


  # 4. Transactional rebuild

  DBI::dbBegin(con)

  rlang::try_fetch(
    {
      ## CREATE OR REPLACE current__anchor
      ## CREATE OR REPLACE current__secondary tables
      DBI::dbCommit(con)
      invisible(TRUE)
    },
    error = function(e) {
      try(DBI::dbRollback(con), silent = TRUE)
      cli::cli_abort(
        "Silver-current promotion failed",
        parent = e,
        class = c("xpipe_silver_error", "xpipe_error")
      )
    }
  )
}


## CLI ---------------------------------------------------------------------

#' Confirm Silver promotion
#'
#' @param confirm Logical.
#' @keywords internal
#' @noRd
.confirm_silver_promotion <- function(confirm = interactive()) {
  checkmate::assert_flag(confirm)

  if (!isTRUE(confirm)) return(invisible(TRUE))

  # Try climenu first, fall back cleanly if unsupported
  if (requireNamespace("climenu", quietly = TRUE) && interactive()) {
    choice <- tryCatch(
      climenu::select(
        c("Yes, continue", "No, abort"),
        prompt = "Proceed with Silver promotion?"
      ),
      error = function(e) NULL
    )
    if (!is.null(choice)) {
      if (choice != "Yes, continue") {
        cli::cli_abort(
          "Silver promotion aborted by user.",
          class = c("xpipe_silver_abort", "xpipe_silver_error", "xpipe_error")
        )
      }
      return(invisible(TRUE))
    }
  }

  answer <- readline("Proceed with Silver promotion? [y/N]: ")
  if (!nzchar(answer) || tolower(substr(answer, 1, 1)) != "y") {
    cli::cli_abort(
      "Silver promotion aborted by user.",
      class = c("xpipe_silver_abort", "xpipe_silver_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}

