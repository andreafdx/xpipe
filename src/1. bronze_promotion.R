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
#'   \item Partitions data by anchor-derived time (year or month)
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
#' without writing any data and without updating Bronze state.
#'
#' @section Storage layout:
#' Bronze is written as immutable Parquet shards per promoted batch:
#' \itemize{
#'   \item \code{bronze/<stream>__<method>/year=YYYY/<table>__<batch_id>.parquet}
#' }
#' Promotion refuses to overwrite an existing shard file.
#'
#' @section Anchor inheritance:
#' Anchor time is derived from the method anchor table only. Secondary tables
#' inherit \code{__anchor_time} by joining to the anchor table using
#' \code{identity_keys}. If required keys are missing or if rows cannot be matched,
#' promotion aborts for that batch.
#'
#' @section Immutability:
#' Bronze promotion is irreversible. Once rows are appended (written as shards),
#' they are never modified or removed.
#'
#' @param config xacc_config object.
#' @param stream Optional stream filter. If provided, only batches
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
    stream = NULL,
    dry_run = FALSE,
    confirm = interactive()
) {
  # ---- read state once; shared by pending identification and promotion log
  state <- .get_bronze_state(config)
  state$promotion_log <- state$promotion_log %||% list()

  pending <- .identify_pending_batches(config, state = state)

  if (nrow(pending) == 0) {
    cli::cli_alert_info("No pending batches to promote.")
    return(invisible(TRUE))
  }

  if (!is.null(stream)) {
    pending <- pending[pending$stream_id == stream, ]
    if (nrow(pending) == 0) {
      cli::cli_alert_info("No pending batches for stream {.val {stream}}.")
      return(invisible(TRUE))
    }
  }

  .validate_anchor_definitions(config, method_ids = unique(pending$method_id))

  previews <- purrr::map(
    seq_len(nrow(pending)),
    ~ .prepare_bronze_promotion_preview(pending[.x, ], config)
  )

  .print_bronze_preview(previews)

  if (isTRUE(dry_run)) {
    cli::cli_alert_info(
      "Dry run complete. No data was written and no state was updated."
    )
    return(invisible(TRUE))
  }

  .confirm_bronze_promotion(confirm)

  # ---- execute + append promotion events
  # Errors propagate immediately. Failed batches are never recorded, so they
  # remain pending and will be retried on the next run. The promotion log is
  # a success-only ledger — no partial or failed entries.
  for (preview in previews) {
    .apply_bronze_promotion(preview, config)

    state$promotion_log <- c(
      state$promotion_log,
      list(.make_promotion_event(preview, config, status = "success"))
    )

    # persist per batch (survive partial failures)
    .save_bronze_state(config, state)
  }

  cli::cli_alert_success(
    "Bronze promotion complete. {length(previews)} batch(es) appended successfully."
  )
  invisible(TRUE)
}



# Helpers -----------------------------------------------------------------


## Pipeline ---------------------------------------------------------------


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
        "x" = "File {.file {path}} does not exist",
        "i" = "Create it by writing the seed JSON or run {.code .init_bronze_state(config)}"
      ),
      class = c("bronze", "state")
    )
  }

  state <- jsonlite::fromJSON(path, simplifyVector = FALSE)

  if (!is.list(state) || !identical(state$format, "promotion_log") || is.null(state$promotion_log)) {
    cli::cli_abort(
      c(
        "Invalid Bronze layer state",
        "x" = "layer.json is not in the supported format",
        "i" = "Overwrite bronze/layer.json with the new seed format"
      ),
      class = c("bronze", "state")
    )
  }

  if (!is.list(state$promotion_log)) {
    cli::cli_abort(
      c(
        "Invalid Bronze layer state",
        "x" = "{.val promotion_log} must be a list"
      ),
      class = c("bronze", "state")
    )
  }

  state
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

  if (!is.list(state) || !identical(state$format, "promotion_log") || is.null(state$promotion_log)) {
    cli::cli_abort(
      c(
        "Invalid Bronze state write",
        "x" = "Refusing to write invalid state (expected format=promotion_log)"
      ),
      class = c("bronze", "state")
    )
  }

  jsonlite::write_json(state, path, auto_unbox = TRUE, pretty = TRUE)
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
.identify_pending_batches <- function(config, state = NULL) {
  if (is.null(state)) state <- .get_bronze_state(config)
  promoted <- .promoted_batch_ids(state)

  meta_files <- fs::dir_ls(
    config$local$paths$batch,
    recurse = TRUE,
    glob = "*_batch_metadata.json"
  )

  if (length(meta_files) == 0) return(data.frame())

  batches <- purrr::map_dfr(meta_files, function(p) {
    meta <- jsonlite::fromJSON(p, simplifyVector = FALSE)

    data.frame(
      batch_id   = meta$batch_id,
      stream_id  = meta$stream$id,
      method_id  = meta$method$id,
      created_at = meta$execution$created_at,
      stringsAsFactors = FALSE
    )
  })

  batches <- batches[!batches$batch_id %in% promoted, ]
  if (nrow(batches) == 0) return(data.frame())

  batches[order(batches$created_at), ]
}



#' Validate anchor definitions for Bronze promotion
#'
#' Ensures that every method defines exactly one anchor table, a valid partition
#' column, and identity keys required to inherit anchor time to secondary tables.
#'
#' @param config xacc_config object.
#'
#' @keywords internal
#' @noRd
.validate_anchor_definitions <- function(config, method_ids = NULL) {
  # If method_ids provided, validate only those; otherwise validate all
  methods_to_check <- if (!is.null(method_ids)) {
    intersect(method_ids, names(config$methods))
  } else {
    names(config$methods)
  }

  for (nm in methods_to_check) {
    m <- config$methods[[nm]]

    anchor <- m$anchor_table

    if (is.null(anchor) || length(anchor) != 1 || !nzchar(anchor)) {
      cli::cli_abort(
        c(
          "Invalid method anchor definition",
          "x" = "Method {.val {nm}} must define one anchor table"
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

    if (is.null(m$identity_keys) || length(m$identity_keys) == 0) {
      cli::cli_abort(
        c(
          "Invalid identity key definition",
          "x" = "Method {.val {nm}} must define identity_keys for anchor inheritance"
        ),
        class = c("bronze", "anchor")
      )
    }
  }

  invisible(TRUE)
}

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

  anchor_keys <- method_cfg$identity_keys
  if (is.null(anchor_keys) || length(anchor_keys) == 0) {
    cli::cli_abort(
      c(
        "Missing method identity keys",
        "x" = "Method {.val {batch$method_id}} must define identity_keys to inherit anchor_time",
        "i" = "These keys must exist in the anchor table and all secondary tables"
      ),
      class = c("bronze", "anchor")
    )
  }

  anchor_table  <- method_cfg$anchor_table
  anchor_column <- method_cfg$partition_column
  anchor_source <- paste0(anchor_table, ".", anchor_column)

  batch_dir <- fs::path(
    config$local$paths$batch,
    batch$batch_id
  )

  anchor_path <- fs::path(batch_dir, paste0(anchor_table, ".parquet"))
  if (!fs::file_exists(anchor_path)) {
    cli::cli_abort(
      c(
        "Anchor table missing",
        "x" = "Required anchor table {.val {anchor_table}} was not found",
        "i" = "Expected location: {.file {batch_dir}}"
      ),
      class = c("bronze", "anchor")
    )
  }

  anchor_df <- arrow::read_parquet(anchor_path)

  missing_keys <- setdiff(anchor_keys, names(anchor_df))
  if (length(missing_keys) > 0) {
    cli::cli_abort(
      c(
        "Anchor keys missing in anchor table",
        "x" = "Anchor table {.val {anchor_table}} is missing required keys: {.val {missing_keys}}",
        "i" = "Table location: {.file {anchor_path}}"
      ),
      class = c("bronze", "anchor")
    )
  }

  if (!anchor_column %in% names(anchor_df)) {
    cli::cli_abort(
      c(
        "Missing anchor column",
        "x" = "Column {.val {anchor_column}} not found in anchor table {.val {anchor_table}}",
        "i" = "Table location: {.file {anchor_path}}"
      ),
      class = c("bronze", "anchor")
    )
  }

  anchor_year <- as.integer(
    format(as.Date(anchor_df[[anchor_column]]), "%Y")
  )

  # Precompute key_lookup here — avoids re-reading anchor parquet in apply phase
  ak         <- .make_key(anchor_df, anchor_keys)
  key_lookup <- setNames(anchor_df[[anchor_column]], ak)

  # Validate uniqueness here (preview phase): if keys are duplicated the years
  # computation below is unreliable and apply would explode. Fail early with no
  # side effects.
  if (anyDuplicated(ak)) {
    cli::cli_abort(
      c(
        "Anchor keys are not unique",
        "x" = "Anchor table {.val {anchor_table}} contains duplicate identity keys",
        "i" = "Cannot deterministically inherit anchor_time",
        "i" = "Batch: {.val {batch$batch_id}}"
      ),
      class = c("bronze", "anchor")
    )
  }

  tables <- fs::path_ext_remove(
    fs::path_file(fs::dir_ls(batch_dir, glob = "*.parquet"))
  )

  list(
    batch_id              = batch$batch_id,
    stream_id             = batch$stream_id,
    method_id             = batch$method_id,
    anchor_source         = anchor_source,
    anchor_table          = anchor_table,
    anchor_column         = anchor_column,
    anchor_keys           = anchor_keys,
    key_lookup            = key_lookup,
    years                 = sort(unique(anchor_year)),
    tables                = tables,
    created_at            = batch$created_at,
    partition_granularity = config$streams[[batch$stream_id]]$partition_granularity %||% "year"
  )
}


#' Apply append-only Bronze promotion
#'
#' Writes immutable Parquet shards for each promoted batch, partitioned by anchor year.
#' No existing Bronze Parquet files are read or rewritten.
#'
#' @param preview Prepared Bronze promotion preview.
#' @param config xacc_config object.
#'
#' @keywords internal
#' @noRd
.apply_bronze_promotion <- function(preview, config) {
  batch_dir    <- fs::path(config$local$paths$batch, preview$batch_id)
  anchor_table <- preview$anchor_table
  anchor_keys  <- preview$anchor_keys
  key_lookup   <- preview$key_lookup
  granularity  <- preview$partition_granularity %||% "year"

  # Defensive only — primary uniqueness check runs in preview phase.
  if (anyDuplicated(names(key_lookup))) {
    cli::cli_abort(
      c(
        "Anchor table keys are not unique",
        "x" = "Cannot inherit anchor_time deterministically from anchor table {.val {anchor_table}}",
        "i" = "Method: {.val {preview$method_id}}",
        "i" = "Batch: {.val {preview$batch_id}}"
      ),
      class = c("bronze", "anchor")
    )
  }

  for (pq in fs::dir_ls(batch_dir, glob = "*.parquet")) {

    table_name <- fs::path_ext_remove(fs::path_file(pq))
    df         <- arrow::read_parquet(pq)

    # Validate keys for secondary tables
    missing_in_df <- setdiff(anchor_keys, names(df))
    if (length(missing_in_df) > 0 && table_name != anchor_table) {
      cli::cli_abort(
        c(
          "Secondary table cannot inherit anchor_time",
          "x" = "Table {.val {table_name}} missing keys required to join to anchor table: {.val {missing_in_df}}",
          "i" = "Batch: {.val {preview$batch_id}}"
        ),
        class = c("bronze", "anchor")
      )
    }

    # Assign anchor_time via pre-built lookup
    df$`__anchor_time` <- key_lookup[.make_key(df, anchor_keys)]

    if (any(is.na(df$`__anchor_time`))) {
      cli::cli_abort(
        c(
          "Anchor inheritance failed",
          "x" = "{sum(is.na(df$`__anchor_time`))} row(s) in {.val {table_name}} unmatched",
          "i" = "Batch: {.val {preview$batch_id}}"
        ),
        class = c("bronze", "anchor")
      )
    }

    # Bronze metadata
    df$`__batch_id`         <- preview$batch_id
    df$`__stream_id`        <- preview$stream_id
    df$`__method_id`        <- preview$method_id
    df$`__anchor_source`    <- preview$anchor_source
    df$`__batch_created_at` <- preview$created_at
    df$`__ingested_at`      <- .now_iso()
    df$`__anchor_year`      <- as.integer(format(as.Date(df$`__anchor_time`), "%Y"))

    # Build per-row partition path from stream granularity
    if (granularity == "year") {
      part_dir <- paste0("year=", df$`__anchor_year`)
    } else if (granularity == "month") {
      df$`__anchor_month` <- as.integer(format(as.Date(df$`__anchor_time`), "%m"))
      part_dir <- paste0(
        "year=", df$`__anchor_year`,
        "/month=", sprintf("%02d", df$`__anchor_month`)
      )
    } else {
      cli::cli_abort(
        c(
          "Unsupported partition granularity",
          "x" = "Stream {.val {preview$stream_id}} declares unsupported granularity: {.val {granularity}}",
          "i" = "Supported values: 'year', 'month'"
        ),
        class = c("bronze", "partition")
      )
    }

    for (pdir in unique(part_dir)) {

      target_dir <- fs::path(
        config$local$paths$bronze,
        paste0(preview$stream_id, "__", preview$method_id),
        pdir
      )
      fs::dir_create(target_dir, recurse = TRUE)

      rows_to_append <- df[part_dir == pdir, ]
      if (nrow(rows_to_append) == 0) next

      # Immutable shard per (table, batch)
      target_file <- fs::path(target_dir, paste0(table_name, "__", preview$batch_id, ".parquet"))

      if (fs::file_exists(target_file)) {
        cli::cli_abort(
          c(
            "Bronze shard already exists",
            "x" = "Refusing to overwrite existing shard (append-only invariant)",
            "i" = "File: {.file {target_file}}"
          ),
          class = c("bronze", "append_only")
        )
      }

      arrow::write_parquet(rows_to_append, target_file)
    }
  }

  invisible(TRUE)
}

#' Current timestamp in ISO-8601 format
#'
#' @return Character scalar timestamp formatted as YYYY-MM-DDTHH:MM:SS±ZZZZ.
#' @keywords internal
#' @noRd
.now_iso <- function() {
  format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
}

#' Build composite key for anchor inheritance joins
#'
#' @param df Data frame-like object.
#' @param keys Character vector of key columns.
#' @return Character vector of composite keys (row-wise).
#' @keywords internal
#' @noRd
.make_key <- function(df, keys) {
  do.call(paste, c(df[keys], sep = "\r"))
}



#' Return batch ids that were successfully promoted
#'
#' @param state bronze layer state
#' @return character vector batch ids
#' @keywords internal
#' @noRd
.promoted_batch_ids <- function(state) {
  log <- state$promotion_log
  if (length(log) == 0) return(character(0))

  ids <- vapply(log, function(e) {
    if (!is.null(e$status) && identical(e$status, "success")) e$batch_id else NA_character_
  }, character(1))

  unique(stats::na.omit(ids))
}

#' Build a promotion event
#'
#' @param preview preview list produced by .prepare_bronze_promotion_preview()
#' @param config xacc_config object
#' @param status Character scalar. Always "success" — logged only on completion.
#' @return list (promotion event)
#' @keywords internal
#' @noRd
.make_promotion_event <- function(preview, config, status = "success") {
  user <- Sys.getenv("USERNAME")
  if (!nzchar(user)) user <- Sys.getenv("USER")
  user <- user %||% NA_character_

  host <- Sys.info()[["nodename"]] %||% NA_character_

  list(
    batch_id      = preview$batch_id,
    stream_id     = preview$stream_id,
    method_id     = preview$method_id,
    status        = status,
    promoted_at   = .now_iso(),
    anchor_source = preview$anchor_source %||% NA_character_,
    anchor_years  = preview$years %||% integer(0),
    tables        = preview$tables %||% character(0),
    tool          = config$runtime$tool$name %||% NA_character_,
    tool_version  = config$runtime$tool$version %||% NA_character_,
    user          = user,
    host          = host
  )
}


## CLI --------------------------------------------------------------------



#' Print Bronze promotion preview
#'
#' @param previews List of prepared preview objects.
#' @keywords internal
#' @noRd
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

#' Confirm Bronze promotion
#'
#' @param confirm Logical. If TRUE, prompt user before writing.
#' @keywords internal
#' @noRd
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
