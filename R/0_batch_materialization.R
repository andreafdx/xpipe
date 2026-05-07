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
#              .resolve_inputs(), .normalize_or_generate_batch_id(),
#              .build_batch_target_dir(), .prepare_batch_ingestion(),
#              .assert_batch_materializable(), .resolve_extraction_instrument(),
#              .run_extraction(), .persist_to_batch(), .materialize_batch()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Error Class Taxonomy --------------------------------------------------------
#
# All errors inherit from `xpipe_error` (package base) and `xpipe_batch_error`
# (file-level domain). New leaves from core_config.R taxonomy also apply here
# (xpipe_batch_paths, xpipe_batch_metadata, xpipe_batch_hash).
#
#   xpipe_error
#   └── xpipe_batch_error
#       ├── xpipe_batch_config        # invalid or incomplete xpipe_config object
#       ├── xpipe_batch_schema_domain # method/stream schema domain mismatch
#       ├── xpipe_batch_method        # unknown or invalid method identifier
#       ├── xpipe_batch_stream        # unknown stream identifier
#       ├── xpipe_batch_path          # inbox path invalid or not found
#       ├── xpipe_batch_input_type    # file vs directory requirement mismatch
#       ├── xpipe_batch_components    # directory component missing or ambiguous
#       ├── xpipe_batch_id            # invalid explicit batch_id
#       ├── xpipe_batch_collision     # target batch directory already exists
#       ├── xpipe_batch_input         # input missing or empty at materialization
#       ├── xpipe_batch_instrument    # extractor not registered or not loaded
#       ├── xpipe_batch_extraction    # extractor returned invalid result
#       ├── xpipe_batch_materialization # ctx or config invalid at materialization
#       └── xpipe_batch_abort         # user declined confirmation prompt

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
  config = get_xpipe_config(),
  batch_id = NULL,
  confirm = interactive(),
  dry_run = FALSE
) {
  checkmate::assert_string(filename)
  checkmate::assert_string(stream)
  checkmate::assert_string(method)
  checkmate::assert_class(config, "xpipe_config")
  checkmate::assert_string(batch_id, null.ok = TRUE)
  checkmate::assert_flag(confirm)
  checkmate::assert_flag(dry_run)

  ctx <- .prepare_batch_ingestion(
    filename = filename,
    stream = stream,
    method = method,
    config = config,
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
) {
  .assert_config_for_batch(config)

  method_config <- .get_method_config(config, method)
  stream_config <- .get_stream_config(config, stream)
  stream_id <- stream

  if (method_config$schema_domain != stream_config$schema_domain) {
    cli::cli_abort(
      c(
        "Invalid batch job",
        "x" = "Method and stream belong to different schema domains",
        "i" = "Method domain: {.val {method_config$schema_domain}}",
        "i" = "Stream domain: {.val {stream_config$schema_domain}}"
      ),
      class = c("xpipe_batch_schema_domain", "xpipe_batch_error", "xpipe_error")
    )
  }

  filepath <- .resolve_inbox_path(config, filename)

  # Validation against method requirement
  .validate_input_type(filepath, method_config)

  # Discover and resolve component inputs
  resolved_inputs <- if (fs::is_dir(filepath)) {
    .resolve_inputs(filepath, method_config)
  } else {
    components <- method_config$components
    if (!is.null(components)) {
      setNames(rep(list(filepath), length(components)), components)
    } else {
      list(data = filepath)
    }
  }

  batch_id <- .normalize_or_generate_batch_id(stream_id, method, batch_id)
  batch_dir <- .build_batch_target_dir(config, batch_id)

  list(
    batch_id = batch_id,
    filename = filename,
    filepath = filepath,
    method_id = method,
    method_config = method_config,
    stream_id = stream_id,
    stream_config = stream_config,
    batch_dir = batch_dir,
    resolved_inputs = resolved_inputs
  )
}


## Init helpers --------------------------------------------------------

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
  if (!inherits(config, "xpipe_config")) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "Expected an {.cls xpipe_config} object from {.code load_xpipe_config()}"
      ),
      class = c("xpipe_batch_config", "xpipe_batch_error", "xpipe_error")
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
      class = c("xpipe_batch_config", "xpipe_batch_error", "xpipe_error")
    )
  }

  if (is.null(config$streams) || is.null(config$methods)) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "Streams or Methods options not loaded"
      ),
      class = c("xpipe_batch_config", "xpipe_batch_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}


#' Retrieve method configuration
#'
#' @param config xpipe_config object.
#' @param method_id Character scalar.
#' @return A list with the method configuration.
#' @keywords internal
#' @noRd
.get_method_config <- function(config, method_id) {
  checkmate::assert_string(method_id)

  available <- names(config$methods)
  if (!(method_id %in% available)) {
    cli::cli_abort(
      c(
        "Invalid method",
        "x" = "Unknown method: {.val {method_id}}",
        "i" = "Available methods: {.str {available}}"
      ),
      class = c("xpipe_batch_method", "xpipe_batch_error", "xpipe_error")
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
  checkmate::assert_string(stream_id)

  available <- names(config$streams)
  if (!(stream_id %in% available)) {
    cli::cli_abort(
      c(
        "Invalid stream",
        "x" = "Unknown stream: {.val {stream_id}}",
        "i" = "Available streams: {.str {available}}"
      ),
      class = c("xpipe_batch_stream", "xpipe_batch_error", "xpipe_error")
    )
  }

  config$streams[[stream_id]]
}


#' Resolve input path from inbox
#'
#' @param config xpipe_config object.
#' @param path Character scalar.
#' @return Normalized absolute path.
#' @keywords internal
#' @noRd
.resolve_inbox_path <- function(config, path) {
  checkmate::assert_string(path)

  full_path <- fs::path(config$local$paths$inbox, path)
  if (!fs::file_exists(full_path)) {
    cli::cli_abort(
      c(
        "Input path not found",
        "x" = "Path {.file {path}} was not found in inbox",
        "i" = "Inbox: {.file {config$local$paths$inbox}}"
      ),
      class = c("xpipe_batch_path", "xpipe_batch_error", "xpipe_error")
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
      class = c("xpipe_batch_input_type", "xpipe_batch_error", "xpipe_error")
    )
  }

  if (required_type == "directory" && !actual_is_dir) {
    cli::cli_abort(
      c(
        "Invalid input type",
        "x" = "Method {.val {method_config$method_id}} requires a directory, but a file was provided.",
        "i" = "Path: {.file {filepath}}"
      ),
      class = c("xpipe_batch_input_type", "xpipe_batch_error", "xpipe_error")
    )
  }
}

#' Discover and resolve components
#'
#' Resolves logical components into concrete file paths.
#'
#' @keywords internal
#' @noRd
.resolve_inputs <- function(dir_path, method_config) {
  components <- method_config$components

  if (is.null(components)) {
    return(NULL)
  }

  resolved <- list()

  for (nm in names(components)) {
    pattern <- components[[nm]]
    matches <- fs::dir_ls(dir_path, glob = pattern)

    if (length(matches) == 0) {
      cli::cli_abort(
        c(
          "Missing input",
          "x" = "No files found for component {.val {nm}}",
          "i" = "Pattern: {.val {pattern}}",
          "i" = "Directory: {.file {dir_path}}"
        ),
        class = c("xpipe_batch_components", "xpipe_batch_error", "xpipe_error")
      )
    }

    if (length(matches) > 1) {
      cli::cli_abort(
        c(
          "Ambiguous input",
          "x" = "Multiple files found for component {.val {nm}}",
          "i" = "Pattern: {.val {pattern}}",
          "i" = "Found: {.file {basename(matches)}}"
        ),
        class = c("xpipe_batch_components", "xpipe_batch_error", "xpipe_error")
      )
    }

    resolved[[nm]] <- as.character(matches[[1]])
  }

  resolved
}


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
.normalize_or_generate_batch_id <- function(
  stream_id,
  method_id,
  batch_id = NULL
) {
  checkmate::assert_string(stream_id)
  checkmate::assert_string(method_id)
  if (!is.null(batch_id)) {
    checkmate::assert_string(batch_id)
    if (!nzchar(batch_id)) {
      cli::cli_abort(
        c(
          "Invalid batch identifier",
          "x" = "{.arg batch_id} must be a non-empty string"
        ),
        class = c("xpipe_batch_id", "xpipe_batch_error", "xpipe_error")
      )
    }
    return(batch_id)
  }
  ts <- format(Sys.time(), "%Y%m%dT%H%M%OS3")
  paste0(ts, "_", stream_id, "_", method_id)
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
  checkmate::assert_string(batch_id)
  fs::path_norm(fs::path(config$local$paths$batch, batch_id))
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

  if (!is.null(ctx$resolved_inputs)) {
    cli::cli_h3("Resolved component inputs")
    cli::cli_bullets(
      purrr::imap_chr(
        ctx$resolved_inputs,
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
          class = c("xpipe_batch_abort", "xpipe_batch_error", "xpipe_error")
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
      class = c("xpipe_batch_abort", "xpipe_batch_error", "xpipe_error")
    )
  }

  invisible(TRUE)
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

  instrument <- .resolve_extraction_instrument(ctx, config)

  cli::cli_alert_info("Running extraction")

  extracted_data <- rlang::try_fetch(
    .run_extraction(ctx, instrument),
    error = function(e) {
      cli::cli_abort(
        "Data extraction failed for method type {.val {ctx$method_config$type}}",
        parent = e,
        class = c("xpipe_batch_extraction", "xpipe_batch_error", "xpipe_error")
      )
    }
  )

  cli::cli_alert_info("Applying privacy rules")

  for (nm in names(extracted_data)) {
    extracted_data[[nm]] <- apply_privacy_rules(
      df = extracted_data[[nm]],
      table_name = nm,
      method_config = ctx$method_config,
      pepper = config$runtime$pepper
    )
  }

  rlang::try_fetch(
    .persist_to_batch(ctx, extracted_data, config),
    error = function(e) {
      cli::cli_abort(
        "Failed to persist batch data to {.file {ctx$batch_dir}}",
        parent = e,
        class = c(
          "xpipe_batch_materialization",
          "xpipe_batch_error",
          "xpipe_error"
        )
      )
    }
  )

  invisible(TRUE)
}


## Phases ----------------------------------------------------------------

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
  checkmate::assert_list(ctx, min.len = 1)
  checkmate::assert_class(config, "xpipe_config")

  # A1. Target collision check (batch layer)
  if (fs::dir_exists(ctx$batch_dir)) {
    cli::cli_abort(
      c(
        "Ingestion cannot proceed",
        "x" = "Target batch directory already exists",
        "i" = "Path: {.file {ctx$batch_dir}}",
        "i" = "Batch id: {.val {ctx$batch_id}}"
      ),
      class = c("xpipe_batch_collision", "xpipe_batch_error", "xpipe_error")
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
      class = c("xpipe_batch_input", "xpipe_batch_error", "xpipe_error")
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
      class = c("xpipe_batch_input", "xpipe_batch_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}

#' Resolve extraction instrument
#'
#' @keywords internal
#' @noRd
.resolve_extraction_instrument <- function(ctx, config) {
  # Registry: method type -> extractor function name (string)
  # Add new extractors here; the function must be loaded before ingest_batch() is called.
  .instrument_registry <- c(
    "access_mdb" = "extract_access_db",
    "xml" = "extract_xml"
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
      class = c("xpipe_batch_instrument", "xpipe_batch_error", "xpipe_error")
    )
  }

  if (!exists(fn_name, mode = "function")) {
    cli::cli_abort(
      c(
        "Extraction instrument not loaded",
        "x" = "Function {.code {fn_name}} is not available in the current environment",
        "i" = "Source the appropriate tool script before calling {.code ingest_batch()}"
      ),
      class = c("xpipe_batch_instrument", "xpipe_batch_error", "xpipe_error")
    )
  }

  get(fn_name, mode = "function")
}


#' Run extraction and load batch data into memory
#'
#' @keywords internal
#' @noRd
.run_extraction <- function(ctx, instrument) {
  extracted <- instrument(ctx)

  if (is.data.frame(extracted)) {
    extracted <- list(data = extracted)
  }

  if (!is.list(extracted) || length(extracted) == 0) {
    cli::cli_abort(
      c(
        "Invalid extraction result",
        "x" = "Extractor must return a non-empty list of data frames"
      ),
      class = c("xpipe_batch_extraction", "xpipe_batch_error", "xpipe_error")
    )
  }

  if (is.null(names(extracted)) || any(!nzchar(names(extracted)))) {
    cli::cli_abort(
      c(
        "Invalid extraction result",
        "x" = "Extracted list must have a valid name for every element"
      ),
      class = c("xpipe_batch_extraction", "xpipe_batch_error", "xpipe_error")
    )
  }

  invalid_elements <- purrr::keep(extracted, ~ !is.data.frame(.x))
  if (length(invalid_elements) > 0) {
    cli::cli_abort(
      c(
        "Invalid extracted object",
        "x" = "All extracted elements must be data.frames",
        "i" = "Invalid element(s): {.val {names(invalid_elements)}}"
      ),
      class = c("xpipe_batch_extraction", "xpipe_batch_error", "xpipe_error")
    )
  }

  extracted
}


#' Persist extracted data to the Batch layer
#'
#' @keywords internal
#' @noRd
.persist_to_batch <- function(ctx, extracted_data, config) {
  fs::dir_create(ctx$batch_dir, recurse = TRUE)

  for (nm in names(extracted_data)) {
    tbl <- extracted_data[[nm]]

    arrow::write_parquet(
      tbl,
      fs::path(ctx$batch_dir, paste0(nm, ".parquet"))
    )
  }

  # Meta file as JSON for cross-platform compatibility
  meta <- list(
    batch_id = ctx$batch_id,

    stream = list(
      id = ctx$stream_id,
      schema_domain = ctx$method_config$schema_domain,
      anchor = ctx$stream_config$anchor
    ),

    method = list(
      id = ctx$method_id,
      type = ctx$method_config$type
    ),

    input = list(
      path = as.character(ctx$filepath),
      input_type = ctx$method_config$input_type
    ),

    execution = list(
      created_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
      tool = config$runtime$tool$name,
      tool_version = config$runtime$tool$version
    )
  )

  if (!is.null(ctx$resolved_inputs)) {
    meta$resolved_inputs <- lapply(ctx$resolved_inputs, basename)
  }

  meta$tables <- names(extracted_data)

  jsonlite::write_json(
    meta,
    fs::path(ctx$batch_dir, "_batch_metadata.json"),
    pretty = TRUE,
    auto_unbox = TRUE
  )

  cli::cli_alert_success("Batch materialized: {.val {ctx$batch_id}}")

  invisible(TRUE)
}
