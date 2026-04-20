box::use(
  fs,
  cli
)

# Helper functions --------------------------------------------------------

#' Assert configuration validity for batch creation
#'
#' Ensures that a valid `xacc_config` object is provided and that
#' all required branches (local paths, batch datastreams) are present.
#'
#' @param config An object of class `xacc_config`.
#' @return Invisibly returns TRUE if valid, otherwise aborts.
#' @keywords internal
#' @noRd
.assert_config_for_batch <- function(config) {
  if (missing(config) || !inherits(config, "xacc_config")) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "A valid {.arg config} object loaded via {.code load_options()} is required"
      ),
      class = c("batch_job", "config")
    )
  }

  if (is.null(config$local$paths$inbox) ||
      is.null(config$local$paths$batch)) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "Missing required paths in config",
        "i" = "Expected: config$local$paths$inbox and config$local$paths$batch"
      ),
      class = c("batch_job", "config", "paths")
    )
  }

  if (is.null(config$batch$datastream)) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "Batch datastream options not loaded"
      ),
      class = c("batch_job", "config", "datastream")
    )
  }

  invisible(TRUE)
}

# Datastream validation ---------------------------------------------------

#' Retrieve datastream configuration from batch layer
#'
#' @param config xacc_config object.
#' @param datastream Character scalar.
#' @return A list with the datastream configuration.
#' @keywords internal
#' @noRd
.get_datastream_config <- function(config, datastream) {
  if (!is.character(datastream) || length(datastream) != 1 || !nzchar(datastream)) {
    cli::cli_abort(
      c(
        "Invalid datastream",
        "x" = "{.arg datastream} must be a non-empty string"
      ),
      class = c("batch_job", "datastream")
    )
  }

  available <- names(config$batch$datastream)
  if (!(datastream %in% available)) {
    cli::cli_abort(
      c(
        "Invalid datastream",
        "x" = "Unknown datastream: {.val {datastream}}",
        "i" = "Available datastreams: {.str {available}}"
      ),
      class = c("batch_job", "datastream")
    )
  }

  config$batch$datastream[[datastream]]
}

## Inbox ------------------------------------------------------------------

#' Resolve input file from inbox
#'
#' @param config xacc_config object.
#' @param filename Character scalar.
#' @return Normalized absolute file path.
#' @keywords internal
#' @noRd
.resolve_inbox_file <- function(config, filename) {
  if (!is.character(filename) || length(filename) != 1 || !nzchar(filename)) {
    cli::cli_abort(
      c(
        "Invalid filename",
        "x" = "{.arg filename} must be a non-empty string"
      ),
      class = c("batch_job", "filename")
    )
  }

  full_path <- fs::path(config$local$paths$inbox, filename)
  if (!fs::file_exists(full_path)) {
    cli::cli_abort(
      c(
        "Input file not found",
        "x" = "File {.file {filename}} was not found in inbox",
        "i" = "Inbox: {.file {config$local$paths$inbox}}"
      ),
      class = c("batch_job", "filename")
    )
  }

  fs::path_norm(full_path)
}

## Alt --------------------------------------------------------------------

# Validate alt flag
.assert_alt_flag <- function(alt) {
  if (!is.logical(alt) || length(alt) != 1 || is.na(alt)) {
    cli::cli_abort(
      c(
        "Invalid alt flag",
        "x" = "{.arg alt} must be TRUE or FALSE"
      ),
      class = c("batch_job", "alt")
    )
  }
  invisible(TRUE)
}

#' Resolve effective batch storage stream
#'
#' @keywords internal
#' @noRd
.resolve_storage_stream <- function(datastream, ds_config, alt) {
  alt_folder <- ds_config$alt

  if (isTRUE(alt)) {
    if (is.null(alt_folder) || !is.character(alt_folder) || !nzchar(alt_folder)) {
      cli::cli_abort(
        c(
          "Alternative version not supported",
          "x" = "Datastream {.val {datastream}} does not declare an alternate folder"
        ),
        class = c("batch_job", "alt", "datastream")
      )
    }
    return(alt_folder)
  }

  datastream
}

## Batch id & storage -----------------------------------------------------

.normalize_or_generate_batch_id <- function(storage_stream, batch_id = NULL) {
  if (!is.null(batch_id)) {
    if (!is.character(batch_id) || length(batch_id) != 1 || !nzchar(batch_id)) {
      cli::cli_abort(
        c(
          "Invalid batch_id",
          "x" = "{.arg batch_id} must be a non-empty string"
        ),
        class = c("batch_job", "batch_id")
      )
    }
    return(batch_id)
  }

  ts <- format(Sys.time(), "%Y%m%d_%H%M%OS3")
  ts <- gsub("\\.", "", ts)

  paste0(storage_stream, "_", ts)
}

.build_batch_target_dir <- function(config, storage_stream, batch_id) {
  fs::path_norm(
    fs::path(config$local$paths$batch, storage_stream, batch_id)
  )
}

# Build S3 batch job object
.build_batch_job <- function(
    filename, filepath,
    datastream, storage_stream,
    anchor, alt,
    batch_root, batch_dir,
    batch_id
) {
  structure(
    list(
      batch_id = batch_id,
      filename = filename,
      filepath = filepath,
      datastream = datastream,
      storage_stream = storage_stream,
      anchor = anchor,
      alt = alt,
      batch_root = batch_root,
      batch_dir = batch_dir,
      status = "initialized"
    ),
    class = "xacc_batch_job"
  )
}

## Public API -------------------------------------------------------------

#' Create a new Batch Import Job
#'
#' @export
new_batch_job <- function(
    filename,
    datastream,
    alt = FALSE,
    config,
    batch_id = NULL
) {
  .assert_config_for_batch(config)

  ds_config <- .get_datastream_config(config, datastream)
  filepath  <- .resolve_inbox_file(config, filename)

  .assert_alt_flag(alt)
  storage_stream <- .resolve_storage_stream(datastream, ds_config, alt)

  anchor <- ds_config$anchor

  batch_id  <- .normalize_or_generate_batch_id(storage_stream, batch_id)
  batch_dir <- .build_batch_target_dir(config, storage_stream, batch_id)

  .build_batch_job(
    filename = filename,
    filepath = filepath,
    datastream = datastream,
    storage_stream = storage_stream,
    anchor = anchor,
    alt = alt,
    batch_root = config$local$paths$batch,
    batch_dir = batch_dir,
    batch_id = batch_id
  )
}

## S3 print ---------------------------------------------------------------

#' Print xacc batch job
#'
#' @export
print.xacc_batch_job <- function(x, ...) {
  cli::cli_div(
    theme = list(rule = list(color = "cyan", "line-type" = "double"))
  )
  cli::cli_rule("XACC Batch Job")

  cli::cli_h2("Status")
  cli::cli_alert_success(x$status)

  cli::cli_h2("Input")
  cli::cli_bullets(c(
    "file        : {.file {x$filepath}}",
    "datastream  : {.val {x$datastream}}",
    "anchor      : {.val {x$anchor}}"
  ))

  if (isTRUE(x$alt)) {
    cli::cli_warn(
      c(
        "Alternate variant enabled",
        "i" = "Stored under {.val {x$storage_stream}}"
      ),
      class = c("batch_job", "alt")
    )
  }

  cli::cli_h2("Storage (Batch)")
  cli::cli_bullets(c(
    "root        : {.file {x$batch_root}}",
    "stream      : {.val {x$storage_stream}}",
    "batch_id    : {.val {x$batch_id}}",
    "target dir  : {.file {x$batch_dir}}"
  ))

  cli::cli_rule()
  cli::cli_end()

  invisible(x)
}
