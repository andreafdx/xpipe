box::use(
  fs,
  cli
)


# Helper functions --------------------------------------------------------


#' Assert configuration validity for batch creation
#'
#' Ensures that a valid `xacc_config` object is provided and that
#' all required branches (local paths, bronze datastreams) are present.
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

  if (is.null(config$local$paths$inbox) || is.null(config$local$paths$bronze)) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "Missing required paths in config",
        "i" = "Expected: config$local$paths$inbox and config$local$paths$bronze"
      ),
      class = c("batch_job", "config", "paths")
    )
  }

  if (is.null(config$bronze$datastream)) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "Bronze datastream options not loaded"
      ),
      class = c("batch_job", "config", "datastream")
    )
  }

  invisible(TRUE)
}


# Datastream validation ---------------------------------------------------


#' Retrieve datastream configuration from bronze layer
#'
#' Validates the datastream identifier and returns the corresponding
#' configuration from `config$bronze$datastream`.
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

  available <- names(config$bronze$datastream)
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

  config$bronze$datastream[[datastream]]
}


## Inbox ------------------------------------------------------------------

#' Resolve input file from inbox
#'
#' Validates the filename and resolves the absolute path inside
#' `config$local$paths$inbox`.
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


## Time block -------------------------------------------------------------

# Validate year
.assert_year <- function(year) {
  if (!is.numeric(year) || length(year) != 1 || is.na(year)) {
    cli::cli_abort(
      c(
        "Invalid year",
        "x" = "{.arg year} must be a single numeric value (e.g., 2025)"
      ),
      class = c("batch_job", "year")
    )
  }
  invisible(TRUE)
}


#' Normalize quarter according to time_block
#'
#' Applies datastream time logic:
#' - quarterly streams require quarter 1–4
#' - yearly streams ignore quarter
#'
#' @param datastream Character scalar.
#' @param ds_config Datastream configuration.
#' @param quarter Numeric or NULL.
#' @return Normalized quarter value or NULL.
#' @keywords internal
#' @noRd
.normalize_quarter_by_time_block <- function(datastream, ds_config, quarter) {
  tb <- ds_config$time_block

  if (identical(tb, "q")) {
    if (is.null(quarter) || !is.numeric(quarter) || length(quarter) != 1 ||
        is.na(quarter) || !(quarter %in% 1:4)) {
      cli::cli_abort(
        c(
          "Invalid quarter: {.val {quarter}}",
          "x" = "Datastream {.val {datastream}} has time block 'q': quarter must be 1..4"
        ),
        class = c("batch_job", "quarter")
      )
    }
    return(quarter)
  }

  if (identical(tb, "y")) {
    if (!is.null(quarter)) {
      cli::cli_alert_warning(
        "Quarter ignored. Datastream {.val {datastream}} has time block 'y'",
        class = c("batch_job", "quarter")
      )
    }
    return(NULL)
  }

  cli::cli_abort(
    c(
      "Invalid datastream configuration",
      "x" = "Unexpected time_block",
      "!" = "Found: {.val {tb}}"
    ),
    class = c("batch_job", "config", "datastream")
  )
}


## Alt --------------------------------------------------------------------

# Validate alt flag (banale)
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


#' Resolve effective bronze storage stream
#'
#' If `alt = TRUE`, returns the alternate folder name declared
#' in `ds_config$alt`. Otherwise returns the base datastream name.
#'
#' @param datastream Character scalar.
#' @param ds_config Datastream configuration.
#' @param alt Logical scalar.
#' @return Character scalar. Folder name used for bronze storage.
#' @keywords internal
#' @noRd
.resolve_storage_stream <- function(datastream, ds_config, alt) {
  alt_folder <- ds_config$alt

  if (isTRUE(alt)) {
    if (is.null(alt_folder) || !is.character(alt_folder) ||
        length(alt_folder) != 1 || !nzchar(alt_folder)) {
      cli::cli_abort(
        c(
          "Alternative version not supported",
          "x" = "Datastream {.val {datastream}} does not declare an alternate folder",
          "i" = "Define {.field alt} in bronze.json or set {.code alt = FALSE}"
        ),
        class = c("batch_job", "alt", "datastream")
      )
    }
    return(alt_folder)
  }

  datastream
}



# Batch id & storage ------------------------------------------------------


# Generate or validate batch_id
.normalize_or_generate_batch_id <- function(
    storage_stream,
    batch_id = NULL
) {
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
  ts <- gsub("\\.", "", ts)   # rimuove il punto dei millisecondi

  paste0(storage_stream, "_", ts)
}


# Build bronze target directory
.build_bronze_target_dir <- function(config, storage_stream, batch_id) {
  fs::path_norm(
    fs::path(config$local$paths$bronze, storage_stream, batch_id)
  )
}


# Build S3 batch job object
.build_batch_job <- function(
    filename, filepath,
    datastream, storage_stream,
    year, quarter, alt,
    bronze_root, bronze_dir,
    batch_id
) {
  structure(
    list(
      batch_id = batch_id,
      filename = filename,
      filepath = filepath,
      datastream = datastream,
      storage_stream = storage_stream,
      year = year,
      quarter = quarter,
      alt = alt,
      bronze_root = bronze_root,
      bronze_dir = bronze_dir,
      status = "initialized"
    ),
    class = "xacc_batch_job"
  )
}



# Job building (Public API) -----------------------------------------------


#' Create a new Batch Import Job
#'
#' Constructs and validates a batch job context for the ingestion pipeline.
#'
#' The job encapsulates all validated metadata required to import a file
#' into the Bronze layer, including time semantics and alternate storage
#' logic.
#'
#' @param filename Character. File name located in `config$local$paths$inbox`.
#' @param datastream Character. Datastream identifier (e.g. "sdo", "ps").
#' @param year Numeric. Reference year.
#' @param quarter Numeric. Quarter (1–4) if required by the datastream.
#' @param alt Logical. If TRUE, use alternate bronze storage folder.
#' @param config xacc_config. Configuration object returned by `load_options()`.
#' @param batch_id Character. Optional batch identifier.
#'
#' @return An S3 object of class \code{xacc_batch_job}.
#' @export
new_batch_job <- function(
    filename,
    datastream,
    year,
    quarter = NULL,
    alt = FALSE,
    config,
    batch_id = NULL
) {
  .assert_config_for_batch(config)

  ds_config <- .get_datastream_config(config, datastream)
  filepath  <- .resolve_inbox_file(config, filename)

  .assert_year(year)
  quarter <- .normalize_quarter_by_time_block(datastream, ds_config, quarter)

  .assert_alt_flag(alt)
  storage_stream <- .resolve_storage_stream(datastream, ds_config, alt)

  batch_id   <- .normalize_or_generate_batch_id(batch_id)
  bronze_dir <- .build_bronze_target_dir(config, storage_stream, batch_id)

  .build_batch_job(
    filename = filename,
    filepath = filepath,
    datastream = datastream,
    storage_stream = storage_stream,
    year = year,
    quarter = quarter,
    alt = alt,
    bronze_root = config$local$paths$bronze,
    bronze_dir = bronze_dir,
    batch_id = batch_id
  )
}
