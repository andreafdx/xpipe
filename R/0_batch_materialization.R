# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# 0. batch_materialization.R
#
# High-level pipeline for batch ingestion.
#
# Approach: Handles preparation, human-readable recaps, and execution
# (materialization) of batch extraction. Uses the method configuration
# to determine the extraction instrument and apply privacy rules.
#
# Public API:  ingest_batch()
# Internals:   .assert_config_for_batch(), .print_ingestion_recap(),
#              .confirm_ingestion(), .get_method_config(), .get_stream_config(),
#              .resolve_inbox_path(), .validate_input_type(),
#              .discover_components(), .normalize_or_generate_batch_id(),
#              .build_batch_target_dir(), .prepare_batch_ingestion(),
#              .assert_batch_materializable(), .resolve_extraction_instrument(),
#              .run_extraction(), .persist_to_batch(), .materialize_batch()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Public API --------------------------------------------------------------

#' Ingest a Data Batch
#'
#' High-level, irreversible operation that converts an inbox input
#' into an immutable Batch artifact.
#'
#' @description
#' \code{ingest_batch()} performs a complete batch ingestion.
#' The operation runs in three logical steps:
#' 1. Preparation (validation and resolution)
#' 2. Recap (human-readable intent summary)
#' 3. Materialization (irreversible)
#'
#' During preparation, configuration, input paths, and method/stream
#' compatibility are fully validated. During materialization, data is
#' extracted, privacy rules are applied, and the canonical batch
#' representation is persisted to disk.
#'
#' In interactive sessions, a recap and confirmation step is shown
#' after preparation and before materialization.
#'
#' @section Phases:
#' \itemize{
#'   \item \strong{Preparation}: validation and resolution only; no I/O
#'   \item \strong{Materialization}: extraction and persistence (irreversible)
#' }
#'
#' @section Immutability:
#' Once materialized, a batch is considered immutable. Re-ingestion of
#' the same input will create a new batch with a new batch identifier.
#'
#' @section Inspection:
#' After ingestion, batch contents and metadata can be inspected via
#' the Batch layer filesystem and inspection helpers.
#'
#' @param filename Character scalar. Name of a file or directory located in the inbox.
#' @param stream Character scalar. Target stream identifier.
#' @param method Character scalar. Ingestion method identifier.
#' @param config An \code{xpipe_config} object loaded via \code{load_options()}.
#' @param batch_id Optional explicit batch identifier.
#' @param confirm Logical; whether to ask for confirmation. Defaults to \code{interactive()}.
#' @param dry_run Logical; if TRUE, performs preparation and recap only.
#'
#' @return Character scalar. The generated batch identifier.
#'
#' @details
#' This function performs irreversible filesystem side effects.
#' It is recommended to validate inputs and configuration before use.
#'
#' @export
ingest_batch <- function(
    filename,
    stream,
    method,
    config,
    batch_id = NULL,
    confirm = interactive(),
    dry_run = FALSE
) {
  ctx <- .prepare_batch_ingestion(
    filename = filename,
    stream   = stream,
    method   = method,
    config   = config,
    batch_id = batch_id
  )

  .print_ingestion_recap(ctx, action = "Batch ingestion")

  if (isTRUE(dry_run)) {
    cli::cli_alert_info(
      "Dry run complete. No files were written and no state was changed."
    )
    return(invisible(ctx$batch_id))
  }

  .confirm_ingestion(confirm = confirm)

  .materialize_batch(ctx, config)

  invisible(ctx$batch_id)
}


# Batch initialization scripts --------------------------------------------

## Helper functions --------------------------------------------------------

#' Assert configuration validity for batch creation
#'
#' Ensures that a valid \code{xpipe_config} object is provided and that
#' all required branches (local paths, streams, methods) are present.
#'
#' @param config An object of class \code{xpipe_config}.
#' @return Invisibly returns TRUE if valid, otherwise aborts.
#' @keywords internal
#' @noRd
.assert_config_for_batch <- function(config) {
  if (missing(config) || !inherits(config, "xpipe_config")) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "A valid {.arg config} object loaded via {.code load_options()} is required"
      ),
      class = c("batch", "config")
    )
  }

  required_paths <- c("inbox", "batch")
  missing_paths <- setdiff(required_paths, names(config$local$paths))

  if (length(missing_paths) > 0) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "Missing required paths in config: {.val {missing_paths}}"
      ),
      class = c("batch", "config", "paths")
    )
  }

  if (is.null(config$streams) || is.null(config$methods)) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "Streams or Methods options not loaded"
      ),
      class = c("batch", "config", "metadata")
    )
  }

  invisible(TRUE)
}


#' Print ingestion recap
#'
#' Prints a standardized recap of an ingestion intent before
#' an irreversible operation is performed.
#'
#' @param ctx Ingestion context list.
#' @param action Character scalar describing the action (e.g. "Batch ingestion").
#'
#' @keywords internal
#' @noRd
.print_ingestion_recap <- function(ctx, action = "Ingestion") {

  cli::cli_h2("{action} recap")

  cli::cli_text(
    "The following input will be processed and materialized as an immutable artifact."
  )

  cli::cli_h3("Input")
  cli::cli_bullets(c(
    "Path   : {.file {ctx$filepath}}",
    "Stream : {.val {ctx$stream_id}}",
    "Method : {.val {ctx$method_id}}"
  ))

  if (!is.null(ctx$components)) {
    cli::cli_h3("Detected components")
    cli::cli_bullets(
      purrr::imap_chr(
        ctx$components,
        ~ paste0("{.strong ", .y, "} : {.file ", basename(.x), "}")
      )
    )
  }

  cli::cli_h3("Target")
  cli::cli_bullets(c(
    "Batch ID        : {.val {ctx$batch_id}}",
    "Batch directory : {.file {ctx$batch_dir}}"
  ))

  cli::cli_alert_warning(
    "This operation is irreversible once materialization starts."
  )

  invisible(TRUE)
}

#' Confirm irreversible ingestion
#'
#' @param confirm Logical; whether confirmation is required.
#'
#' @return Invisibly TRUE if confirmed, otherwise aborts.
#'
#' @keywords internal
#' @noRd
.confirm_ingestion <- function(confirm = TRUE) {

  if (!isTRUE(confirm)) {
    return(invisible(TRUE))
  }

  # Try climenu first, fall back cleanly if unsupported
  if (requireNamespace("climenu", quietly = TRUE)) {

    choice <- tryCatch(
      climenu::select(
        c("Yes, continue", "No, abort"),
        prompt = "Proceed with materialization?"
      ),
      error = function(e) NULL
    )

    if (!is.null(choice)) {
      if (choice != "Yes, continue") {
        cli::cli_abort(
          "Batch ingestion aborted by user.",
          class = "batch_abort"
        )
      }
      return(invisible(TRUE))
    }
  }

  # Fallback: readline (always works)
  answer <- readline("Proceed with materialization? [y/N]: ")

  if (!nzchar(answer) || tolower(substr(answer, 1, 1)) != "y") {
    cli::cli_abort(
      "Batch ingestion aborted by user.",
      class = "batch_abort"
    )
  }

  invisible(TRUE)
}



## Method and Stream validation --------------------------------------------

#' Retrieve method configuration
#'
#' @param config xpipe_config object.
#' @param method_id Character scalar.
#' @return A list with the method configuration.
#' @keywords internal
#' @noRd
.get_method_config <- function(config, method_id) {
  if (!is.character(method_id) || length(method_id) != 1 || !nzchar(method_id)) {
    cli::cli_abort(
      c(
        "Invalid method",
        "x" = "{.arg method_id} must be a non-empty string"
      ),
      class = c("batch", "method")
    )
  }

  available <- names(config$methods)
  if (!(method_id %in% available)) {
    cli::cli_abort(
      c(
        "Invalid method",
        "x" = "Unknown method: {.val {method_id}}",
        "i" = "Available methods: {.str {available}}"
      ),
      class = c("batch", "method")
    )
  }

  config$methods[[method_id]]
}

#' Retrieve stream configuration
#'
#' @param config xpipe_config object.
#' @param stream_id Character scalar.
#' @return A list with the stream configuration.
#' @keywords internal
#' @noRd
.get_stream_config <- function(config, stream_id) {
  available <- names(config$streams)
  if (!(stream_id %in% available)) {
    cli::cli_abort(
      c(
        "Invalid stream",
        "x" = "Unknown stream: {.val {stream_id}}",
        "i" = "Available streams: {.str {available}}"
      ),
      class = c("batch", "stream")
    )
  }

  config$streams[[stream_id]]
}

### Inbox ------------------------------------------------------------------

#' Resolve input path from inbox
#'
#' @param config xpipe_config object.
#' @param path Character scalar.
#' @return Normalized absolute path.
#' @keywords internal
#' @noRd
.resolve_inbox_path <- function(config, path) {
  if (!is.character(path) || length(path) != 1 || !nzchar(path)) {
    cli::cli_abort(
      c(
        "Invalid path",
        "x" = "{.arg path} must be a non-empty string"
      ),
      class = c("batch", "path")
    )
  }

  full_path <- fs::path(config$local$paths$inbox, path)
  if (!fs::file_exists(full_path)) {
    cli::cli_abort(
      c(
        "Input path not found",
        "x" = "Path {.file {path}} was not found in inbox",
        "i" = "Inbox: {.file {config$local$paths$inbox}}"
      ),
      class = c("batch", "path")
    )
  }

  fs::path_norm(full_path)
}

#' Validate input type against method requirement
#'
#' @keywords internal
#' @noRd
.validate_input_type <- function(filepath, method_config) {
  required_type <- method_config$input_type
  actual_is_dir <- fs::is_dir(filepath)

  if (required_type == "file" && actual_is_dir) {
    cli::cli_abort(
      c(
        "Invalid input type",
        "x" = "Selected method requires a file, but a directory was provided.",
        "i" = "Path: {.file {filepath}}"
      ),
      class = c("batch", "input_type")
    )
  }

  if (required_type == "directory" && !actual_is_dir) {
    cli::cli_abort(
      c(
        "Invalid input type",
        "x" = "Method {.val {method_config$method_id}} requires a directory, but a file was provided.",
        "i" = "Path: {.file {filepath}}"
      ),
      class = c("batch", "input_type")
    )
  }
}

#' Discover and validate method components in a directory
#'
#' @keywords internal
#' @noRd
.discover_components <- function(dir_path, method_config) {
  components <- method_config$components
  if (is.null(components)) return(NULL)

  resolved <- list()

  for (nm in names(components)) {
    pattern <- components[[nm]]
    matches <- fs::dir_ls(dir_path, glob = pattern)

    if (length(matches) == 0) {
      cli::cli_abort(
        c(
          "Missing component",
          "x" = "Could not find file for component {.val {nm}}",
          "i" = "Pattern: {.val {pattern}}",
          "i" = "Directory: {.file {dir_path}}"
        ),
        class = c("batch", "components")
      )
    }

    if (length(matches) > 1) {
      cli::cli_abort(
        c(
          "Ambiguous component",
          "x" = "Multiple files found for component {.val {nm}}",
          "i" = "Pattern: {.val {pattern}}",
          "i" = "Found: {.file {basename(matches)}}"
        ),
        class = c("batch", "components")
      )
    }

    resolved[[nm]] <- as.character(matches)
  }

  resolved
}

### Batch id & storage -----------------------------------------------------

#' Normalize or Generate Batch Identifier
#'
#' Validates an explicit batch identifier or generates a unique
#' stream-scoped batch ID when none is provided.
#'
#' @param stream_id Character scalar identifying the stream.
#' @param method_id Character scalar identifying the method.
#' @param batch_id Optional character scalar. Explicit batch ID.
#'
#' @return Character scalar batch identifier.
#'
#' @noRd
.normalize_or_generate_batch_id <- function(stream_id, method_id, batch_id = NULL) {
  if (!is.null(batch_id)) {
    if (!is.character(batch_id) || length(batch_id) != 1 || !nzchar(batch_id)) {
      cli::cli_abort(
        c(
          "Invalid batch_id",
          "x" = "{.arg batch_id} must be a non-empty string"
        ),
        class = c("batch", "batch_id")
      )
    }
    return(batch_id)
  }

  ts <- format(Sys.time(), "%Y%m%dT%H%M%OS3")

  paste0(ts, "_" ,stream_id, "_", method_id)
}

#' Build Batch Target Directory Path
#'
#' Constructs the normalized filesystem path for a batch within
#' the Batch layer, based on stream and batch identifiers.
#'
#' @param config xpipe_config object.
#' @param batch_id Character scalar batch identifier.
#'
#' @return Normalized filesystem path to the batch directory.
#'
#' @noRd
.build_batch_target_dir <- function(config, batch_id) {
  fs::path_norm(
    fs::path(config$local$paths$batch, batch_id)
  )
}

## Internal API -------------------------------------------------------------

#' Prepare Batch Ingestion Context
#'
#' Constructs a validated batch ingestion context based on an input file
#' or directory located in the inbox and a configured ingestion method.
#'
#' This function performs configuration validation, input resolution,
#' and method/stream compatibility checks, but does not read, transform,
#' or write any data. The returned list represents a fully specified
#' ingestion intent ready for materialization.
#'
#' @param filename Character scalar. Name of a file or directory located
#'   in the inbox path defined in the local configuration.
#' @param stream Character scalar identifying the target stream.
#' @param method Character scalar identifying the ingestion method to use,
#'   as defined in \code{methods.json}.
#' @param config An object of class \code{xpipe_config}, as returned by
#'   \code{load_options()}.
#' @param batch_id Optional character scalar. Explicit batch identifier.
#'   If \code{NULL}, a unique batch identifier is generated automatically.
#'
#' @return A named list containing the ingestion context.
#'
#' @details
#' The context list encapsulates all metadata required for batch
#' materialization, including resolved input paths, method and stream
#' configuration, and target batch directory.
#'
#' No filesystem side effects are performed beyond path validation.
#' Data extraction and persistence occur only during
#' \code{materialize_batch()}.
#'
#' @keywords internal
.prepare_batch_ingestion <- function(
    filename,
    stream,
    method,
    config,
    batch_id = NULL
){
  .assert_config_for_batch(config)

  method_config <- .get_method_config(config, method)
  stream_config <- .get_stream_config(config, stream)
  stream_id     <- stream

  if (method_config$schema_domain != stream_config$schema_domain) {
    cli::cli_abort(
      c(
        "Invalid batch job",
        "x" = "Method and stream belong to different schema domains",
        "i" = "Method domain: {.val {method_config$schema_domain}}",
        "i" = "Stream domain: {.val {stream_config$schema_domain}}"
      ),
      class = c("batch", "schema_domain")
    )
  }

  filepath  <- .resolve_inbox_path(config, filename)

  # Validation against method requirement
  .validate_input_type(filepath, method_config)

  # Discover components if it's a directory
  components <- if (fs::is_dir(filepath)) {
    .discover_components(filepath, method_config)
  } else {
    NULL
  }

  batch_id  <- .normalize_or_generate_batch_id(stream_id, method, batch_id)
  batch_dir <- .build_batch_target_dir(config, batch_id)

  list(
    batch_id      = batch_id,
    filename      = filename,
    filepath      = filepath,
    method_id     = method,
    method_config = method_config,
    stream_id     = stream_id,
    stream_config = stream_config,
    batch_dir     = batch_dir,
    components    = components
  )
}

# Batch materialization pipeline ------------------------------------------
#
# Conceptual phases:
#   Phase A – Pre-materialization guardrails
#   Phase B – Extraction instrument resolution
#   Phase C – Data extraction (in-memory)
#   Phase D – Batch persistence (canonical output)
#
# Only Phase A is implemented as a standalone conceptual function.
# Phases B-D are sequential pipeline steps used exclusively by
# `materialize_batch()`.

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
      class = c("batch", "materialization")
    )
  }

  if (!inherits(config, "xpipe_config")) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "{.arg config} must be an object of class {.cls xpipe_config}"
      ),
      class = c("batch", "materialization", "config")
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
      class = c("batch", "collision")
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
      class = c("batch", "input")
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
      class = c("batch", "input")
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

  # Registry: method type -> extractor function name (string)
  # Add new extractors here; the function must be loaded before ingest_batch() is called.
  .instrument_registry <- c(
    "access_mdb" = "extract_access_db",
    "xml"        = "extract_xml"
  )

  method_type <- ctx$method_config$type

  fn_name <- .instrument_registry[method_type]

  if (is.na(fn_name)) {
    cli::cli_abort(
      c(
        "No extraction instrument registered",
        "x" = "No extractor registered for method type {.val {method_type}}",
        "i" = "Registered types: {.val {names(.instrument_registry)}}"
      ),
      class = c("batch", "instrument")
    )
  }

  if (!exists(fn_name, mode = "function")) {
    cli::cli_abort(
      c(
        "Extraction instrument not loaded",
        "x" = "Function {.code {fn_name}} is not available in the current environment",
        "i" = "Source the appropriate tool script before calling {.code ingest_batch()}"
      ),
      class = c("batch", "instrument")
    )
  }

  get(fn_name, mode = "function")
}

## Phase C --------------------------------------------------------------

#' Run extraction and load batch data into memory
#'
#' @keywords internal
#' @noRd
.run_extraction <- function(ctx, instrument) {

  if (!is.null(ctx$components)) {
    # Multi-component extraction (Directory based)
    cli::cli_alert_info("Running multi-component extraction ({length(ctx$components)} files)")

    extracted <- list()
    for (nm in names(ctx$components)) {
      path <- ctx$components[[nm]]
      cli::cli_inform("Component {.val {nm}} : {.file {basename(path)}}")

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
      class = c("batch", "extraction")
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
        class = c("batch", "materialization")
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

## Internal API -------------------------------------------------------------

#' Materialize Batch Ingestion Context
#'
#' Transforms a validated ingestion context into an immutable, on-disk
#' batch representation.
#'
#' @param ctx Ingestion context list.
#' @param config xpipe_config object.
#' @return Invisibly TRUE on success.
#' @keywords internal
.materialize_batch <- function(ctx, config) {

  .assert_batch_materializable(ctx, config)

  instrument     <- .resolve_extraction_instrument(ctx, config)
  extracted_data <- .run_extraction(ctx, instrument)

  # Apply privacy rules to each extracted table
  for (nm in names(extracted_data)) {
    extracted_data[[nm]] <- apply_privacy_rules(
      extracted_data[[nm]],
      ctx$method_config,
      config$runtime$pepper
    )
  }
  .persist_to_batch(ctx, extracted_data, config)

  invisible(TRUE)
}
