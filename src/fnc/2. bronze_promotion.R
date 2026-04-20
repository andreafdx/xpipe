box::use(
  jsonlite,
  fs,
  cli
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
  
  # Filter out promoted batches
  pending <- batches_df[!batches_df$batch_id %in% promoted, ]
  
  if (nrow(pending) > 0) {
    # Sort by created_at (ascending, so oldest first)
    pending <- pending[order(pending$created_at), ]
  }
  
  return(pending)
}

