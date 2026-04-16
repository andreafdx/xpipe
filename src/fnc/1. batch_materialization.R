
# Job lifecycle -----------------------------------------------------------


#' Assert that a batch job can be materialized
#'
#' Performs Phase A (Pre-materialization Guardrails) checks.
#' This function validates that a batch job is in a safe and coherent
#' state before any irreversible side effects (extraction or disk writes)
#' are performed.
#'
#' Responsibilities:
#' - validate batch status
#' - detect target directory collisions
#' - re-validate input file existence
#'
#' This function must not:
#' - create directories
#' - modify job status
#' - perform extraction
#'
#' @param job An object of class \code{xacc_batch_job}.
#' @param config An object of class \code{xacc_config}.
#'
#' @return Invisibly returns TRUE if the batch is materializable.
#'         Otherwise, aborts with a descriptive error.
#'
#' @keywords internal
#' @noRd
.assert_batch_materializable <- function(job, config) {

  # Basic structural validation of inputs
  if (!inherits(job, "xacc_batch_job")) {
    cli::cli_abort(
      c(
        "Invalid batch job",
        "x" = "{.arg job} must be an object of class {.cls xacc_batch_job}"
      ),
      class = c("batch_job", "materialization")
    )
  }

  if (!inherits(config, "xacc_config")) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "{.arg config} must be an object of class {.cls xacc_config}"
      ),
      class = c("batch_job", "materialization", "config")
    )
  }

  # A1. State precondition
  if (!identical(job$status, "initialized")) {
    cli::cli_abort(
      c(
        "Batch job cannot be materialized",
        "x" = "Invalid batch status: {.val {job$status}}",
        "i" = "Expected status: {.val initialized}"
      ),
      class = c("batch_job", "state")
    )
  }

  # A2. Target collision check
  if (fs::dir_exists(job$bronze_dir)) {
    cli::cli_abort(
      c(
        "Batch job cannot be materialized",
        "x" = "Target bronze directory already exists",
        "i" = "Path: {.file {job$bronze_dir}}",
        "i" = "Batch id: {.val {job$batch_id}}"
      ),
      class = c("batch_job", "collision")
    )
  }

  # A3. Input file re-validation
  if (!fs::file_exists(job$filepath)) {
    cli::cli_abort(
      c(
        "Batch job cannot be materialized",
        "x" = "Input file does not exist at materialization time",
        "i" = "Expected path: {.file {job$filepath}}"
      ),
      class = c("batch_job", "input")
    )
  }

  # Optional lightweight sanity check: file size
  file_info <- fs::file_info(job$filepath)
  if (is.na(file_info$size) || file_info$size == 0) {
    cli::cli_abort(
      c(
        "Batch job cannot be materialized",
        "x" = "Input file is empty or unreadable",
        "i" = "Path: {.file {job$filepath}}"
      ),
      class = c("batch_job", "input")
    )
  }

  invisible(TRUE)
}


#' Resolve extraction instrument for a batch job
#'
#' Performs Phase B of batch materialization.
#' This function selects an appropriate extraction instrument
#' based on the batch job characteristics and configuration.
#'
#' The returned instrument must:
#' - accept a batch job and input path
#' - return data in memory
#'
#' This function must not:
#' - read the input file
#' - write to disk
#' - perform extraction
#'
#' @param job An object of class \code{xacc_batch_job}.
#' @param config An object of class \code{xacc_config}.
#'
#' @return A callable extraction instrument.
#'
#' @keywords internal
#' @noRd
.resolve_extraction_instrument <- function(job, config) {

  # Defensive checks (lightweight, no re-validation of Phase A)
  if (!inherits(job, "xacc_batch_job")) {
    cli::cli_abort(
      c(
        "Invalid batch job",
        "x" = "Expected an {.cls xacc_batch_job}"
      ),
      class = c("batch_job", "instrument")
    )
  }

  datastream <- job$datastream

  # Placeholder mapping (to be expanded later)
  # At this stage we only declare intent, not implementation
  instrument <- switch(
    datastream,
    "sdo" = extract_sdo,
    "ps"  = extract_ps,
    NULL
  )

  if (is.null(instrument)) {
    cli::cli_abort(
      c(
        "No extraction instrument available",
        "x" = "No extractor registered for datastream {.val {datastream}}"
      ),
      class = c("batch_job", "instrument")
    )
  }

  instrument
}


#' Run extraction instrument and load data into memory
#'
#' Performs Phase C of batch materialization.
#'
#' This function executes the selected extraction instrument and
#' validates that the returned data conforms to the extraction contract.
#'
#' The extraction instrument is expected to:
#' - accept a batch job and an input file path
#' - return data fully loaded in memory
#' - perform no disk writes
#'
#' @param job An object of class \code{xacc_batch_job}.
#' @param instrument A callable extraction instrument.
#'
#' @return Extracted data loaded in memory.
#'
#' @keywords internal
#' @noRd
.run_extraction <- function(job, instrument) {

  if (!inherits(job, "xacc_batch_job")) {
    cli::cli_abort(
      c(
        "Invalid batch job",
        "x" = "Expected an {.cls xacc_batch_job}"
      ),
      class = c("batch_job", "extraction")
    )
  }

  if (!is.function(instrument)) {
    cli::cli_abort(
      c(
        "Invalid extraction instrument",
        "x" = "Extraction instrument must be callable"
      ),
      class = c("batch_job", "extraction", "instrument")
    )
  }

  extracted_data <- instrument(job, job$filepath)

  if (is.null(extracted_data)) {
    cli::cli_abort(
      c(
        "Extraction failed",
        "x" = "Extraction instrument returned NULL"
      ),
      class = c("batch_job", "extraction")
    )
  }

  if (is.data.frame(extracted_data)) {
    extracted_data <- list(data = extracted_data)
  }

  if (!is.list(extracted_data) || length(extracted_data) == 0) {
    cli::cli_abort(
      c(
        "Invalid extraction result",
        "x" = "Extraction must return a non-empty list of tables"
      ),
      class = c("batch_job", "extraction")
    )
  }

  extracted_data
}


#' Persist extracted data to the Bronze layer
#'
#' Performs Phase D of batch materialization.
#'
#' This function is responsible for:
#' - creating the bronze target directory
#' - persisting extracted in-memory data to disk
#' - writing minimal batch metadata
#'
#' It assumes that:
#' - Phase A, B, and C have already succeeded
#' - extracted_data is valid and non-empty
#'
#' @param job An object of class \code{xacc_batch_job}.
#' @param extracted_data A named list of in-memory tables.
#'
#' @return Invisibly returns TRUE if persistence succeeds.
#'
#' @keywords internal
#' @noRd
.persist_to_bronze <- function(job, extracted_data) {

  if (!inherits(job, "xacc_batch_job")) {
    cli::cli_abort(
      c(
        "Invalid batch job",
        "x" = "Expected an {.cls xacc_batch_job}"
      ),
      class = c("batch_job", "materialization")
    )
  }

  if (!is.list(extracted_data) || length(extracted_data) == 0) {
    cli::cli_abort(
      c(
        "Invalid extracted data",
        "x" = "Expected a non-empty list of extracted tables"
      ),
      class = c("batch_job", "materialization", "data")
    )
  }

  # Create bronze directory
  fs::dir_create(job$bronze_dir)

  # Persist each extracted table
  for (name in names(extracted_data)) {
    table <- extracted_data[[name]]

    if (!is.data.frame(table)) {
      cli::cli_abort(
        c(
          "Invalid extracted table",
          "x" = "Each extracted element must be a data.frame",
          "i" = "Table name: {.val {name}}"
        ),
        class = c("batch_job", "materialization", "data")
      )
    }

    # Placeholder persistence strategy
    # Concrete format (csv, parquet, etc.) will be defined later
    output_path <- fs::path(job$bronze_dir, paste0(name, ".rds"))
    saveRDS(table, output_path)
  }

  # Write minimal batch metadata
  metadata <- list(
    batch_id    = job$batch_id,
    datastream  = job$datastream,
    storage     = job$storage_stream,
    created_at  = Sys.time()
  )

  saveRDS(metadata, fs::path(job$bronze_dir, "_batch_metadata.rds"))

  invisible(TRUE)
}

# Materialize  ------------------------------------------------------------


#' Materialize a batch job into the Bronze layer
#'
#' Orchestrates the execution of a batch job according to the
#' materialization lifecycle.
#'
#' This function is responsible for:
#' - enforcing pre-materialization guardrails (Phase A)
#' - coordinating extraction and persistence steps
#' - managing batch state transitions
#'
#' At this stage, only Phase A and state transitions are implemented.
#' Extraction and persistence are intentionally left as placeholders.
#'
#' @param job An object of class \code{xacc_batch_job}.
#' @param config An object of class \code{xacc_config}.
#'
#' @return An updated \code{xacc_batch_job}.
#' @export
materialize_batch_job <- function(job, config) {

  # Phase A: Pre-materialization guardrails
  .assert_batch_materializable(job, config)

  # Transition to execution state
  job$status <- "materializing"

  # Phase B: Instrument resolution
  # Placeholder: resolve input descriptor and select extraction instrument

  # Phase C: Extraction
  # Placeholder: run extraction instrument and load data into memory

  # Phase D: Bronze materialization
  # Placeholder: create directories and persist extracted data

  # Finalize job
  job$status <- "materialized"

  job
}
