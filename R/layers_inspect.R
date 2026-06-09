# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# layers_inspect.R
#
# Layer inspection and formatting utilities.
#
# Approach: Scans the local filesystem for Batch layer directories,
# parses metadata, and provides a structured representation for console display.
#
# Public API:  inspect_batch_layer()
# Internals:   .format_datetime(), print.xpipe_batch_layer()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

## Helpers ----------------------------------------------------------------

#' Format execution timestamps for display
#'
#' Converts ISO-8601 or SQL-style timestamps to a compact,
#' human-readable \code{YYYY-MM-DD HH:MM} format.
#'
#' @param x Character vector of datetime strings.
#' @return Character vector of formatted datetimes.
#' @keywords internal
#' @noRd
.format_datetime <- function(x) {
  format(as.POSIXct(x, tryFormats = c(
    "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%d %H:%M:%S"
  )), "%Y-%m-%d %H:%M")
}

## Public API -------------------------------------------------------------

#' Inspect the Batch layer
#'
#' @param config xpipe_config object.
#' @return xpipe_batch_layer
#' @export
inspect_batch_layer <- function(config = get_xpipe_config()) {
  if (!inherits(config, "xpipe_config")) {
    cli::cli_abort(
      "{.arg config} must be a valid {.cls xpipe_config}",
      class = c("xpipe_batch_config", "xpipe_batch_error", "xpipe_error")
    )
  }

  batch_root <- config$local$paths$batch
  if (!fs::dir_exists(batch_root)) {
    cli::cli_abort(
      "Batch layer directory does not exist: {.file {batch_root}}",
      class = c("xpipe_batch_paths", "xpipe_batch_error", "xpipe_error")
    )
  }

  batch_dirs <- fs::dir_ls(batch_root, type = "directory", recurse = FALSE)
  batch_dirs <- batch_dirs[nzchar(basename(batch_dirs))]
  ids <- basename(batch_dirs)

  meta_paths <- fs::path(batch_dirs, "_batch_metadata.json")
  has_meta <- fs::file_exists(meta_paths)

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:", read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  batches <- vector("list", length(ids))
  names(batches) <- ids

  for (i in seq_along(ids)) {
    bd <- batch_dirs[[i]]
    id <- ids[[i]]

    info <- list(
      batch_id = id,
      path = bd,
      status = "ok",
      meta = NULL,
      parquet_files = character(0),
      parquet_tables = character(0),
      parquet_stats = data.frame(),
      checks = list()
    )

    if (!has_meta[[i]]) {
      info$status <- "incomplete"
      batches[[i]] <- info
      next
    }

    meta <- rlang::try_fetch(
      jsonlite::fromJSON(meta_paths[[i]], simplifyVector = TRUE),
      error = function(e) NULL
    )

    if (is.null(meta)) {
      info$status <- "invalid_metadata"
      batches[[i]] <- info
      next
    }

    info$meta <- meta

    pq_files <- fs::dir_ls(bd, glob = "*.parquet", type = "file")
    info$parquet_files <- as.character(pq_files)
    info$parquet_tables <- fs::path_ext_remove(fs::path_file(pq_files))

    # Stats via DuckDB (no R materialization)
    if (length(pq_files) > 0) {
      stats <- lapply(seq_along(pq_files), function(j) {
        p <- as.character(pq_files[[j]])
        tbl <- info$parquet_tables[[j]]
        p_lit <- DBI::dbQuoteLiteral(con, p)

        ncols <- DBI::dbGetQuery(con, paste0("SELECT COUNT(*) AS n FROM parquet_schema(", p_lit, ")"))$n[[1]]
        nrows <- DBI::dbGetQuery(con, paste0("SELECT COUNT(*) AS n FROM read_parquet(", p_lit, ")"))$n[[1]]

        data.frame(
          table = tbl,
          ncols = as.integer(ncols),
          nrows = as.integer(nrows),
          file = p,
          stringsAsFactors = FALSE
        )
      })
      info$parquet_stats <- do.call(rbind, stats)
    } else {
      info$parquet_stats <- data.frame(
        table = character(),
        ncols = integer(),
        nrows = integer(),
        file = character(),
        stringsAsFactors = FALSE
      )
    }

    # Checks
    method_id <- meta$method$id %||% NA_character_
    method_cfg <- config$methods[[method_id]] %||% NULL
    anchor <- if (!is.null(method_cfg)) method_cfg$anchor_table %||% NA_character_ else NA_character_

    declared_tables <- meta$tables %||% character(0)
    materialized_tables <- info$parquet_tables

    info$checks$anchor_table <- anchor
    info$checks$anchor_materialized <- isTRUE(nzchar(anchor) && anchor %in% materialized_tables)

    info$checks$zero_column_parquet <- if (nrow(info$parquet_stats) > 0) {
      info$parquet_stats$table[info$parquet_stats$ncols == 0]
    } else character(0)

    info$checks$declared_not_materialized <- setdiff(declared_tables, materialized_tables)
    info$checks$materialized_not_declared <- setdiff(materialized_tables, declared_tables)

    batches[[i]] <- info
  }

  structure(
    list(
      root = batch_root,
      count = length(ids),
      batches = batches
    ),
    class = "xpipe_batch_layer"
  )
}



#' Inspect the Bronze layer (DuckDB)
#'
#' Opens the stream DuckDB file in Bronze and reports:
#' - physical tables and row counts
#' - authoritative __promotion_log history
#' - consistency checks between log and physical tables
#'
#' @param stream_id Character scalar. Stream identifier (e.g. "sdo").
#' @param config xpipe_config.
#' @param read_only Logical. Defaults to TRUE.
#'
#' @return An object of class xpipe_bronze_inspection.
#' @export
inspect_bronze <- function(stream_id = NULL, config = get_xpipe_config(), read_only = TRUE) {

  checkmate::assert_string(stream_id, null.ok = TRUE)
  checkmate::assert_class(config, "xpipe_config")
  checkmate::assert_flag(read_only)

  bronze_root <- config$local$paths$bronze
  if (!checkmate::test_string(bronze_root, min.chars = 1)) {
    cli::cli_abort(
      c("Bronze path not configured",
        "x" = "Expected config$local$paths$bronze to be set"),
      class = c("xpipe_bronze_state", "xpipe_error")
    )
  }

  if (is.null(stream_id)) {
    dbs <- fs::dir_ls(bronze_root, glob = "*.duckdb", type = "file")
    streams <- fs::path_ext_remove(fs::path_file(dbs))

    if (length(streams) == 0) {
      cli::cli_abort(
        c("No Bronze databases found",
          "x" = "No *.duckdb files found in {.file {bronze_root}}"),
        class = c("xpipe_bronze_state", "xpipe_error")
      )
    }

    choice <- NULL

    if (interactive() && requireNamespace("climenu", quietly = TRUE)) {
      choice <- tryCatch(
        climenu::select(streams, prompt = "Select Bronze stream to inspect"),
        error = function(e) NULL
      )
    }

    if (!is.null(choice)) {
      stream_id <- choice
    } else {
      # fallback: simple numbered prompt (no cli_inform)
      cat("\nSelect Bronze stream to inspect\n\n")

      for (i in seq_along(streams)) {
        cat(sprintf(" %d. %s\n", i, streams[[i]]))
      }

      cat("\n")
      k <- suppressWarnings(as.integer(readline("Enter number: ")))

      if (is.na(k) || k < 1 || k > length(streams)) {
        cli::cli_abort(
          "Invalid selection.",
          class = c("xpipe_bronze_state", "xpipe_error")
        )
      }

      stream_id <- streams[[k]]
    }

  }

  bronze_db <- fs::path(bronze_root, paste0(stream_id, ".duckdb"))
  if (!fs::file_exists(bronze_db)) {
    cli::cli_abort(
      c("Bronze database not found",
        "x" = "Expected {.file {bronze_db}} to exist"),
      class = c("xpipe_bronze_state", "xpipe_error")
    )
  }

  con <- DBI::dbConnect(
    duckdb::duckdb(),
    dbdir = as.character(bronze_db),
    read_only = read_only
  )
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  tables <- DBI::dbListTables(con)
  has_log <- "__promotion_log" %in% tables

  # data tables (exclude internal)
  data_tables <- setdiff(tables, "__promotion_log")

  # row counts (can be expensive if huge; acceptable for Bronze inspection)
  row_counts <- if (length(data_tables) > 0) {
    do.call(rbind, lapply(data_tables, function(tbl) {
      n <- DBI::dbGetQuery(
        con,
        paste0("SELECT COUNT(*) AS n FROM ", DBI::dbQuoteIdentifier(con, tbl))
      )$n[[1]]
      data.frame(table_name = tbl, n = as.numeric(n), stringsAsFactors = FALSE)
    }))
  } else {
    data.frame(table_name = character(), n = numeric(), stringsAsFactors = FALSE)
  }

  # promotion history
  promotion_log <- if (isTRUE(has_log)) {
    DBI::dbGetQuery(
      con,
      "SELECT batch_id, stream_id, method_id, promoted_at, batch_created_at, tables, tool, tool_version
       FROM __promotion_log
       ORDER BY promoted_at DESC"
    )
  } else {
    data.frame(
      batch_id = character(),
      stream_id = character(),
      method_id = character(),
      promoted_at = as.POSIXct(character()),
      batch_created_at = as.POSIXct(character()),
      tables = character(),
      tool = character(),
      tool_version = character(),
      stringsAsFactors = FALSE
    )
  }

  # parse promoted table list from JSON
  promoted_tables_from_log <- character(0)
  if (nrow(promotion_log) > 0) {
    promoted_tables_from_log <- unlist(lapply(promotion_log$tables, function(x) {
      if (is.null(x) || is.na(x) || !nzchar(x)) return(character(0))
      out <- tryCatch(jsonlite::fromJSON(x), error = function(e) NULL)
      if (is.null(out)) return(character(0))
      as.character(out)
    }))
    promoted_tables_from_log <- unique(promoted_tables_from_log)
  }

  # sanity checks
  checks <- list()
  checks$has_promotion_log <- isTRUE(has_log)
  checks$log_rows <- nrow(promotion_log)
  checks$data_tables_count <- length(data_tables)

  checks$log_tables_missing_physically <- setdiff(promoted_tables_from_log, data_tables)
  checks$physical_tables_not_in_log <- setdiff(data_tables, promoted_tables_from_log)

  # latest promotion summary
  latest <- if (nrow(promotion_log) > 0) promotion_log[1, , drop = FALSE] else promotion_log

  structure(
    list(
      stream_id = stream_id,
      bronze_db = as.character(bronze_db),
      tables = tables,
      data_tables = data_tables,
      row_counts = row_counts,
      promotion_log = promotion_log,
      latest = latest,
      promoted_tables_from_log = promoted_tables_from_log,
      checks = checks
    ),
    class = "xpipe_bronze_inspection"
  )
}



#' Inspect Silver-current tables
#'
#' Inspects the Silver DuckDB database for one stream/method pair, reporting
#' current tables, row counts, anchor uniqueness, orphan secondary rows, and
#' batch distribution in the current anchor table.
#'
#' @param stream_id Character scalar. Stream identifier.
#' @param method_id Character scalar. Method identifier.
#' @param config xpipe_config.
#' @param read_only Logical. Open Silver database read-only. Defaults to TRUE.
#' @param as_of Optional ingestion snapshot timestamp. If provided, inspection
#'   compares Silver-current against the latest Bronze anchor batch with
#'   `__batch_created_at <= as_of`. This is ingestion time, not domain/event time.
#'
#' @return An object of class `xpipe_silver_current_inspection`.
#' @export
inspect_silver_current <- function(
    stream_id = NULL,
    method_id = NULL,
    as_of = NULL,
    config = get_xpipe_config(),
    read_only = TRUE
) {

  checkmate::assert_string(stream_id, null.ok = TRUE)
  checkmate::assert_class(config, "xpipe_config")
  checkmate::assert_flag(read_only)
  as_of <- .normalize_silver_as_of(as_of)

  if (is.null(stream_id)) {
    streams <- names(config$silver)

    if (length(streams) == 0) {
      cli::cli_abort(
        "No Silver streams configured",
        class = c("xpipe_silver_state", "xpipe_error")
      )
    }

    choice <- NULL
    if (interactive() && requireNamespace("climenu", quietly = TRUE)) {
      choice <- tryCatch(
        climenu::select(streams, prompt = "Select Silver stream to inspect"),
        error = function(e) NULL
      )
    }

    if (!is.null(choice)) {
      stream_id <- choice
    } else {
      cat("\nSelect Silver stream to inspect\n\n")
      for (i in seq_along(streams)) {
        cat(sprintf(" %d. %s\n", i, streams[[i]]))
      }
      cat("\n")
      k <- suppressWarnings(as.integer(readline("Enter number: ")))
      if (is.na(k) || k < 1 || k > length(streams)) {
        cli::cli_abort(
          "Invalid selection.",
          class = c("xpipe_silver_state", "xpipe_error")
        )
      }
      stream_id <- streams[[k]]
    }
  }

  silver_cfg <- config$silver[[stream_id]]
  if (is.null(silver_cfg)) {
    cli::cli_abort(
      c(
        "Silver not configured for stream",
        "x" = "Stream {.val {stream_id}} not found in silver.json"
      ),
      class = c("xpipe_silver_state", "xpipe_error")
    )
  }

  if (!isTRUE(silver_cfg$current$enabled)) {
    cli::cli_abort(
      c(
        "Silver-current disabled",
        "x" = "Silver-current is disabled for stream {.val {stream_id}}"
      ),
      class = c("xpipe_silver_state", "xpipe_error")
    )
  }

  canonical_method <- silver_cfg$canonical_method
  method_id <- method_id %||% canonical_method
  checkmate::assert_string(method_id)

  silver_root <- config$local$paths$silver
  if (!checkmate::test_string(silver_root, min.chars = 1)) {
    cli::cli_abort(
      c(
        "Silver path not configured",
        "x" = "Expected config$local$paths$silver to be set"
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

  silver_db <- fs::path(silver_root, paste0(stream_id, ".duckdb"))
  if (!fs::file_exists(silver_db)) {
    cli::cli_abort(
      c(
        "Silver database not found",
        "x" = "Expected {.file {silver_db}} to exist"
      ),
      class = c("xpipe_silver_state", "xpipe_error")
    )
  }

  con <- DBI::dbConnect(
    duckdb::duckdb(),
    dbdir = as.character(silver_db),
    read_only = read_only
  )
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  # Silver vs Bronze currency check

  latest_bronze_batch <- NA_character_
  latest_silver_batch <- NA_character_

  current_anchor <- paste0("current__", anchor_tbl)

  bronze_db <- fs::path(config$local$paths$bronze, paste0(stream_id, ".duckdb"))

  if (fs::file_exists(bronze_db)) {
    try({
      try(DBI::dbExecute(con, "DETACH bronze"), silent = TRUE)

      DBI::dbExecute(
        con,
        paste0(
          "ATTACH ",
          DBI::dbQuoteLiteral(con, as.character(bronze_db)),
          " AS bronze (READ_ONLY)"
        )
      )

      on.exit(try(DBI::dbExecute(con, "DETACH bronze"), silent = TRUE), add = TRUE)

      anchor_full <- paste0(stream_id, "__", method_id, "__", anchor_tbl)

      bronze_tables <- DBI::dbGetQuery(
        con,
        "SELECT table_name
       FROM duckdb_tables()
       WHERE database_name = 'bronze'
         AND schema_name = 'main'"
      )$table_name

      if (anchor_full %in% bronze_tables) {
        where_sql <- if (is.null(as_of)) {
          ""
        } else {
          paste0(
            " WHERE __batch_created_at <= ",
            DBI::dbQuoteLiteral(con, as_of)
          )
        }

        latest_bronze <- DBI::dbGetQuery(
          con,
          paste0(
            "SELECT __batch_id AS batch_id
           FROM bronze.main.", DBI::dbQuoteIdentifier(con, anchor_full),
            where_sql, "
           ORDER BY __batch_created_at DESC, __batch_id DESC
           LIMIT 1"
          )
        )

        latest_bronze_batch <- if (nrow(latest_bronze) == 0) {
          NA_character_
        } else {
          latest_bronze$batch_id[[1]]
        }
      }
    }, silent = TRUE)
  }

  if (current_anchor %in% DBI::dbListTables(con)) {
    latest_silver <- DBI::dbGetQuery(
      con,
      paste0(
        "SELECT __batch_id AS batch_id
       FROM ", DBI::dbQuoteIdentifier(con, current_anchor), "
       ORDER BY __batch_created_at DESC, __batch_id DESC
       LIMIT 1"
      )
    )

    latest_silver_batch <- if (nrow(latest_silver) == 0) {
      NA_character_
    } else {
      latest_silver$batch_id[[1]]
    }
  }

  silver_status <- if (is.na(latest_bronze_batch)) {
    "UNKNOWN"
  } else if (is.na(latest_silver_batch)) {
    "STALE"
  } else if (identical(latest_bronze_batch, latest_silver_batch)) {
    "UP TO DATE"
  } else {
    "STALE"
  }

  tables <- DBI::dbListTables(con)
  current_tables <- tables[startsWith(tables, "current__")]

  row_counts <- lapply(current_tables, function(tab) {
    sql <- paste0(
      "SELECT ",
      DBI::dbQuoteLiteral(con, tab),
      " AS table_name, COUNT(*) AS n FROM ",
      DBI::dbQuoteIdentifier(con, tab)
    )
    DBI::dbGetQuery(con, sql)
  })

  row_counts <- if (length(row_counts) > 0) {
    do.call(rbind, row_counts)
  } else {
    data.frame(table_name = character(), n = integer())
  }

  current_anchor <- paste0("current__", anchor_tbl)
  anchor_exists <- current_anchor %in% current_tables

  duplicate_keys <- data.frame()
  batch_distribution <- data.frame()
  orphan_checks <- list()

  if (isTRUE(anchor_exists)) {
    anchor_fields <- DBI::dbListFields(con, current_anchor)
    missing_anchor_keys <- setdiff(keys, anchor_fields)

    if (length(missing_anchor_keys) > 0) {
      cli::cli_abort(
        c(
          "Invalid Silver anchor table",
          "x" = "Missing identity key(s): {.val {missing_anchor_keys}}"
        ),
        class = c("xpipe_silver_anchor", "xpipe_error")
      )
    }

    keys_sql <- paste(DBI::dbQuoteIdentifier(con, keys), collapse = ", ")

    duplicate_keys <- DBI::dbGetQuery(
      con,
      paste0(
        "SELECT ", keys_sql, ", COUNT(*) AS n
         FROM ", DBI::dbQuoteIdentifier(con, current_anchor), "
         GROUP BY ", keys_sql, "
         HAVING COUNT(*) > 1
         LIMIT 50"
      )
    )

    batch_distribution <- DBI::dbGetQuery(
      con,
      paste0(
        "SELECT
           __batch_id,
           __batch_created_at,
           COUNT(*) AS n
         FROM ", DBI::dbQuoteIdentifier(con, current_anchor), "
         GROUP BY __batch_id, __batch_created_at
         ORDER BY __batch_created_at DESC, __batch_id DESC"
      )
    )

    secondary_tables <- setdiff(current_tables, current_anchor)

    for (tab in secondary_tables) {
      sec_fields <- DBI::dbListFields(con, tab)
      needed <- c(keys, "__batch_id")

      if (!all(needed %in% sec_fields)) {
        orphan_checks[[tab]] <- data.frame(
          table_name = tab,
          checked = FALSE,
          orphan_rows = NA_integer_,
          reason = "missing identity key(s) or __batch_id"
        )
        next
      }

      join_keys <- paste(
        paste0(
          "s.", DBI::dbQuoteIdentifier(con, keys),
          " = a.", DBI::dbQuoteIdentifier(con, keys)
        ),
        collapse = " AND "
      )

      sql <- paste0(
        "SELECT
           ", DBI::dbQuoteLiteral(con, tab), " AS table_name,
           TRUE AS checked,
           COUNT(*) AS orphan_rows,
           CAST(NULL AS VARCHAR) AS reason
         FROM ", DBI::dbQuoteIdentifier(con, tab), " s
         LEFT JOIN ", DBI::dbQuoteIdentifier(con, current_anchor), " a
           ON ", join_keys, "
          AND s.__batch_id = a.__batch_id
         WHERE a.__batch_id IS NULL"
      )

      orphan_checks[[tab]] <- DBI::dbGetQuery(con, sql)
    }
  }

  orphan_checks <- if (length(orphan_checks) > 0) {
    do.call(rbind, orphan_checks)
  } else {
    data.frame(
      table_name = character(),
      checked = logical(),
      orphan_rows = integer(),
      reason = character()
    )
  }

  structure(
    list(
      stream_id = stream_id,
      method_id = method_id,
      canonical_method = canonical_method,
      silver_db = silver_db,
      tables = tables,
      current_tables = current_tables,
      anchor_table = current_anchor,
      anchor_exists = anchor_exists,
      row_counts = row_counts,
      duplicate_keys = duplicate_keys,
      orphan_checks = orphan_checks,
      batch_distribution = batch_distribution,
      latest_bronze_batch = latest_bronze_batch,
      latest_silver_batch = latest_silver_batch,
      silver_status = silver_status,
      as_of = as_of
    ),
    class = "xpipe_silver_current_inspection"
  )
}

#' Inspect Silver alignment between current and harmonized
#'
#' Determines whether Silver-harmonized is aligned with Silver-current
#' based exclusively on __silver_log metadata.
#'
#' @param stream_id Stream identifier.
#' @param config xpipe_config object.
#'
#' @return A list with current, harmonized and alignment status.
#' @export
inspect_silver_alignment <- function(stream_id, config = get_xpipe_config()) {
  checkmate::assert_string(stream_id)
  checkmate::assert_class(config, "xpipe_config")

  silver_db <- fs::path(config$local$paths$silver, paste0(stream_id, ".duckdb"))
  if (!fs::file_exists(silver_db)) {
    cli::cli_abort(
      c(
        "Silver database not found",
        "x" = "Expected {.file {silver_db}} to exist"
      ),
      class = c("xpipe_silver_state", "xpipe_error")
    )
  }

  con <- DBI::dbConnect(
    duckdb::duckdb(),
    dbdir = as.character(silver_db),
    read_only = TRUE
  )
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  if (!("__silver_log" %in% DBI::dbGetQuery(con, "SHOW TABLES")$name)) {
    return(list(
      status = "UNKNOWN",
      reason = "__silver_log not found"
    ))
  }

  log <- DBI::dbGetQuery(
    con,
    "
    SELECT phase, as_of, built_at
    FROM __silver_log
    WHERE stream_id = ?
    ORDER BY built_at DESC
    ",
    params = list(stream_id)
  )

  current <- log[log$phase == "current", , drop = FALSE]
  harmonized <- log[log$phase == "harmonized", , drop = FALSE]

  if (nrow(current) == 0 || nrow(harmonized) == 0) {
    return(list(
      status = "UNKNOWN",
      current = if (nrow(current)) current[1, ] else NULL,
      harmonized = if (nrow(harmonized)) harmonized[1, ] else NULL
    ))
  }

  current_latest <- current[1, ]
  harmonized_latest <- harmonized[1, ]

  aligned <- (
    harmonized_latest$built_at >= current_latest$built_at &&
      identical(harmonized_latest$as_of, current_latest$as_of)
  )

  list(
    status = if (aligned) "ALIGNED" else "STALE",
    current = current_latest,
    harmonized = harmonized_latest
  )
}

## S3 Print Methods ----------------------------------------------------------

#' Print Method for xpipe_batch_layer
#'
#' @export
print.xpipe_batch_layer <- function(x, ...) {
  pad <- function(x, width) {
    x <- as.character(x)
    paste0(x, strrep(" ", pmax(0, width - nchar(x))))
  }

  fmt_bool <- function(v) {
    if (isTRUE(v)) "YES" else "NO"
  }

  head_tail <- function(v, n = 12) {
    v <- as.character(v)
    if (length(v) <= n) return(v)
    c(v[seq_len(n)], paste0("… +", length(v) - n, " more"))
  }

  box_list <- function(v, header, border_col = "cyan") {
    if (length(v) == 0) v <- "None"
    cli::cat_boxx(
      head_tail(v),
      header = header,
      border_style = "round",
      padding = c(top = 0, right = 2, bottom = 0, left = 2),
      float = "left",
      border_col = border_col
    )
  }

  box_table <- function(df, header, border_col = "cyan", max_rows = 20) {
    if (is.null(df) || !is.data.frame(df) || nrow(df) == 0) {
      return(cli::cat_boxx(
        "None",
        header = header,
        border_style = "round",
        padding = c(top = 0, right = 2, bottom = 0, left = 2),
        float = "left",
        border_col = border_col
      ))
    }

    df2 <- df
    if (nrow(df2) > max_rows) df2 <- df2[seq_len(max_rows), , drop = FALSE]

    cols <- names(df2)
    widths <- vapply(cols, function(cn) {
      max(nchar(cn), max(nchar(as.character(df2[[cn]])), na.rm = TRUE))
    }, numeric(1))

    header_row <- paste(pad(cols, widths), collapse = "  ")
    sep_row <- paste(vapply(widths, function(w) strrep("-", w), character(1)), collapse = "  ")

    body <- vapply(seq_len(nrow(df2)), function(i) {
      paste(pad(df2[i, cols, drop = FALSE], widths), collapse = "  ")
    }, character(1))

    lines <- c(header_row, sep_row, body)
    if (nrow(df) > max_rows) {
      lines <- c(lines, paste0("… +", nrow(df) - max_rows, " more"))
    }

    cli::cat_boxx(
      lines,
      header = header,
      border_style = "round",
      padding = c(top = 0, right = 2, bottom = 0, left = 2),
      float = "left",
      border_col = border_col
    )
  }

  cli::cli_h2("Batch layer inspection")

  # Summary counts (supports both old/new shapes)
  batches <- x$batches %||% list()
  ids <- names(batches)

  status_of <- function(b) {
    if (!is.null(b$status)) return(as.character(b$status))
    if (!is.null(b$.status)) return(as.character(b$.status))
    if (is.list(b) && !is.null(b$batch_id)) return("ok")
    "unknown"
  }

  statuses <- vapply(batches, status_of, character(1))
  tab <- sort(table(statuses), decreasing = TRUE)

  summary_rows <- c(
    paste0(pad("Path", 18), ": ", x$root),
    paste0(pad("Batches", 18), ": ", x$count)
  )
  if (length(tab) > 0) {
    for (nm in names(tab)) {
      summary_rows <- c(summary_rows, paste0(pad(paste0("Status ", nm), 18), ": ", tab[[nm]]))
    }
  }

  cli::cat_boxx(
    summary_rows,
    header = "Batch Layer Summary",
    border_style = "round",
    padding = c(top = 0, right = 2, bottom = 0, left = 2),
    float = "left",
    border_col = "cyan"
  )

  if (length(ids) == 0) return(invisible(x))

  cli::cli_h3("Latest batch details")

  # Determine latest batch by metadata execution.created_at when available
  created <- vapply(batches, function(b) {
    m <- b$meta %||% b
    ts <- m$execution$created_at %||% NA_character_
    if (!is.character(ts) || !nzchar(ts)) return(as.POSIXct(NA))
    as.POSIXct(ts, tz = "UTC", tryFormats = c("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%d %H:%M:%S"))
  }, as.POSIXct(NA))

  latest_id <- if (all(is.na(created))) ids[[1]] else names(which.max(created))
  b <- batches[[latest_id]]
  m <- b$meta %||% b

  method_id <- m$method$id %||% NA_character_
  stream_id <- m$stream$id %||% NA_character_
  created_at <- m$execution$created_at %||% NA_character_

  latest_rows <- c(
    paste0(pad("Batch", 18), ": ", latest_id),
    paste0(pad("Status", 18), ": ", status_of(b)),
    paste0(pad("Stream", 18), ": ", stream_id),
    paste0(pad("Method", 18), ": ", method_id),
    paste0(pad("Created at", 18), ": ", created_at)
  )

  # Extra info if new inspect is used
  if (!is.null(b$parquet_tables)) {
    latest_rows <- c(latest_rows, paste0(pad("Parquet tables", 18), ": ", length(b$parquet_tables)))
  }

  cli::cat_boxx(
    latest_rows,
    header = "Info",
    border_style = "round",
    padding = c(top = 0, right = 2, bottom = 0, left = 2),
    float = "left",
    border_col = "cyan"
  )

  # Show parquet stats if available
  if (!is.null(b$parquet_stats) && is.data.frame(b$parquet_stats)) {
    df <- b$parquet_stats
    keep <- intersect(c("table", "ncols", "nrows"), names(df))
    df <- df[, keep, drop = FALSE]
    box_table(df, header = "Parquet stats", border_col = "cyan", max_rows = 25)
  } else {
    # fallback: show declared tables from metadata if available
    declared <- m$tables %||% character(0)
    box_list(declared, header = "Declared tables (metadata)", border_col = "cyan")
  }

  # Checks (if available)
  if (!is.null(b$checks) && is.list(b$checks)) {
    checks <- b$checks
    anchor <- checks$anchor_table %||% NA_character_
    anchor_ok <- checks$anchor_materialized %||% FALSE
    zero_cols <- checks$zero_column_parquet %||% character(0)
    decl_not_mat <- checks$declared_not_materialized %||% character(0)
    mat_not_decl <- checks$materialized_not_declared %||% character(0)

    sanity_rows <- c(
      paste0(pad("Anchor", 18), ": ", anchor),
      paste0(pad("Anchor ok", 18), ": ", fmt_bool(anchor_ok))
    )


    # build sanity check table
    sanity_df <- data.frame(
      check = c(
        "Anchor table",
        "Zero-column parquet",
        "Declared not materialized",
        "Materialized not declared"
      ),
      result = c(
        if (isTRUE(anchor_ok)) "OK" else "FAIL",
        if (length(zero_cols) == 0) "OK" else "FAIL",
        if (length(decl_not_mat) == 0) "OK" else "WARN",
        if (length(mat_not_decl) == 0) "OK" else "WARN"
      ),
      detail = c(
        anchor %||% "",
        if (length(zero_cols) == 0) "none" else paste(zero_cols, collapse = ", "),
        if (length(decl_not_mat) == 0) "none" else paste(decl_not_mat, collapse = ", "),
        if (length(mat_not_decl) == 0) "none" else paste(mat_not_decl, collapse = ", ")
      ),
      stringsAsFactors = FALSE
    )

    # column widths
    max_check  <- max(nchar(sanity_df$check),  nchar("check"))
    max_result <- max(nchar(sanity_df$result), nchar("result"))
    max_detail <- max(nchar(sanity_df$detail), nchar("detail"))

    sanity_rows <- c(
      paste0(
        pad("check",  max_check),  "  ",
        pad("result", max_result), "  ",
        pad("detail", max_detail)
      ),
      paste0(
        strrep("-", max_check),  "  ",
        strrep("-", max_result), "  ",
        strrep("-", max_detail)
      ),
      vapply(seq_len(nrow(sanity_df)), function(i) {
        paste0(
          pad(sanity_df$check[[i]],  max_check),  "  ",
          pad(sanity_df$result[[i]], max_result), "  ",
          pad(sanity_df$detail[[i]], max_detail)
        )
      }, character(1))
    )

    # overall color: red if any FAIL, yellow if any WARN, else green
    border_col <- if (any(sanity_df$result == "FAIL")) {
      "red"
    } else if (any(sanity_df$result == "WARN")) {
      "yellow"
    } else {
      "green"
    }

    cli::cat_boxx(
      sanity_rows,
      header = "Sanity checks",
      border_style = "round",
      padding = c(top = 0, right = 2, bottom = 0, left = 2),
      float = "left",
      border_col = border_col
    )

  }

  cli::cli_h3("More info")

  # build summary rows for all batches (excluding latest)

  other_ids <- setdiff(names(batches), latest_id)

  other_ids <- other_ids[order(
    vapply(other_ids, function(id) {
      b <- batches[[id]]
      m <- b$meta %||% b
      ts <- m$execution$created_at %||% NA_character_
      as.POSIXct(
        ts,
        tz = "UTC",
        tryFormats = c("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%d %H:%M:%S")
      )
    }, as.POSIXct(NA)),
    decreasing = TRUE
  )]

  if (length(other_ids) == 0) {
    cli::cat_boxx(
      "No older batches.",
      header = "Batch history (latest first)",
      border_style = "round",
      padding = c(top = 0, right = 2, bottom = 0, left = 2),
      float = "left",
      border_col = "cyan"
    )
  } else {

    rows <- lapply(other_ids, function(id) {
      b <- batches[[id]]
      m <- b$meta %||% b

      stream_id <- m$stream$id %||% ""
      method_id <- m$method$id %||% ""
      created_at <- m$execution$created_at %||% ""

      # human-friendly datetime
      created_at <- tryCatch(
        format(
          as.POSIXct(created_at, tz = "UTC",
                     tryFormats = c("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%d %H:%M:%S")),
          "%Y-%m-%d %H:%M"
        ),
        error = function(e) created_at
      )

      n_tables <- length(b$parquet_tables %||% character(0))

      # derive generic sanity
      chk <- b$checks %||% list()
      sanity <- "OK"

      if (isFALSE(chk$anchor_materialized) ||
          length(chk$zero_column_parquet %||% character(0)) > 0) {
        sanity <- "FAIL"
      } else if (length(chk$declared_not_materialized %||% character(0)) > 0 ||
                 length(chk$materialized_not_declared %||% character(0)) > 0) {
        sanity <- "WARN"
      }

      c(
        batch_id = id,
        stream   = stream_id,
        method   = method_id,
        created  = created_at,
        tables   = as.character(n_tables),
        sanity   = sanity
      )
    })

    df <- as.data.frame(do.call(rbind, rows), stringsAsFactors = FALSE)

    # column widths
    widths <- vapply(names(df), function(nm) {
      max(nchar(nm), max(nchar(df[[nm]]), na.rm = TRUE))
    }, numeric(1))

    table_rows <- c(
      paste(pad(names(df), widths), collapse = "  "),
      paste(vapply(widths, function(w) strrep("-", w), character(1)), collapse = "  "),
      vapply(seq_len(nrow(df)), function(i) {
        paste(pad(df[i, ], widths), collapse = "  ")
      }, character(1))
    )

    border_col <- if ("FAIL" %in% df$sanity) {
      "red"
    } else if ("WARN" %in% df$sanity) {
      "yellow"
    } else {
      "green"
    }

    cli::cat_boxx(
      table_rows,
      header = "Batch history (latest first)",
      border_style = "round",
      padding = c(top = 0, right = 2, bottom = 0, left = 2),
      float = "left",
      border_col = border_col
    )
  }

  invisible(x)
}

#' Print Method for xpipe_bronze_inspection
#'
#' @export
print.xpipe_bronze_inspection <- function(x, ...) {
  pad <- function(x, width) {
    x <- as.character(x)
    paste0(x, strrep(" ", pmax(0, width - nchar(x))))
  }

  fmt_bool <- function(v) if (isTRUE(v)) "YES" else "NO"

  head_tail <- function(v, n = 12) {
    v <- as.character(v)
    if (length(v) <= n) return(v)
    c(v[seq_len(n)], paste0("… +", length(v) - n, " more"))
  }

  cli::cli_h2("Bronze stream inspection")

  summary_rows <- c(
    paste0(pad("Stream", 18), ": ", x$stream_id),
    paste0(pad("Database", 18), ": ", x$bronze_db),
    paste0(pad("Tables", 18), ": ", length(x$tables)),
    paste0(pad("Data tables", 18), ": ", length(x$data_tables)),
    paste0(pad("Has promotion log", 18), ": ", fmt_bool(x$checks$has_promotion_log)),
    paste0(pad("Log rows", 18), ": ", x$checks$log_rows)
  )

  cli::cat_boxx(
    summary_rows,
    header = "Bronze Summary",
    border_style = "round",
    padding = c(top = 0, right = 2, bottom = 0, left = 2),
    float = "left",
    border_col = "cyan"
  )

  # Sanity checks table
  missing_phys <- x$checks$log_tables_missing_physically %||% character(0)
  extra_phys <- x$checks$physical_tables_not_in_log %||% character(0)

  sanity_df <- data.frame(
    check = c(
      "Promotion log present",
      "Log tables missing physically",
      "Physical tables not in log"
    ),
    result = c(
      if (isTRUE(x$checks$has_promotion_log)) "OK" else "FAIL",
      if (length(missing_phys) == 0) "OK" else "FAIL",
      if (length(extra_phys) == 0) "OK" else "WARN"
    ),
    detail = c(
      if (isTRUE(x$checks$has_promotion_log)) "__promotion_log" else "missing",
      if (length(missing_phys) == 0) "none" else paste(head_tail(missing_phys), collapse = ", "),
      if (length(extra_phys) == 0) "none" else paste(head_tail(extra_phys), collapse = ", ")
    ),
    stringsAsFactors = FALSE
  )

  max_check  <- max(nchar(sanity_df$check),  nchar("check"))
  max_result <- max(nchar(sanity_df$result), nchar("result"))
  max_detail <- max(nchar(sanity_df$detail), nchar("detail"))

  sanity_rows <- c(
    paste0(pad("check",  max_check),  "  ",
           pad("result", max_result), "  ",
           pad("detail", max_detail)),
    paste0(strrep("-", max_check), "  ",
           strrep("-", max_result), "  ",
           strrep("-", max_detail)),
    vapply(seq_len(nrow(sanity_df)), function(i) {
      paste0(pad(sanity_df$check[[i]],  max_check),  "  ",
             pad(sanity_df$result[[i]], max_result), "  ",
             pad(sanity_df$detail[[i]], max_detail))
    }, character(1))
  )

  border_col <- if (any(sanity_df$result == "FAIL")) "red" else if (any(sanity_df$result == "WARN")) "yellow" else "green"

  cli::cat_boxx(
    sanity_rows,
    header = "Bronze sanity checks",
    border_style = "round",
    padding = c(top = 0, right = 2, bottom = 0, left = 2),
    float = "left",
    border_col = border_col
  )

  # Current tables row counts (top N)
  if (nrow(x$row_counts) > 0) {
    df <- x$row_counts[order(-x$row_counts$n), , drop = FALSE]
    df <- head(df, 20)

    max_t <- max(nchar(df$table_name), nchar("table"))
    max_n <- max(nchar(as.character(df$n)), nchar("rows"))

    rows <- c(
      paste0(pad("table", max_t), "  ", pad("rows", max_n)),
      paste0(strrep("-", max_t), "  ", strrep("-", max_n)),
      vapply(seq_len(nrow(df)), function(i) {
        paste0(pad(df$table_name[[i]], max_t), "  ", pad(df$n[[i]], max_n))
      }, character(1))
    )

    cli::cli_h3("More info")
    cli::cat_boxx(
      rows,
      header = "Top tables by rows",
      border_style = "round",
      padding = c(top = 0, right = 2, bottom = 0, left = 2),
      float = "left",
      border_col = "cyan"
    )
  }

  # Promotion history (other batches)
  if (nrow(x$promotion_log) > 1) {
    df <- x$promotion_log
    df$promoted_at <- as.character(df$promoted_at)
    df$batch_created_at <- as.character(df$batch_created_at)

    df2 <- df[, c("batch_id", "method_id", "batch_created_at", "promoted_at"), drop = FALSE]
    if (nrow(df2) > 20) df2 <- df2[seq_len(20), , drop = FALSE]

    widths <- vapply(names(df2), function(nm) {
      max(nchar(nm), max(nchar(df2[[nm]]), na.rm = TRUE))
    }, numeric(1))

    lines <- c(
      paste(pad(names(df2), widths), collapse = "  "),
      paste(vapply(widths, function(w) strrep("-", w), character(1)), collapse = "  "),
      vapply(seq_len(nrow(df2)), function(i) {
        paste(pad(df2[i, ], widths), collapse = "  ")
      }, character(1))
    )

    cli::cat_boxx(
      lines,
      header = "Promotion history (latest first)",
      border_style = "round",
      padding = c(top = 0, right = 2, bottom = 0, left = 2),
      float = "left",
      border_col = "cyan"
    )
  }

  invisible(x)
}



#' Print Silver-current inspection
#'
#' @param x An object returned by `inspect_silver_current()`.
#' @param ... Ignored.
#'
#' @return Invisibly returns `x`.
#' @export
#' Print Silver-current inspection
#'
#' @param x An object returned by `inspect_silver_current()`.
#' @param ... Ignored.
#'
#' @return Invisibly returns `x`.
#' @export
print.xpipe_silver_current_inspection <- function(x, ...) {
  pad <- function(x, width) {
    x <- as.character(x)
    paste0(x, strrep(" ", pmax(0, width - nchar(x))))
  }

  fmt_bool <- function(x) {
    if (isTRUE(x)) "YES" else "NO"
  }

  cli::cli_h2("Silver-current stream / method inspection")

  summary_rows <- c(
    paste0(pad("Stream", 18), ": ", x$stream_id),
    paste0(pad("Method", 18), ": ", x$method_id),
    paste0(pad("Method (canonical)", 18), ": ", x$canonical_method),
    paste0(pad("Database", 18), ": ", x$silver_db),
    paste0(pad("Anchor table", 18), ": ", x$anchor_table),
    paste0(pad("Anchor exists", 18), ": ", fmt_bool(x$anchor_exists)),
    paste0(pad("---", 18)),
    paste0(pad("Snapshot as_of", 18), ": ", if (is.null(x$as_of)) "latest" else x$as_of),
    paste0(pad("Eligible Bronze", 18), ": ", x$latest_bronze_batch %||% "NA"),
    paste0(pad("Silver batch", 18), ": ", x$latest_silver_batch %||% "NA"),
    paste0(pad("Silver status", 18), ": ", x$silver_status)
  )

  cli::cat_boxx(
    summary_rows,
    header = "Silver stream / method Summary",
    border_style = "round",
    padding = c(top = 0, right = 2, bottom = 0, left = 2),
    float = "left",
    border_col =
      if (x$silver_status == "UP TO DATE") "cyan"
    else if (x$silver_status == "STALE") "yellow"
    else "red"
  )

  # Sanity checks
  uniqueness_rows <- if (!isTRUE(x$anchor_exists)) {
    "Anchor table is missing."
  } else if (nrow(x$duplicate_keys) == 0) {
    "OK - no duplicate anchor keys."
  } else {
    c(
      "FAIL - duplicate anchor keys found.",
      utils::capture.output(print(x$duplicate_keys, row.names = FALSE))
    )
  }


  cli::cat_boxx(
    uniqueness_rows,
    header = "Anchor uniqueness",
    border_style = "round",
    padding = c(top = 0, right = 2, bottom = 0, left = 2),
    float = "left",
    border_col = if (nrow(x$duplicate_keys) == 0 && isTRUE(x$anchor_exists)) "green" else "red"
  )

  if (nrow(x$orphan_checks) > 0) {
    orphan_df <- x$orphan_checks

    orphan_df$checked <- ifelse(orphan_df$checked, "YES", "NO")
    orphan_df$reason[is.na(orphan_df$reason)] <- ""

    max_table <- max(nchar(orphan_df$table_name), nchar("table"))
    max_checked <- max(nchar(orphan_df$checked), nchar("checked"))
    max_orphans <- max(nchar(as.character(orphan_df$orphan_rows)), nchar("orphans"))
    max_reason <- max(nchar(orphan_df$reason), nchar("reason"))

    orphan_rows <- c(
      paste0(
        pad("table", max_table), "  ",
        pad("checked", max_checked), "  ",
        pad("orphans", max_orphans), "  ",
        pad("reason", max_reason)
      ),
      paste0(
        strrep("-", max_table), "  ",
        strrep("-", max_checked), "  ",
        strrep("-", max_orphans), "  ",
        strrep("-", max_reason)
      ),
      vapply(seq_len(nrow(orphan_df)), function(i) {
        paste0(
          pad(orphan_df$table_name[[i]], max_table), "  ",
          pad(orphan_df$checked[[i]], max_checked), "  ",
          pad(orphan_df$orphan_rows[[i]], max_orphans), "  ",
          pad(orphan_df$reason[[i]], max_reason)
        )
      }, character(1))
    )

    orphan_bad <- any(orphan_df$orphan_rows > 0, na.rm = TRUE)
  } else {
    orphan_rows <- "No secondary tables checked."
    orphan_bad <- FALSE
  }

  cli::cat_boxx(
    orphan_rows,
    header = "Secondary orphan checks",
    border_style = "round",
    padding = c(top = 0, right = 2, bottom = 0, left = 2),
    float = "left",
    border_col = if (isTRUE(orphan_bad)) "red" else "green"
  )

  cli::cli_h3("More info")

  # Current tables row counts
  if (nrow(x$row_counts) > 0) {
    max_name <- max(nchar(x$row_counts$table_name), nchar("table"))
    max_n <- max(nchar(as.character(x$row_counts$n)), nchar("rows"))

    table_rows <- c(
      paste0(pad("table", max_name), "  ", pad("rows", max_n)),
      paste0(strrep("-", max_name), "  ", strrep("-", max_n)),
      vapply(seq_len(nrow(x$row_counts)), function(i) {
        paste0(
          pad(x$row_counts$table_name[[i]], max_name),
          "  ",
          pad(x$row_counts$n[[i]], max_n)
        )
      }, character(1))
    )
  } else {
    table_rows <- "No current__ tables found."
  }

  cli::cat_boxx(
    table_rows,
    header = "Current tables",
    border_style = "round",
    padding = c(top = 0, right = 2, bottom = 0, left = 2),
    float = "left",
    border_col = "cyan"
  )

  # Batch distribution in anchor table
  if (nrow(x$batch_distribution) > 0) {
    bd <- x$batch_distribution

    max_batch <- max(nchar(bd$`__batch_id`), nchar("batch_id"))
    max_created <- max(nchar(as.character(bd$`__batch_created_at`)), nchar("created_at"))
    max_n <- max(nchar(as.character(bd$n)), nchar("rows"))

    batch_rows <- c(
      paste0(
        pad("batch_id", max_batch), "  ",
        pad("created_at", max_created), "  ",
        pad("rows", max_n)
      ),
      paste0(
        strrep("-", max_batch), "  ",
        strrep("-", max_created), "  ",
        strrep("-", max_n)
      ),
      vapply(seq_len(nrow(bd)), function(i) {
        paste0(
          pad(bd$`__batch_id`[[i]], max_batch), "  ",
          pad(as.character(bd$`__batch_created_at`[[i]]), max_created), "  ",
          pad(bd$n[[i]], max_n)
        )
      }, character(1))
    )
  } else {
    batch_rows <- "No batch distribution available."
  }

  cli::cat_boxx(
    batch_rows,
    header = "Current anchor batch distribution",
    border_style = "round",
    padding = c(top = 0, right = 2, bottom = 0, left = 2),
    float = "left",
    border_col = "cyan"
  )

  invisible(x)
}
