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
#            .resolve_silver_canonical_method(), .normalize_silver_as_of(),
#            .is_silver_up_to_date(), .confirm_silver_promotion(),
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
#' @param as_of Optional ingestion snapshot timestamp. If provided, Silver-current
#'   is rebuilt using only Bronze rows with `__batch_created_at <= as_of`.
#'   This is an ingestion-time snapshot, it does not have domain temporal meaning.
#'
#' @return Invisibly TRUE.
#' @export
promote_to_silver <- function(
    config = get_xpipe_config(),
    stream = NULL,
    phase = "current",
    as_of = NULL,
    dry_run = FALSE,
    confirm = interactive()
) {
  checkmate::assert_class(config, "xpipe_config")
  checkmate::assert_string(stream, null.ok = TRUE)
  checkmate::assert_string(phase)
  checkmate::assert_flag(dry_run)
  checkmate::assert_flag(confirm)
  as_of <- .normalize_silver_as_of(as_of)

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

  targets <- .select_silver_promotion_targets(
    config = config,
    stream = stream
  )

  if (length(targets) == 0) {
    cli::cli_inform("No Silver-current streams enabled.")
    return(invisible(TRUE))
  }

  # Dry Run block

  if (isTRUE(dry_run)) {
    for (sid in targets) {
      mid <- .resolve_silver_canonical_method(sid, config)

      if (is.null(as_of)) {
        cli::cli_inform(
          "Would promote Silver-current for stream {.val {sid}} using method {.val {mid}}."
        )
      } else {
        cli::cli_inform(
          "Would promote Silver-current for stream {.val {sid}} using method {.val {mid}} as of ingestion snapshot {.val {as_of}}."
        )
      }
    }
    return(invisible(TRUE))
  }

  .confirm_silver_promotion(confirm)

  for (sid in targets) {
    .promote_to_silver_current(
      stream_id = sid,
      config = config,
      as_of = as_of
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


.select_silver_promotion_targets <- function(config, stream = NULL) {
  checkmate::assert_class(config, "xpipe_config")
  checkmate::assert_string(stream, null.ok = TRUE)

  silver_streams <- names(config$silver)

  if (length(silver_streams) == 0) {
    cli::cli_abort(
      c(
        "Silver contract not loaded",
        "x" = "No streams found in silver.json."
      ),
      class = c("xpipe_config_error", "xpipe_error")
    )
  }

  enabled <- silver_streams[vapply(
    silver_streams,
    function(sid) isTRUE(config$silver[[sid]]$current$enabled),
    logical(1)
  )]

  if (!is.null(stream)) {
    if (!(stream %in% silver_streams)) {
      cli::cli_abort(
        c(
          "Invalid Silver stream",
          "x" = "Stream {.val {stream}} not found in silver.json"
        ),
        class = c("xpipe_config_error", "xpipe_error")
      )
    }

    if (!isTRUE(config$silver[[stream]]$current$enabled)) {
      cli::cli_abort(
        c(
          "Silver-current disabled",
          "x" = "Silver-current is disabled for stream {.val {stream}}"
        ),
        class = c("xpipe_config_error", "xpipe_error")
      )
    }

    return(stream)
  }

  if (length(enabled) == 0) {
    return(character(0))
  }

  # Non-interactive: preserve pipeline behavior.
  # stream = NULL means all enabled streams.
  if (!interactive()) {
    return(enabled)
  }

  choices <- c("All enabled streams", enabled, "Abort")

  choice <- NULL
  if (requireNamespace("climenu", quietly = TRUE)) {
    choice <- tryCatch(
      climenu::select(
        choices,
        prompt = "Select Silver stream to promote"
      ),
      error = function(e) NULL
    )
  }

  if (is.null(choice)) {
    cat("\nSelect Silver stream to promote\n\n")
    for (i in seq_along(choices)) {
      cat(sprintf(" %d. %s\n", i, choices[[i]]))
    }
    cat("\n")

    k <- suppressWarnings(as.integer(readline("Enter number: ")))

    if (is.na(k) || k < 1 || k > length(choices)) {
      cli::cli_abort(
        "Invalid selection.",
        class = c("xpipe_silver_abort", "xpipe_silver_error", "xpipe_error")
      )
    }

    choice <- choices[[k]]
  }

  if (identical(choice, "Abort")) {
    cli::cli_abort(
      "Silver promotion aborted by user.",
      class = c("xpipe_silver_abort", "xpipe_silver_error", "xpipe_error")
    )
  }

  if (identical(choice, "All enabled streams")) {
    return(enabled)
  }

  choice
}


.normalize_silver_as_of <- function(as_of = NULL) {
  if (is.null(as_of)) return(NULL)

  if (inherits(as_of, "POSIXt")) {
    return(format(as_of, "%Y-%m-%d %H:%M:%S"))
  }

  if (inherits(as_of, "Date")) {
    return(format(as.POSIXct(as_of), "%Y-%m-%d %H:%M:%S"))
  }

  if (is.character(as_of) && length(as_of) == 1 && nzchar(as_of)) {
    parsed <- as.POSIXct(
      as_of,
      tz = "UTC",
      tryFormats = c(
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d"
      )
    )

    if (!is.na(parsed)) {
      return(format(parsed, "%Y-%m-%d %H:%M:%S"))
    }
  }

  cli::cli_abort(
    c(
      "Invalid Silver snapshot timestamp",
      "x" = "{.arg as_of} must be NULL, Date, POSIXct, or a parseable datetime string",
      "i" = "Examples: '2026-05-21', '2026-05-21 23:59:59'"
    ),
    class = c("xpipe_silver_config", "xpipe_error")
  )
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

.is_silver_up_to_date <- function(con, stream_id, method_id, anchor_tbl, as_of = NULL) {

  anchor_full <- paste0(stream_id, "__", method_id, "__", anchor_tbl)

  bronze_anchor <- paste0(
    "bronze.main.",
    DBI::dbQuoteIdentifier(con, anchor_full)
  )

  where_sql <- if (is.null(as_of)) {
    ""
  } else {
    paste0(
      " WHERE __batch_created_at <= ",
      DBI::dbQuoteLiteral(con, as_of)
    )
  }

  latest_bronze <- .silver_query(
    con,
    paste0(
      "SELECT __batch_id AS batch_id
       FROM ", bronze_anchor,
      where_sql, "
       ORDER BY __batch_created_at DESC, __batch_id DESC
       LIMIT 1"
    )
  )

  latest_bronze <- if (nrow(latest_bronze) == 0) {
    NA_character_
  } else {
    latest_bronze$batch_id[[1]]
  }

  current_anchor <- paste0("current__", anchor_tbl)

  silver_latest <- if (current_anchor %in% DBI::dbListTables(con)) {
    out <- .silver_query(
      con,
      paste0(
        "SELECT __batch_id AS batch_id
         FROM ", DBI::dbQuoteIdentifier(con, current_anchor), "
         ORDER BY __batch_created_at DESC, __batch_id DESC
         LIMIT 1"
      )
    )

    if (nrow(out) == 0) NA_character_ else out$batch_id[[1]]
  } else {
    NA_character_
  }

  if (is.na(latest_bronze) || is.na(silver_latest)) {
    return(FALSE)
  }

  identical(latest_bronze, silver_latest)
}


# Harmonization registry --------------------------------------------------

.silver_harmonized_profile_registry <- list(
  sdo_harmonized_v1 = .silver_profile_sdo_harmonized_v1
)

.silver_profile_sdo_harmonized_v1 <- function(con, stream_id, method_id, config) {
  # Stub: WP2 wiring only
  # - no transformations yet
  # - no renaming yet
  # - must not read Bronze
  # - must read only current__*

  invisible(TRUE)
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
.promote_to_silver_current <- function(stream_id, config, as_of = NULL) {

  # 1. Preconditions

  checkmate::assert_string(stream_id)
  checkmate::assert_class(config, "xpipe_config")
  as_of <- .normalize_silver_as_of(as_of)

  method_id <- .resolve_silver_canonical_method(stream_id, config)

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
        "Invalid Silver configuration",
        "x" = "Canonical method {.val {method_id}} not found in methods contract"
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

  # 2. Open Silver and attach Bronze

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

  # 3. Discover Bronze tables

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

  # 4. Up-to-date check

  if (.is_silver_up_to_date(con_s, stream_id, method_id, anchor_tbl, as_of = as_of)) {

    if (!interactive()) {
      if (is.null(as_of)) {
        cli::cli_inform(
          "Silver-current for stream {.val {stream_id}} left unchanged (already up to date)."
        )
      } else {
        cli::cli_inform(
          "Silver-current for stream {.val {stream_id}} left unchanged (already up to date for snapshot {.val {as_of}})."
        )
      }
      return(invisible(TRUE))
    }

    answer <- readline(
      if (is.null(as_of)) {
        paste0(
          "Silver-current is already up to date for stream ",
          stream_id, ". Rebuild anyway? [y/N]: "
        )
      } else {
        paste0(
          "Silver-current is already up to date for stream ",
          stream_id, " as of ", as_of, ". Rebuild anyway? [y/N]: "
        )
      }
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

  # 5. Transactional rebuild

  anchor_where_sql <- if (is.null(as_of)) {
    ""
  } else {
    paste0(
      "WHERE a.__batch_created_at <= ",
      DBI::dbQuoteLiteral(con_s, as_of)
    )
  }

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
             ", anchor_where_sql, "
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

      if (is.null(as_of)) {
        cli::cli_alert_success(
          "Silver-current rebuilt for stream {.val {stream_id}} using method {.val {method_id}}."
        )
      } else {
        cli::cli_alert_success(
          "Silver-current rebuilt for stream {.val {stream_id}} using method {.val {method_id}} as of ingestion snapshot {.val {as_of}}."
        )
      }


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

