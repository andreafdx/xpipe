
# Batch materialization pipeline ------------------------------------------
#
# Conceptual phases:
#   Phase A – Pre‑materialization guardrails
#   Phase B – Extraction instrument resolution
#   Phase C – Data extraction (in‑memory)
#   Phase D – Batch persistence (canonical output)
#
# Only Phase A is implemented as a standalone conceptual function.
# Phases B–D are sequential pipeline steps used exclusively by
# `materialize_batch_job()`.




## Phase A ----------------------------------------------------------------

#' Assert that a batch job can be materialized
#'
#' Performs Phase A (Pre-materialization Guardrails) checks.
#' Validates that a batch job is in a safe and coherent state
#' before any irreversible side effects are performed.
#'
#' Responsibilities:
#' - validate batch status
#' - detect target directory collisions (batch layer)
#' - re-validate input file existence
#'
#' @param job An object of class \code{xacc_batch_job}.
#' @param config An object of class \code{xacc_config}.
#' @return Invisibly TRUE if materializable, otherwise aborts.
#' @keywords internal
#' @noRd
.assert_batch_materializable <- function(job, config) {

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

  # A2. Target collision check (batch layer)
  if (fs::dir_exists(job$batch_dir)) {
    cli::cli_abort(
      c(
        "Batch job cannot be materialized",
        "x" = "Target batch directory already exists",
        "i" = "Path: {.file {job$batch_dir}}",
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

  # Lightweight sanity check
  info <- fs::file_info(job$filepath)
  if (is.na(info$size) || info$size == 0) {
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

## Phase B --------------------------------------------------------------

#' Resolve extraction instrument for a batch job
#'
#' Selects the extractor responsible for producing
#' the canonical batch representation.
#'
#' @keywords internal
#' @noRd
.resolve_extraction_instrument <- function(job, config) {

  method_type <- job$method_config$type

  instrument <- switch(
    method_type,
    "access_db" = extract_access_db,
    "xml"       = extract_xml,
    "csv"       = extract_csv,
    NULL
  )

  if (is.null(instrument)) {
    cli::cli_abort(
      c(
        "No extraction instrument available",
        "x" = "No extractor registered for method type {.val {method_type}}"
      ),
      class = c("batch_job", "instrument")
    )
  }

  instrument
}

## Phase C --------------------------------------------------------------

#' Run extraction and load batch data into memory
#'
#' @keywords internal
#' @noRd
.run_extraction <- function(job, instrument) {

  extracted <- instrument(job, job$filepath)

  if (is.data.frame(extracted)) {
    extracted <- list(data = extracted)
  }

  if (!is.list(extracted) || length(extracted) == 0) {
    cli::cli_abort(
      c(
        "Invalid extraction result",
        "x" = "Extractor must return a non-empty list of data frames"
      ),
      class = c("batch_job", "extraction")
    )
  }

  extracted
}

## Phase D --------------------------------------------------------------

#' Persist extracted data to the Batch layer
#'
#' Writes the canonical, immutable batch representation.
#'
#' @keywords internal
#' @noRd
.persist_to_batch <- function(job, extracted_data) {

  fs::dir_create(job$batch_dir, recurse = TRUE)

  for (nm in names(extracted_data)) {
    tbl <- extracted_data[[nm]]

    if (!is.data.frame(tbl)) {
      cli::cli_abort(
        c(
          "Invalid extracted object",
          "x" = "All extracted elements must be data.frames",
          "i" = "Element: {.val {nm}}"
        ),
        class = c("batch_job", "materialization")
      )
    }

    # Fallback to RDS if arrow is not available
    if (requireNamespace("arrow", quietly = TRUE)) {
      arrow::write_parquet(
        tbl, 
        fs::path(job$batch_dir, paste0(nm, ".parquet"))
      )
    } else {
      cli::cli_alert_warning("Package {.pkg arrow} not found. Falling back to RDS.")
      saveRDS(
        tbl, 
        fs::path(job$batch_dir, paste0(nm, ".rds"))
      )
    }
  }

  # Meta file as JSON for cross-platform compatibility
  meta <- list(
    batch_id   = job$batch_id,
    stream_id  = job$stream_id,
    method_id  = job$method_id,
    alt        = job$alt,
    anchor     = job$stream_config$anchor,
    created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")
  )
  
  jsonlite::write_json(
    meta, 
    fs::path(job$batch_dir, "_batch_metadata.json"),
    pretty = TRUE,
    auto_unbox = TRUE
  )

  invisible(TRUE)
}

# Public API -------------------------------------------------------------

#' Materialize a batch job
#'
#' Executes the full batch materialization lifecycle:
#' guardrails → extraction → privacy → batch persistence.
#'
#' @export
materialize_batch_job <- function(job, config) {

  .assert_batch_materializable(job, config)

  job$status <- "materializing"

  instrument     <- .resolve_extraction_instrument(job, config)
  extracted_data <- .run_extraction(job, instrument)

  # Apply privacy rules to each extracted table
  extracted_data <- lapply(extracted_data, function(df) {
    apply_privacy_rules(
      df, 
      job$stream_config, 
      config$runtime$pepper
    )
  })

  .persist_to_batch(job, extracted_data)

  job$status <- "materialized"
  job
}
