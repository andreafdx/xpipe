box::use(
  fs,
  cli
)

#' Create a new Batch Import Job
#'
#' Constructs and strictly validates a context object for the
#' ingestion pipeline. It enforces the datastream business rules
#' defined in the YAML configuration.
#'
#' @param filename Character. The name of the file (searched in config$paths$inbox).
#' @param datastream Character. The datastream ID (e.g., 'sdo', 'ps').
#' @param year Numeric. The reference year.
#' @param quarter Numeric. The quarter (1-4). Optional depending on datastream time_block.
#' @param alt Logical. Specify if it is an alternative datastream version.
#' @param config List. The global configuration object.
#'
#' @return An S3 object of class \code{xacc_batch_job}.
#' @export
new_batch_job <- function(
  filename,
  datastream,
  year,
  quarter = NULL,
  alt = FALSE,
  config
) {
  # 1. Config Validation
  if (
    missing(config) ||
      !inherits(config, "xacc_config") ||
      is.null(config$bronze$datastream)
  ) {
    cli::cli_abort(
      "A valid {.arg config} object loaded via {.code .load_options()} is required.",
      class = c("batch_job", "config")
    )
  }

  # 2. Datastream basics
  if (!is.character(datastream) || length(datastream) != 1) {
    cli::cli_abort(
      "{.arg datastream} must be a single string.",
      class = c("batch_job", "datastream")
    )
  }

  if (!(datastream %in% names(config$bronze$datastream))) {
    cli::cli_abort(
      c(
        "Invalid datastream: {.val {datastream}}",
        "i" = "Available datastreams are: {.str {names(config$bronze$datastream)}}"
      ),
      class = c("batch_job", "datastream")
    )
  }

  ds_config <- config$bronze$datastream[[datastream]]

  # 3. Filename & Path Resolution
  if (!is.character(filename) || length(filename) != 1 || filename == "") {
    cli::cli_abort(
      "{.arg filename} must be a non-empty string.",
      class = c("batch_job", "filename")
    )
  }

  full_path <- fs::path(config$local$paths$inbox, filename)
  if (!fs::file_exists(full_path)) {
    cli::cli_abort(
      "The input file {.file {filename}} was not found in {.file {config$local$paths$inbox}}.",
      class = c("batch_job", "filename")
    )
  }

  # 4. Year Validation
  if (!is.numeric(year) || length(year) != 1) {
    cli::cli_abort(
      "{.arg year} must be a numeric value (e.g., 2025).",
      class = c("batch_job", "year")
    )
  }

  # 5. Quarter Validation based on time_block
  if (ds_config$time_block == "q") {
    if (
      is.null(quarter) ||
        !is.numeric(quarter) ||
        length(quarter) != 1 ||
        !(quarter %in% 1:4)
    ) {
      cli::cli_abort(
        c(
          "Datastream {.val {datastream}} has time block 'q'.",
          "x" = "{.arg quarter} must be provided as a number between 1 and 4."
        ),
        class = c("batch_job", "quarter")
      )
    }
  } else if (ds_config$time_block == "y") {
    if (!is.null(quarter)) {
      cli::cli_alert_warning(
        "Datastream {.val {datastream}} has time block 'y'. {.arg quarter} will be ignored.",
        class = c("batch_job", "quarter")
      )
      quarter <- NULL # Force it to NULL since it's yearly
    }
  }

  # 6. Alt Validation based on yaml alt definition
  if (!is.logical(alt) || length(alt) != 1 || is.na(alt)) {
    cli::cli_abort(
      "{.arg alt} must be TRUE or FALSE.",
      class = c("batch_job", "alt")
    )
  }

  if (alt == TRUE && !isTRUE(ds_config$alt)) {
    cli::cli_abort(
      c(
        "Datastream {.val {datastream}} does not support alternative versions.",
        "x" = "Set {.code alt = FALSE} or fix the configuration."
      ),
      class = c("batch_job", "alt")
    )
  }

  # 7. Build the S3 object
  job <- structure(
    list(
      filename = filename,
      filepath = fs::path_norm(full_path),
      datastream = datastream,
      year = year,
      quarter = quarter,
      alt = alt,
      status = "initialized"
    ),
    class = "xacc_batch_job"
  )

  return(job)
}
