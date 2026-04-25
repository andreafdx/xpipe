box::use(
  jsonlite,
  fs,
  cli,
  duckdb,
  DBI,
  purrr[imap_chr]
)


# Bronze promotion pipeline -----------------------------------------------



## Helpers -----------------------------------------------------------------


#' Get Bronze State
#'
#' Reads the state of the Bronze layer from `layer.json`.
#'
#' @param config xacc_config object.
#' @return A list with the current state.
#' @noRd
.get_bronze_state <- function(config) {
  path <- fs::path(config$local$paths$bronze, "layer.json")

  if (!fs::file_exists(path)) {
    cli$cli_abort(
      c(
        "Bronze layer state not found",
        "x" = "File {.file {path}} does not exist"
      ),
      class = c("bronze_state", "file_not_found")
    )
  }

  tryCatch(
    jsonlite$fromJSON(path, simplifyVector = TRUE),
    error = function(e) {
      cli$cli_abort(
        c(
          "Failed to read Bronze layer state",
          "x" = "Invalid JSON syntax in {.file {path}}",
          "!" = e$message
        ),
        class = c("bronze_state", "json_error")
      )
    }
  )
}

#' Save Bronze State
#'
#' Writes the updated state of the Bronze layer back to `layer.json`.
#'
#' @param config xacc_config object.
#' @param state A list representing the updated state.
#' @noRd
.save_bronze_state <- function(config, state) {
  path <- fs::path(config$local$paths$bronze, "layer.json")

  tryCatch(
    {
      json_content <- jsonlite$toJSON(state, auto_unbox = TRUE, pretty = TRUE)
      writeLines(as.character(json_content), path)
    },
    error = function(e) {
      cli$cli_abort(
        c(
          "Failed to save Bronze layer state",
          "x" = "Could not write to {.file {path}}",
          "!" = e$message
        ),
        class = c("bronze_state", "write_error")
      )
    }
  )

  invisible(TRUE)
}

#' Identify Pending Batches
#'
#' Scans the batch layer for un-promoted batches.
#'
#' @param config xacc_config object.
#' @return A data frame of pending batch metadata, sorted by creation time.
#' @noRd
.identify_pending_batches <- function(config) {
  state <- .get_bronze_state(config)
  promoted <- state$promoted_batches
  if (is.null(promoted)) promoted <- character(0)

  batch_root <- config$local$paths$batch

  if (!fs::dir_exists(batch_root)) {
    return(data.frame()) # No batches yet
  }

  # Find all batch metadata files
  meta_files <- fs::dir_ls(batch_root, recurse = TRUE, type = "file", glob = "*_batch_metadata.json")

  if (length(meta_files) == 0) {
    return(data.frame())
  }

  # Load all metadata
  batches <- lapply(meta_files, function(p) {
    jsonlite$fromJSON(p, simplifyVector = TRUE)
  })

  # Bind into a data.frame for easier sorting/filtering
  # Using map_dfr for safe column alignment across potentially different metadata schemas
  batches_df <- purrr::map_dfr(batches, as.data.frame, stringsAsFactors = FALSE)

  if (nrow(batches_df) == 0) return(data.frame())

  # Ensure we only include batches that have at least one parquet file
  batches_df$has_data <- sapply(meta_files, function(p) {
    length(fs::dir_ls(fs::path_dir(p), glob = "*.parquet")) > 0
  })

  batches_df <- batches_df[batches_df$has_data, ]

  # Filter out promoted batches
  pending <- batches_df[!batches_df$batch_id %in% promoted, ]


  if (nrow(pending) > 0) {
    # Sort by created_at (ascending, so oldest first)
    pending <- pending[order(pending$created_at), ]
  }

  return(pending)
}


## Public API --------------------------------------------------------------


#' Promote Materialized Batches to the Bronze Layer
#'
#' Performs bulk promotion of materialized batch datasets into the Bronze layer.
#' Promotion merges immutable batch Parquet files into cumulative, time-partitioned
#' Bronze Parquet tables with deterministic deduplication.
#'
#' @param config An object of class \code{xacc_config}.
#' @param stream_id Optional filter for a specific stream.
#' @export
promote_to_bronze <- function(config, stream_id = NULL) {
  pending <- .identify_pending_batches(config)

  if (nrow(pending) == 0) {
    cli$cli_alert_info("No pending batches to promote.")
    return(invisible(TRUE))
  }

  if (!is.null(stream_id)) {
    pending <- pending[pending$stream_id == stream_id, ]
    if (nrow(pending) == 0) {
      cli$cli_alert_info("No pending batches for stream {.val {stream_id}}.")
      return(invisible(TRUE))
    }
  }

  cli$cli_h1("Bronze Promotion (The Librarian)")

  # Connect to in-memory DuckDB
  con <- DBI$dbConnect(duckdb$duckdb())
  on.exit(DBI$dbDisconnect(con, shutdown = TRUE))

  streams <- unique(pending$stream_id)

  for (s_id in streams) {
    cli$cli_h2("Processing stream: {.val {s_id}}")

    stream_cfg <- config$streams[[s_id]]
    if (is.null(stream_cfg)) {
      cli$cli_alert_danger("Configuration missing for stream {.val {s_id}}. Skipping.")
      next
    }

    s_pending <- pending[pending$stream_id == s_id, ]

    # 1. Discover all tables in this stream's pending batches
    all_parquet_files <- fs::dir_ls(
      fs::path(config$local$paths$batch, s_id, s_pending$batch_id),
      glob = "*.parquet"
    )
    table_names <- unique(fs::path_ext_remove(fs::path_file(all_parquet_files)))

    # 2. Process batches individually
    for (i in seq_len(nrow(s_pending))) {
      b_meta <- s_pending[i, ]
      cli$cli_h3("Batch: {.val {b_meta$batch_id}}")

      # --- HYBRID RULE LOOKUP ---
      method_cfg <- config$methods[[b_meta$method_id]]
      primary_tbl <- method_cfg$primary_table
      part_col    <- method_cfg$partition_column
      ident_keys  <- method_cfg$identity_keys

      # 2.1 Find affected years using the PRIMARY table
      primary_path <- fs::path(config$local$paths$batch, s_id, b_meta$batch_id, paste0(primary_tbl, ".parquet"))

      if (!fs::file_exists(primary_path)) {
        cli$cli_alert_danger("Primary table {.val {primary_tbl}} missing in batch. Skipping batch.")
        next
      }

      years_query <- sprintf(
        "SELECT DISTINCT year(%s) as year FROM read_parquet('%s')",
        part_col, primary_path
      )
      affected_years <- DBI$dbGetQuery(con, years_query)$year

      # 2.2 Atomic Merge for each year
      for (yr in affected_years) {
        cli$cli_h3("Year: {.val {yr}}")

        for (tbl_nm in table_names) {
          batch_tbl_path <- fs::path(config$local$paths$batch, s_id, b_meta$batch_id, paste0(tbl_nm, ".parquet"))

          bronze_yr_dir <- fs::path(config$local$paths$bronze, s_id, paste0("year=", yr))
          fs::dir_create(bronze_yr_dir, recurse = TRUE)
          bronze_file <- fs::path(bronze_yr_dir, paste0(tbl_nm, ".parquet"))
          tmp_bronze_file <- fs::path(bronze_yr_dir, paste0(tbl_nm, "_tmp.parquet"))

          if (fs::file_exists(bronze_file)) {
            cli$cli_alert_info("Atomic Merge: {.val {tbl_nm}}")

            if (fs::file_exists(batch_tbl_path)) {
                # PURGE + REFILL in one operation
                sql <- sprintf("
                  COPY (
                    SELECT * FROM read_parquet('%s') b
                    WHERE NOT EXISTS (
                      SELECT 1 FROM read_parquet('%s') p
                      WHERE %s
                    )
                    UNION ALL BY NAME
                    SELECT * FROM read_parquet('%s')
                  ) TO '%s' (FORMAT PARQUET);
                ",
                bronze_file,
                primary_path,
                paste(paste0("b.", ident_keys, " = p.", ident_keys), collapse = " AND "),
                batch_tbl_path,
                tmp_bronze_file
                )
            } else {
                # PURGE ONLY (Patient exists in Primary but not in this secondary table)
                sql <- sprintf("
                  COPY (
                    SELECT * FROM read_parquet('%s') b
                    WHERE NOT EXISTS (
                      SELECT 1 FROM read_parquet('%s') p
                      WHERE %s
                    )
                  ) TO '%s' (FORMAT PARQUET);
                ",
                bronze_file,
                primary_path,
                paste(paste0("b.", ident_keys, " = p.", ident_keys), collapse = " AND "),
                tmp_bronze_file
                )
            }

            DBI$dbExecute(con, sql)

            # Windows-safe move
            if (fs::file_exists(bronze_file)) fs::file_delete(bronze_file)
            fs::file_move(tmp_bronze_file, bronze_file)

          } else if (fs::file_exists(batch_tbl_path)) {
            # Fresh create
            cli$cli_alert_info("Creating: {.val {tbl_nm}}")
            DBI$dbExecute(con, sprintf("COPY (SELECT * FROM read_parquet('%s')) TO '%s' (FORMAT PARQUET);", batch_tbl_path, bronze_file))
          }
        }
      }
    }
  }

  # Update State
  state <- .get_bronze_state(config)
  state$promoted_batches <- unique(c(state$promoted_batches, pending$batch_id))
  state$last_promoted_batches <- pending$batch_id
  state$last_promoted_batch   <- tail(pending$batch_id, 1)
  state$last_promotion_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  .save_bronze_state(config, state)

  cli$cli_alert_success("Promotion complete. {nrow(pending)} batches merged.")
  invisible(TRUE)
}
