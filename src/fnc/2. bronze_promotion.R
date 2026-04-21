box::use(
  jsonlite,
  fs,
  cli,
  duckdb,
  DBI,
  purrr[imap_chr]
)

#' Get Bronze State
#'
#' Reads the state of the Bronze layer from `layer.json`.
#'
#' @param config xacc_config object.
#' @return A list with the current state.
#' @export
get_bronze_state <- function(config) {
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
#' @export
save_bronze_state <- function(config, state) {
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
#' @export
identify_pending_batches <- function(config) {
  state <- get_bronze_state(config)
  promoted <- state$promoted_batches
  if (is.null(promoted)) promoted <- character(0)
  
  batch_root <- config$local$paths$batch
  
  if (!fs$dir_exists(batch_root)) {
    return(data.frame()) # No batches yet
  }
  
  # Find all batch metadata files
  meta_files <- fs$dir_ls(batch_root, recurse = TRUE, type = "file", glob = "*_batch_metadata.json")
  
  if (length(meta_files) == 0) {
    return(data.frame())
  }
  
  # Load all metadata
  batches <- lapply(meta_files, function(p) {
    jsonlite$fromJSON(p, simplifyVector = TRUE)
  })
  
  # Bind into a data.frame for easier sorting/filtering
  batches_df <- do.call(rbind, lapply(batches, as.data.frame, stringsAsFactors = FALSE))

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

#' Promote Batches to Bronze
#'
#' Orchestrates the bulk promotion of pending batches to the Bronze layer.
#'
#' @param config xacc_config object.
#' @param stream_id Optional filter for a specific stream.
#' @export
promote_to_bronze <- function(config, stream_id = NULL) {
  pending <- identify_pending_batches(config)
  
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
  
  # Group by stream
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
      # 1. Get method rules for this specific batch
      method_cfg <- config$methods[[b_meta$method_id]]
      primary_tbl <- method_cfg$primary_table
      part_col    <- method_cfg$partition_column
      ident_keys  <- method_cfg$identity_keys
      
      # 2. Determine years using the PRIMARY table
      primary_path <- fs::path(config$local$paths$batch, s_id, b_meta$batch_id, paste0(primary_tbl, ".parquet"))
      
      if (!fs::file_exists(primary_path)) {
        cli$cli_alert_danger("Primary table {.val {primary_tbl}} missing in batch. Skipping batch.")
        next
      }
      
      # Use stream_cfg$partition_granularity here if we wanted to support Month
      # For now we stick to year() as requested
      years_query <- sprintf(
        "SELECT DISTINCT year(%s) as year FROM read_parquet('%s')",
        part_col, primary_path
      )
      affected_years <- DBI$dbGetQuery(con, years_query)$year
      
      # 3. Apply these years to all tables in the batch
      for (tbl_nm in table_names) {
        batch_tbl_path <- fs::path(config$local$paths$batch, s_id, b_meta$batch_id, paste0(tbl_nm, ".parquet"))
        if (!fs::file_exists(batch_tbl_path)) next
        
        for (yr in affected_years) {
          cli$cli_alert_info("Table {.val {tbl_nm}} -> Year {.val {yr}}")
          
          bronze_yr_dir <- fs::path(config$local$paths$bronze, s_id, paste0("year=", yr))
          fs::dir_create(bronze_yr_dir, recurse = TRUE)
          bronze_file <- fs::path(bronze_yr_dir, paste0(tbl_nm, ".parquet"))
          
          if (fs::file_exists(bronze_file)) {
            combine_sql <- sprintf("
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
            batch_tbl_path,
            paste(paste0("b.", ident_keys, " = p.", ident_keys), collapse = " AND "),
            batch_tbl_path,
            bronze_file
            )
          } else {
            combine_sql <- sprintf("COPY (SELECT * FROM read_parquet('%s')) TO '%s' (FORMAT PARQUET);", batch_tbl_path, bronze_file)
          }
          DBI$dbExecute(con, combine_sql)
        }
      }
    }
  }
  
  # Update State
  state <- get_bronze_state(config)
  state$promoted_batches <- unique(c(state$promoted_batches, pending$batch_id))
  state$last_promotion_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  save_bronze_state(config, state)
  
  cli$cli_alert_success("Promotion complete. {nrow(pending)} batches merged.")
  invisible(TRUE)
}
