box::use(
  fs,
  cli,
  purrr[imap_chr]
)

# Helper functions --------------------------------------------------------

#' Assert configuration validity for batch creation
#'
#' Ensures that a valid `xacc_config` object is provided and that
#' all required branches (local paths, streams, methods) are present.
#'
#' @param config An object of class `xacc_config`.
#' @return Invisibly returns TRUE if valid, otherwise aborts.
#' @keywords internal
#' @noRd
.assert_config_for_batch <- function(config) {
  if (missing(config) || !inherits(config, "xacc_config")) {
    cli$cli_abort(
      c(
        "Invalid configuration",
        "x" = "A valid {.arg config} object loaded via {.code load_options()} is required"
      ),
      class = c("batch_job", "config")
    )
  }

  required_paths <- c("inbox", "raw", "batch")
  missing_paths <- setdiff(required_paths, names(config$local$paths))

  if (length(missing_paths) > 0) {
    cli$cli_abort(
      c(
        "Invalid configuration",
        "x" = "Missing required paths in config: {.val {missing_paths}}"
      ),
      class = c("batch_job", "config", "paths")
    )
  }

  if (is.null(config$streams) || is.null(config$methods)) {
    cli$cli_abort(
      c(
        "Invalid configuration",
        "x" = "Streams or Methods options not loaded"
      ),
      class = c("batch_job", "config", "metadata")
    )
  }

  invisible(TRUE)
}

# Method and Stream validation --------------------------------------------

#' Retrieve method configuration
#'
#' @param config xacc_config object.
#' @param method_id Character scalar.
#' @return A list with the method configuration.
#' @keywords internal
#' @noRd
.get_method_config <- function(config, method_id) {
  if (!is.character(method_id) || length(method_id) != 1 || !nzchar(method_id)) {
    cli$cli_abort(
      c(
        "Invalid method",
        "x" = "{.arg method_id} must be a non-empty string"
      ),
      class = c("batch_job", "method")
    )
  }

  available <- names(config$methods)
  if (!(method_id %in% available)) {
    cli$cli_abort(
      c(
        "Invalid method",
        "x" = "Unknown method: {.val {method_id}}",
        "i" = "Available methods: {.str {available}}"
      ),
      class = c("batch_job", "method")
    )
  }

  config$methods[[method_id]]
}

#' Retrieve stream configuration
#'
#' @param config xacc_config object.
#' @param stream_id Character scalar.
#' @return A list with the stream configuration.
#' @keywords internal
#' @noRd
.get_stream_config <- function(config, stream_id) {
  available <- names(config$streams)
  if (!(stream_id %in% available)) {
    cli$cli_abort(
      c(
        "Invalid stream",
        "x" = "Unknown stream: {.val {stream_id}}",
        "i" = "Available streams: {.str {available}}"
      ),
      class = c("batch_job", "stream")
    )
  }

  config$streams[[stream_id]]
}

## Inbox ------------------------------------------------------------------

#' Resolve input path from inbox
#'
#' @param config xacc_config object.
#' @param path Character scalar.
#' @return Normalized absolute path.
#' @keywords internal
#' @noRd
.resolve_inbox_path <- function(config, path) {
  if (!is.character(path) || length(path) != 1 || !nzchar(path)) {
    cli$cli_abort(
      c(
        "Invalid path",
        "x" = "{.arg path} must be a non-empty string"
      ),
      class = c("batch_job", "path")
    )
  }

  full_path <- fs::path(config$local$paths$inbox, path)
  if (!fs::file_exists(full_path)) {
    cli$cli_abort(
      c(
        "Input path not found",
        "x" = "Path {.file {path}} was not found in inbox",
        "i" = "Inbox: {.file {config$local$paths$inbox}}"
      ),
      class = c("batch_job", "path")
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
    cli$cli_abort(
      c(
        "Invalid input type",
        "x" = "Method {.val {method_config$method_id}} requires a file, but a directory was provided.",
        "i" = "Path: {.file {filepath}}"
      ),
      class = c("batch_job", "input_type")
    )
  }

  if (required_type == "directory" && !actual_is_dir) {
    cli$cli_abort(
      c(
        "Invalid input type",
        "x" = "Method {.val {method_config$method_id}} requires a directory, but a file was provided.",
        "i" = "Path: {.file {filepath}}"
      ),
      class = c("batch_job", "input_type")
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
      cli$cli_abort(
        c(
          "Missing component",
          "x" = "Could not find file for component {.val {nm}}",
          "i" = "Pattern: {.val {pattern}}",
          "i" = "Directory: {.file {dir_path}}"
        ),
        class = c("batch_job", "components")
      )
    }

    if (length(matches) > 1) {
      cli$cli_abort(
        c(
          "Ambiguous component",
          "x" = "Multiple files found for component {.val {nm}}",
          "i" = "Pattern: {.val {pattern}}",
          "i" = "Found: {.file {basename(matches)}}"
        ),
        class = c("batch_job", "components")
      )
    }

    resolved[[nm]] <- as.character(matches)
  }

  resolved
}

## Batch id & storage -----------------------------------------------------


#' Normalize or Generate Batch Identifier
#'
#' Validates an explicit batch identifier or generates a unique
#' stream-scoped batch ID when none is provided.
#'
#' @param stream_id Character scalar identifying the stream.
#' @param batch_id Optional character scalar. Explicit batch ID.
#'
#' @return Character scalar batch identifier.
#'
#' @noRd
.normalize_or_generate_batch_id <- function(stream_id, batch_id = NULL) {
  if (!is.null(batch_id)) {
    if (!is.character(batch_id) || length(batch_id) != 1 || !nzchar(batch_id)) {
      cli$cli_abort(
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

  paste0(stream_id, "_", ts)
}



#' Build Batch Target Directory Path
#'
#' Constructs the normalized filesystem path for a batch within
#' the Batch layer, based on stream and batch identifiers.
#'
#' @param config xacc_config object.
#' @param stream_id Character scalar identifying the stream.
#' @param batch_id Character scalar batch identifier.
#'
#' @return Normalized filesystem path to the batch directory.
#'
#' @noRd
.build_batch_target_dir <- function(config, stream_id, batch_id) {
  fs::path_norm(
    fs::path(config$local$paths$batch, stream_id, batch_id)
  )
}


#' Construct Batch Job Object
#'
#' Assembles a structured \code{xacc_batch_job} object representing
#' a validated batch import intent in initialized state.
#'
#' @param filename Character scalar. Original input name.
#' @param filepath Character scalar. Resolved absolute input path.
#' @param method_id Character scalar ingestion method identifier.
#' @param method_config Method configuration list.
#' @param stream_id Character scalar identifying the stream.
#' @param stream_config Stream configuration list.
#' @param batch_root Character scalar batch root path.
#' @param batch_dir Character scalar target batch directory.
#' @param batch_id Character scalar batch identifier.
#' @param components Optional list of discovered components.
#'
#' @return An object of class \code{xacc_batch_job}.
#'
#' @noRd
.build_batch_job <- function(
    filename, filepath,
    method_id, method_config,
    stream_id, stream_config,
    batch_root, batch_dir,
    batch_id,
    components = NULL
) {
  structure(
    list(
      batch_id = batch_id,
      filename = filename,
      filepath = filepath,
      method_id = method_id,
      method_config = method_config,
      stream_id = stream_id,
      stream_config = stream_config,
      batch_root = batch_root,
      batch_dir = batch_dir,
      status = "initialized",
      components = components
    ),
    class = "xacc_batch_job"
  )
}

# Public API -------------------------------------------------------------

#' Create a New Batch Import Job
#'
#' Constructs a validated batch import job intent based on an input file
#' or directory located in the inbox and a configured ingestion method.
#'
#' This function performs configuration validation, input resolution,
#' and method/stream compatibility checks, but does not read, transform,
#' or write any data. The returned object represents a fully specified
#' batch job ready for materialization.
#'
#' @param filename Character scalar. Name of a file or directory located
#'   in the inbox path defined in the local configuration.
#' @param method Character scalar identifying the ingestion method to use,
#'   as defined in \code{methods.json}.
#' @param config An object of class \code{xacc_config}, as returned by
#'   \code{load_options()}.
#' @param batch_id Optional character scalar. Explicit batch identifier.
#'   If \code{NULL}, a unique batch identifier is generated automatically.
#'
#' @return An object of class \code{xacc_batch_job} in
#'   \code{"initialized"} state.
#'
#' @details
#' The batch job object encapsulates all metadata required for batch
#' materialization, including resolved input paths, method and stream
#' configuration, target batch directory, and any discovered components.
#'
#' No filesystem side effects are performed beyond path validation.
#' Data extraction and persistence occur only during
#' \code{materialize_batch_job()}.
#'
#' @export
new_batch_job <- function(
    filename,
    method,
    config,
    batch_id = NULL
) {
  .assert_config_for_batch(config)

  method_config <- .get_method_config(config, method)
  stream_id     <- method_config$stream
  stream_config <- .get_stream_config(config, stream_id)

  # Inject stream_id into stream_config for downstream use
  stream_config$stream_id <- stream_id

  filepath  <- .resolve_inbox_path(config, filename)

  # Validation against method requirement
  .validate_input_type(filepath, method_config)

  # Discover components if it's a directory
  components <- if (fs::is_dir(filepath)) {
    .discover_components(filepath, method_config)
  } else {
    NULL
  }

  batch_id  <- .normalize_or_generate_batch_id(stream_id, batch_id)
  batch_dir <- .build_batch_target_dir(config, stream_id, batch_id)

  .build_batch_job(
    filename = filename,
    filepath = filepath,
    method_id = method,
    method_config = method_config,
    stream_id = stream_id,
    stream_config = stream_config,
    batch_root = config$local$paths$batch,
    batch_dir = batch_dir,
    batch_id = batch_id,
    components = components
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
    "path        : {.file {x$filepath}}",
    "method      : {.val {x$method_id}} [{.val {x$method_config$type}}]",
    "stream      : {.val {x$stream_id}}",
    "anchor      : {.val {x$stream_config$anchor}}"
  ))

  if (!is.null(x$components)) {
    cli::cli_h3("Components discovered")
    cli::cli_bullets(
      purrr::imap_chr(x$components, ~ paste0("{.strong ", .y, "} : {.file ", basename(.x), "}"))
    )
  }

  cli::cli_h2("Storage (Batch)")
  cli::cli_bullets(c(
    "root        : {.file {x$batch_root}}",
    "stream      : {.val {x$stream_id}}",
    "batch_id    : {.val {x$batch_id}}",
    "target dir  : {.file {x$batch_dir}}"
  ))

  cli::cli_rule()
  cli::cli_end()

  invisible(x)
}
