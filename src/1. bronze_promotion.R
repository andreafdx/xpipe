
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
#'   \item Partitions data by anchor-derived year
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
#' without writing any data.
#'
#' @section Immutability:
#' Bronze promotion is irreversible. Once rows are appended, they are
#' never modified or removed.
#'
#' @param config xacc_config object.
#' @param stream_id Optional stream filter. If provided, only batches
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
    config,
    stream_id = NULL,
    dry_run = FALSE,
    confirm = interactive()
) {
  pending <- .identify_pending_batches(config)

  if (nrow(pending) == 0) {
    cli::cli_alert_info("No pending batches to promote.")
    return(invisible(TRUE))
  }

  if (!is.null(stream_id)) {
    pending <- pending[pending$stream_id == stream_id, ]
    if (nrow(pending) == 0) {
      cli::cli_alert_info("No pending batches for stream {.val {stream_id}}.")
      return(invisible(TRUE))
    }
  }

  state <- .get_bronze_state(config)
  if (is.null(state$promoted_batches)) {
    state$promoted_batches <- character(0)
  }

  .validate_anchor_definitions(config)

  previews <- purrr::map(
    seq_len(nrow(pending)),
    ~ .prepare_bronze_promotion_preview(pending[.x, ], config)
  )

  .print_bronze_preview(previews)

  if (isTRUE(dry_run)) {
    cli::cli_alert_info("Dry run complete. No data was written.")
    return(invisible(TRUE))
  }

  .confirm_bronze_promotion(confirm)

  for (preview in previews) {
    .apply_bronze_promotion(preview, config)
    state$promoted_batches <- c(state$promoted_batches, preview$batch_id)
    state$last_promotion_at <- .now_iso()
  }

  .save_bronze_state(config, state)

  cli::cli_alert_success(
    "Bronze promotion complete. {length(previews)} batch(es) appended."
  )
  invisible(TRUE)
}




# Helpers -----------------------------------------------------------------


## Pipeline ---------------------------------------------------------------


#' Null-coalescing operator
#'
#' Returns the left-hand side if it is not NULL, otherwise returns the right-hand side.
#'
#' @keywords internal
#' @noRd
`%||%` <- function(lhs, rhs) {
  if (is.null(lhs)) rhs else lhs
}


#' Read Bronze layer state
#'
#' Loads the Bronze layer state file (`layer.json`) which tracks
#' promoted batches and promotion timestamps.
#'
#' @param config xacc_config object.
#' @return A list representing the Bronze state.
#'
#' @keywords internal
#' @noRd
.get_bronze_state <- function(config) {
  path <- fs::path(config$local$paths$bronze, "layer.json")

  if (!fs::file_exists(path)) {
    cli::cli_abort(
      c(
        "Bronze layer state not found",
        "x" = "File {.file {path}} does not exist"
      ),
      class = c("bronze", "state")
    )
  }

  jsonlite::fromJSON(path, simplifyVector = TRUE)
}

#' Save Bronze layer state
#'
#' Persists the updated Bronze layer state to `layer.json`. This state
#' tracks which batches have been promoted and records promotion timestamps.
#'
#' This function performs no validation and should only be called by
#' the Bronze promotion pipeline after successful data writes.
#'
#' @param config xacc_config object.
#' @param state A list representing the Bronze layer state.
#'
#' @keywords internal
#' @noRd
.save_bronze_state <- function(config, state) {
  path <- fs::path(config$local$paths$bronze, "layer.json")

  jsonlite::write_json(
    state,
    path,
    auto_unbox = TRUE,
    pretty = TRUE
  )

  invisible(TRUE)
}


#' Identify unpromoted batches
#'
#' Scans the Batch layer metadata and returns all materialized batches
#' that have not yet been promoted to Bronze.
#'
#' @param config xacc_config object.
#' @return Data frame of pending batches ordered by creation time.
#'
#' @keywords internal
#' @noRd
.identify_pending_batches <- function(config) {
  state <- .get_bronze_state(config)
  promoted <- state$promoted_batches %||% character(0)

  meta_files <- fs::dir_ls(
    config$local$paths$batch,
    recurse = TRUE,
    glob = "*_batch_metadata.json"
  )

  if (length(meta_files) == 0) {
    return(data.frame())
  }

  batches <- purrr::map_dfr(
    meta_files,
    ~ jsonlite::fromJSON(.x, simplifyVector = TRUE),
    .id = "meta_file"
  )

  batches <- batches[!batches$batch_id %in% promoted, ]

  if (nrow(batches) == 0) return(data.frame())

  batches[order(batches$created_at), ]
}


#' Validate anchor definitions for Bronze promotion
#'
#' Ensures that every method defines exactly one anchor table and
#' a valid partition (anchor) column.
#'
#' @param config xacc_config object.
#'
#' @keywords internal
#' @noRd
.validate_anchor_definitions <- function(config) {
  for (nm in names(config$methods)) {
    m <- config$methods[[nm]]

    anchor <- m$anchor_table %||% m$primary_table

    if (is.null(anchor) || length(anchor) != 1 || !nzchar(anchor)) {
      cli::cli_abort(
        c(
          "Invalid method anchor definition",
          "x" = "Method {.val {nm}} must define exactly one anchor table"
        ),
        class = c("bronze", "anchor")
      )
    }

    if (is.null(m$partition_column) || !nzchar(m$partition_column)) {
      cli::cli_abort(
        c(
          "Invalid partition definition",
          "x" = "Method {.val {nm}} must define a partition_column"
        ),
        class = c("bronze", "anchor")
      )
    }
  }

  invisible(TRUE)
}


#' Apply append-only Bronze promotion
#'
#' Appends enriched batch rows to the Bronze layer according to
#' anchor-derived partitioning rules.
#'
#' @param preview Prepared Bronze promotion preview.
#' @param config xacc_config object.
#'
#' @keywords internal
#' @noRd
.apply_bronze_promotion <- function(preview, config) {

  batch_dir <- fs::path(
    config$local$paths$batch,
    preview$stream_id,
    preview$batch_id
  )

  parquet_files <- fs::dir_ls(batch_dir, glob = "*.parquet")

  for (pq in parquet_files) {

    table_name <- fs::path_ext_remove(fs::path_file(pq))
    df <- arrow::read_parquet(pq)

    df$`__batch_id`         <- preview$batch_id
    df$`__stream_id`        <- preview$stream_id
    df$`__method_id`        <- preview$method_id
    df$`__anchor_source`    <- preview$anchor_source
    df$`__batch_created_at` <- preview$created_at
    df$`__ingested_at`      <- Sys.time()

    ## anchor_time / year inherited from preview
    anchor_table <- sub("\\..*", "", preview$anchor_source)
    anchor_column <- sub(".*\\.", "", preview$anchor_source)

    anchor_df <- arrow::read_parquet(
      fs::path(batch_dir, paste0(anchor_table, ".parquet"))
    )

    df$`__anchor_time` <- anchor_df[[anchor_column]]
    df$`__anchor_year` <- as.integer(
      format(as.Date(df$`__anchor_time`), "%Y")
    )

    for (yr in unique(df$`__anchor_year`)) {

      target_dir <- fs::path(
        config$local$paths$bronze,
        paste0(preview$stream_id, "_", preview$method_id),
        paste0("year=", yr)
      )
      fs::dir_create(target_dir, recurse = TRUE)

      target_file <- fs::path(target_dir, paste0(table_name, ".parquet"))

      arrow::write_parquet(
        df[df$`__anchor_year` == yr, ],
        target_file,
        append = fs::file_exists(target_file)
      )
    }
  }

  invisible(TRUE)
}

.now_iso <- function() {
  format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
}


## CLI --------------------------------------------------------------------


#' Prepare Bronze promotion preview
#'
#' Computes the anchor source, affected years, and tables for a batch
#' without performing any writes.
#'
#' @param batch One-row batch metadata data frame.
#' @param config xacc_config object.
#' @return A list describing the planned Bronze promotion.
#'
#' @keywords internal
#' @noRd
.prepare_bronze_promotion_preview <- function(batch, config) {

  method_cfg <- config$methods[[batch$method_id]]
  anchor_table  <- method_cfg$anchor_table %||% method_cfg$primary_table
  anchor_column <- method_cfg$partition_column
  anchor_source <- paste0(anchor_table, ".", anchor_column)

  batch_dir <- fs::path(
    config$local$paths$batch,
    batch$stream_id,
    batch$batch_id
  )

  anchor_path <- fs::path(batch_dir, paste0(anchor_table, ".parquet"))
  if (!fs::file_exists(anchor_path)) {
    cli::cli_abort(
      c(
        "Anchor table missing",
        "x" = "Expected {.file {anchor_path}}"
      ),
      class = c("bronze", "anchor")
    )
  }

  anchor_df <- arrow::read_parquet(anchor_path)

  if (!anchor_column %in% names(anchor_df)) {
    cli::cli_abort(
      c(
        "Missing anchor column",
        "x" = "{.val {anchor_column}} not found in {.val {anchor_table}}"
      ),
      class = c("bronze", "anchor")
    )
  }

  anchor_year <- as.integer(
    format(as.Date(anchor_df[[anchor_column]]), "%Y")
  )

  tables <- fs::path_ext_remove(
    fs::path_file(fs::dir_ls(batch_dir, glob = "*.parquet"))
  )

  list(
    batch_id      = batch$batch_id,
    stream_id     = batch$stream_id,
    method_id     = batch$method_id,
    anchor_source = anchor_source,
    years         = sort(unique(anchor_year)),
    tables        = tables,
    created_at    = batch$created_at
  )
}

.print_bronze_preview <- function(previews) {

  cli::cli_h2("Bronze Promotion Preview")

  for (p in previews) {
    cli::cli_h3("Batch {.val {p$batch_id}}")

    cli::cli_bullets(c(
      "Stream          : {.val {p$stream_id}}",
      "Method          : {.val {p$method_id}}",
      "Anchor source   : {.val {p$anchor_source}}",
      "Anchor years    : {.val {paste(p$years, collapse = ', ')}}",
      "Tables promoted : {.val {paste(p$tables, collapse = ', ')}}"
    ))
  }

  cli::cli_alert_warning(
    "Bronze promotion is append-only and irreversible."
  )

  invisible(TRUE)
}

.confirm_bronze_promotion <- function(confirm) {

  if (!isTRUE(confirm)) {
    return(invisible(TRUE))
  }

  answer <- readline("Proceed with Bronze promotion? [y/N]: ")

  if (!nzchar(answer) || tolower(substr(answer, 1, 1)) != "y") {
    cli::cli_abort("Bronze promotion aborted by user.", class = "bronze_abort")
  }

  invisible(TRUE)
}

