
box::use(
  fs,
  cli,
  purrr[imap_chr]
)

# Batch initialization scripts --------------------------------------------




## Helper functions --------------------------------------------------------

#' Assert configuration validity for batch creation
#'
#' Ensures that a valid `xpipe_config` object is provided and that
#' all required branches (local paths, streams, methods) are present.
#'
#' @param config An object of class `xpipe_config`.
#' @return Invisibly returns TRUE if valid, otherwise aborts.
#' @keywords internal
#' @noRd
.assert_config_for_batch <- function(config) {
  if (missing(config) || !inherits(config, "xpipe_config")) {
    cli$cli_abort(
      c(
        "Invalid configuration",
        "x" = "A valid {.arg config} object loaded via {.code load_options()} is required"
      ),
      class = c("batch_job", "config")
    )
  }

  required_paths <- c("inbox", "batch")
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
#' @param config xpipe_config object.
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
        "x" = "Selected method requires a file, but a directory was provided.",
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

### Batch id & storage -----------------------------------------------------


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
.normalize_or_generate_batch_id <- function(stream_id, method_id, batch_id = NULL) {
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

  ts <- format(Sys.time(), "%Y%m%dT%H%M%OS3")
  #ts <- gsub("\\.", "", ts)

  paste0(ts, "_" ,stream_id, "_", method_id)
}



#' Build Batch Target Directory Path
#'
#' Constructs the normalized filesystem path for a batch within
#' the Batch layer, based on stream and batch identifiers.
#'
#' @param config xpipe_config object.
#' @param stream_id Character scalar identifying the stream.
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


## Public API -------------------------------------------------------------

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
#' @export
prepare_batch_ingestion <- function(
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
    cli$cli_abort(
      c(
        "Invalid batch job",
        "x" = "Method and stream belong to different schema domains",
        "i" = "Method domain: {.val {method_config$schema_domain}}",
        "i" = "Stream domain: {.val {stream_config$schema_domain}}"
      ),
      class = c("batch_job", "schema_domain")
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
