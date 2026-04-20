box::use(
  jsonlite,
  fs,
  cli,
  duckdb,
  DBI
)

#' Get Bronze State
#'
#' Reads the state of the Bronze layer from `layer.json`.
#'
#' @param config xacc_config object.
#' @return A list with the current state.
#' @export
get_bronze_state <- function(config) {
  path <- fs$path(config$local$paths$bronze, "layer.json")
  
  if (!fs$file_exists(path)) {
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
  path <- fs$path(config$local$paths$bronze, "layer.json")
  
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
    
    # 1. Identify all tables in the pending batches
    all_parquet_files <- fs::dir_ls(
      fs::path(config$local$paths$batch, s_id, s_pending$batch_id), 
      glob = "*.parquet"
    )
    
    table_names <- unique(fs::path_ext_remove(fs::path_file(all_parquet_files)))
    
    for (tbl_nm in table_names) {
      cli$cli_h3("Table: {.val {tbl_nm}}")
      
      # 2. Resolve paths for this specific table across batches
      table_batches <- s_pending
      table_batches$table_path <- fs::path(
        config$local$paths$batch, 
        s_id, 
        table_batches$batch_id, 
        paste0(tbl_nm, ".parquet")
      )
      
      table_batches <- table_batches[fs::file_exists(table_batches$table_path), ]
      
      if (nrow(table_batches) == 0) next
      
      batch_paths_sql <- paste0("'", table_batches$table_path, "'", collapse = ", ")
      
      # 3. Identify affected years for this table
      years_query <- sprintf(
        "SELECT DISTINCT year(%s) as year FROM read_parquet([%s])",
        stream_cfg$partition_column,
        batch_paths_sql
      )
      
      affected_years <- DBI$dbGetQuery(con, years_query)$year
      
      for (yr in affected_years) {
        cli$cli_alert_info("Merging Year: {.val {yr}}")
        
        # New structure: bronze/{stream}/year=YYYY/{table}/data.parquet
        bronze_yr_dir <- fs::path(config$local$paths$bronze, s_id, paste0("year=", yr), tbl_nm)
        fs::dir_create(bronze_yr_dir, recurse = TRUE)
        bronze_file <- fs::path(bronze_yr_dir, "data.parquet")
        
        # Step A: Load Pending Data for this year and table
        DBI$dbWriteTable(con, "pending_meta", table_batches, overwrite = TRUE)
        
        merge_sql <- sprintf("
          -- 1. Create a view of all pending data with batch IDs
          CREATE OR REPLACE VIEW pending_view AS 
          SELECT *, regexp_extract(filename, '.*/([^/]+)/[^/]+\\.parquet', 1) as batch_id
          FROM read_parquet([%s], filename=TRUE);

          -- 2. Deduplicate pending: latest batch wins for each identity
          CREATE OR REPLACE TEMP TABLE dedup_pending AS
          SELECT pv.* EXCLUDE(batch_id, filename), year(pv.%s) as year
          FROM pending_view pv
          JOIN pending_meta pm ON pv.batch_id = pm.batch_id
          WHERE year(pv.%s) = %d
          QUALIFY row_number() OVER(PARTITION BY %s ORDER BY pm.created_at DESC) = 1;
        ",
        batch_paths_sql,
        stream_cfg$partition_column,
        stream_cfg$partition_column,
        yr,
        paste(stream_cfg$identity_keys, collapse = ", ")
        )
        
        DBI$dbExecute(con, merge_sql)
        
        # Step B: Combine with existing Bronze
        if (fs::file_exists(bronze_file)) {
          combine_sql <- sprintf("
            COPY (
              SELECT * FROM read_parquet('%s') b
              WHERE NOT EXISTS (
                SELECT 1 FROM dedup_pending d 
                WHERE %s
              )
              UNION ALL BY NAME
              SELECT * FROM dedup_pending
            ) TO '%s' (FORMAT PARQUET);
          ",
          bronze_file,
          paste(paste0("b.", stream_cfg$identity_keys, " = d.", stream_cfg$identity_keys), collapse = " AND "),
          bronze_file
          )
        } else {
          combine_sql <- sprintf("
            COPY dedup_pending TO '%s' (FORMAT PARQUET);
          ",
          bronze_file
          )
        }
        
        DBI$dbExecute(con, combine_sql)
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

