box::use(
  fs,
  cli,
  jsonlite,
  arrow,
  #./crypto[apply_privacy_rules]
)

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

#' Assert that batch materialization is safe
#'
#' Performs Phase A (Materialization Guardrails) checks.
#' Validates that the ingestion context is coherent and that
#' filesystem preconditions are met before any side effects occur.
#'
#' @param ctx Ingestion context list.
#' @param config xpipe_config object.
#' @return Invisibly TRUE if materializable, otherwise aborts.
#' @keywords internal
#' @noRd
.assert_batch_materializable <- function(ctx, config) {

  if (!is.list(ctx)) {
    cli::cli_abort(
      c(
        "Invalid ingestion context",
        "x" = "{.arg ctx} must be a list"
      ),
      class = c("batch_job", "materialization")
    )
  }

  if (!inherits(config, "xpipe_config")) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "{.arg config} must be an object of class {.cls xpipe_config}"
      ),
      class = c("batch_job", "materialization", "config")
    )
  }

  # A1. Target collision check (batch layer)
  if (fs::dir_exists(ctx$batch_dir)) {
    cli::cli_abort(
      c(
        "Ingestion cannot proceed",
        "x" = "Target batch directory already exists",
        "i" = "Path: {.file {ctx$batch_dir}}",
        "i" = "Batch id: {.val {ctx$batch_id}}"
      ),
      class = c("batch_job", "collision")
    )
  }

  # A2. Input path re-validation
  if (!fs::file_exists(ctx$filepath)) {
    cli::cli_abort(
      c(
        "Ingestion cannot proceed",
        "x" = "Input path does not exist at materialization time",
        "i" = "Expected path: {.file {ctx$filepath}}"
      ),
      class = c("batch_job", "input")
    )
  }

  # Lightweight sanity check
  info <- fs::file_info(ctx$filepath)
  if (is.na(info$size) || (fs::is_file(ctx$filepath) && info$size == 0)) {
    cli::cli_abort(
      c(
        "Ingestion cannot proceed",
        "x" = "Input is empty or unreadable",
        "i" = "Path: {.file {ctx$filepath}}"
      ),
      class = c("batch_job", "input")
    )
  }

  invisible(TRUE)
}

## Phase B --------------------------------------------------------------

#' Resolve extraction instrument
#'
#' @keywords internal
#' @noRd
.resolve_extraction_instrument <- function(ctx, config) {

  method_type <- ctx$method_config$type

  instrument <- switch(
    method_type,
    "access_mdb" = extract_access_db,
    "xml"       = extract_xml,
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
.run_extraction <- function(ctx, instrument) {

  if (!is.null(ctx$components)) {
    # Multi-component extraction (Directory based)
    cli$cli_alert_info("Running multi-component extraction ({length(ctx$components)} files)")

    extracted <- list()
    for (nm in names(ctx$components)) {
      path <- ctx$components[[nm]]
      cli$cli_inform("Component {.val {nm}} : {.file {basename(path)}}")

      # Call instrument for each component
      res <- instrument(ctx, path)

      # If instrument returns a list (unlikely for single component but possible), merge
      if (is.data.frame(res)) {
        extracted[[nm]] <- res
      } else if (is.list(res)) {
        # Prefix keys to avoid name collisions if multiple files return same table names
        names(res) <- paste0(nm, "_", names(res))
        extracted <- c(extracted, res)
      }
    }
  } else {
    # Single-file extraction
    extracted <- instrument(ctx, ctx$filepath)
  }

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
#' @keywords internal
#' @noRd
.persist_to_batch <- function(ctx, extracted_data, config) {

  fs::dir_create(ctx$batch_dir, recurse = TRUE)

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

    arrow::write_parquet(
      tbl,
      fs::path(ctx$batch_dir, paste0(nm, ".parquet"))
    )
  }

  # Meta file as JSON for cross-platform compatibility
  meta <- list(
    batch_id = ctx$batch_id,

    stream = list(
      id            = ctx$stream_id,
      schema_domain = ctx$method_config$schema_domain,
      anchor        = ctx$stream_config$anchor
    ),

    method = list(
      id   = ctx$method_id,
      type = ctx$method_config$type
    ),

    input = list(
      path       = ctx$filename,
      input_type = ctx$method_config$input_type
    ),

    execution = list(
      created_at  = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
      tool       = config$runtime$tool$name,
      tool_version = config$runtime$tool$version
    )
  )
  if (!is.null(ctx$method_config$components)) {
    meta$components <- ctx$method_config$components
  }


  jsonlite::write_json(
    meta,
    fs::path(ctx$batch_dir, "_batch_metadata.json"),
    pretty = TRUE,
    auto_unbox = TRUE
  )

  invisible(TRUE)
}

# Public API -------------------------------------------------------------

#' Materialize Batch Ingestion Context
#'
#' Transforms a validated ingestion context into an immutable, on-disk
#' batch representation.
#'
#' @param ctx Ingestion context list.
#' @param config xpipe_config object.
#' @return Invisibly TRUE on success.
#' @export
materialize_batch <- function(ctx, config) {

  .assert_batch_materializable(ctx, config)

  instrument     <- .resolve_extraction_instrument(ctx, config)
  extracted_data <- .run_extraction(ctx, instrument)

  # Apply privacy rules to each extracted table
  for (nm in names(extracted_data)) {
    extracted_data[[nm]] <- apply_privacy_rules(
      extracted_data[[nm]],
      ctx$stream_config,
      config$runtime$pepper
    )
  }
  .persist_to_batch(ctx, extracted_data, config)

  invisible(TRUE)
}

#' Ingest a Data Batch
#'
#' High-level entry point for batch ingestion. Performs both preparation
#' and materialization of a data batch.
#'
#' @param filename Character scalar. Input name.
#' @param stream Character scalar identifying the target stream.
#' @param method Character scalar identifying the ingestion method.
#' @param config xpipe_config object.
#' @param batch_id Optional explicit batch identifier.
#'
#' @return Character scalar batch identifier.
#' @export
ingest_batch <- function(
    filename,
    stream,
    method,
    config,
    batch_id = NULL
) {
  ctx <- prepare_batch_ingestion(
    filename = filename,
    stream   = stream,
    method   = method,
    config   = config,
    batch_id = batch_id
  )

  materialize_batch(ctx, config)

  invisible(ctx$batch_id)
}





