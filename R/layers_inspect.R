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
#' Scans the local Batch layer directory and returns a structured
#' representation of all discovered batches and their metadata.
#'
#' Incomplete batches (missing \code{_batch_metadata.json}) are recorded
#' but marked as such and excluded from detailed inspection.
#'
#' @param config An \code{xpipe_config} object.
#'
#' @return An object of class \code{xpipe_batch_layer} containing:
#' \itemize{
#'   \item \code{root} - batch layer root path
#'   \item \code{count} - number of batch directories found
#'   \item \code{batches} - named list of batch metadata
#' }
#'
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

  # Defensive: remove empty directory names
  batch_dirs <- batch_dirs[nzchar(basename(batch_dirs))]

  ids <- basename(batch_dirs)
  metadata_files <- fs::path(batch_dirs, "_batch_metadata.json")
  has_meta <- fs::file_exists(metadata_files)

  batches <- vector("list", length(ids))
  names(batches) <- ids

  for (i in seq_along(ids)) {
    if (!has_meta[i]) {
      batches[[i]] <- list(.status = "incomplete")
      next
    }

    batches[[i]] <- jsonlite::fromJSON(metadata_files[i], simplifyVector = TRUE)
  }

  structure(list(
    root    = batch_root,
    count   = length(ids),
    batches = batches
  ),
  class = "xpipe_batch_layer")
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
#'
#' @return An object of class `xpipe_silver_current_inspection`.
#' @export
inspect_silver_current <- function(
    stream_id,
    method_id,
    config = get_xpipe_config(),
    read_only = TRUE
) {
  checkmate::assert_string(stream_id)
  checkmate::assert_string(method_id)
  checkmate::assert_class(config, "xpipe_config")
  checkmate::assert_flag(read_only)

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
      silver_db = silver_db,
      tables = tables,
      current_tables = current_tables,
      anchor_table = current_anchor,
      anchor_exists = anchor_exists,
      row_counts = row_counts,
      duplicate_keys = duplicate_keys,
      orphan_checks = orphan_checks,
      batch_distribution = batch_distribution
    ),
    class = "xpipe_silver_current_inspection"
  )
}



## S3 Print Methods ----------------------------------------------------------

#' Print Method for xpipe_batch_layer
#'
#' @param x An object of class \code{xpipe_batch_layer}.
#' @param ... Additional arguments (ignored).
#' @export
print.xpipe_batch_layer <- function(x, ...) {
  cli::cli_div(theme = list(rule = list(
    color = "cyan", "line-type" = "double"
  )))

  cli::cli_rule("Batch Layer", right = "xpipe")

  cli::cli_bullets(c("Path        : {.file {x$root}}", "Batch count : {.val {x$count}}"))

  if (x$count == 0) {
    cli::cli_alert_info("No batches found.")
    return(invisible(x))
  }

  # Filter valid batches
  metas <- x$batches
  metas <- metas[!vapply(metas, function(m)
    isTRUE(m$.status == "incomplete"), logical(1))]

  if (length(metas) == 0) {
    cli::cli_alert_warning("Found {x$count} batch directories, but all are incomplete (missing metadata).")
    return(invisible(x))
  }
  created <- vapply(metas, function(m)
    as.POSIXct(m$execution$created_at, tz = "UTC"), as.POSIXct(NA))

  latest_id <- names(which.max(created))
  latest    <- metas[[latest_id]]

  # Latest batch
  cli::cli_h2("Latest Batch")
  cli::cli_text("{.strong {latest_id}}")

  cli::cli_bullets(c(
    paste0(
      "Stream       : ",
      latest$stream$id,
      " [",
      latest$stream$schema_domain,
      "]"
    ),
    paste0("Method       : ", latest$method$id, " [", latest$method$type, "]"),
    paste0("Input        : ", latest$input$path),
    paste0("Created at   : ", latest$execution$created_at),
    paste0(
      "Producer     : ",
      latest$execution$tool,
      " ",
      latest$execution$tool_version
    )
  ))

  # Components
  if (!is.null(latest$components)) {
    cli::cli_text("Components")

    items <- purrr::imap_chr(latest$components, ~ paste0(.x))

    cli::cli_ul(items)
  }

  # Other batches
  others <- metas[names(metas) != latest_id]

  if (length(others) > 0) {
    cli::cli_h2("Other batches")

    by_stream <- split(others, vapply(others, function(m)
      m$stream$id, character(1)))

    for (stream_id in names(by_stream)) {
      cli::cli_h3("{stream_id} stream")

      items <- vapply(names(by_stream[[stream_id]]), function(batch_id) {
        m <- by_stream[[stream_id]][[batch_id]]
        paste(batch_id,
              "|",
              m$method$id,
              "|",
              .format_datetime(m$execution$created_at))
      }, character(1))

      cli::cli_ul(items)
    }
  }

  cli::cli_rule()
  cli::cli_end()

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

  cli::cli_h2("Silver-current inspection")

  summary_rows <- c(
    paste0(pad("Stream", 18), ": ", x$stream_id),
    paste0(pad("Method", 18), ": ", x$method_id),
    paste0(pad("Database", 18), ": ", x$silver_db),
    paste0(pad("Anchor table", 18), ": ", x$anchor_table),
    paste0(pad("Anchor exists", 18), ": ", fmt_bool(x$anchor_exists))
  )

  cli::cat_boxx(
    summary_rows,
    header = "Summary",
    border_style = "round",
    padding = c(top = 0, right = 2, bottom = 0, left = 2),
    float = "left",
    border_col = "cyan"
  )

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

  cli::cli_h3("Sanity checks")

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
