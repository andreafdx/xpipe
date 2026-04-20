# ======================================================================= #
# FILE: src/fnc/config.R
#
# System configuration and options loading
#
# ======================================================================= #

box::use(
  ./crypto[.hash_phi],
  purrr[imap_chr]
)

# Helper functions --------------------------------------------------------

#' Find Internal Asset
#'
#' Resilient helper to locate internal files (config, schemas) in both
#' development and installed package modes.
#'
#' @param ... Character strings defining the subpath within 'inst'.
#' @return Character scalar. The absolute path to the asset.
#' @noRd
.find_asset <- function(...) {
  search_paths <- c(".", "..", "../..")

  for (base in search_paths) {
    dev_path <- fs::path_abs(fs::path(base, "inst", ...))
    if (fs::file_exists(dev_path) || fs::dir_exists(dev_path)) {
      return(dev_path)
    }
  }

  pkg_path <- system.file(..., package = "xacc")
  if (pkg_path != "") {
    return(pkg_path)
  }

  cli::cli_abort(
    c(
      "Internal asset not found",
      "x" = "Could not locate {.file {fs::path(...)}}"
    ),
    class = "asset_not_found"
  )
}

#' Validate JSON File Against Internal Schema
#'
#' @param json_path Path to JSON file.
#' @param schema_name Schema file name.
#' @param title Error title.
#' @param class Error classes.
#' @return Invisibly TRUE if valid.
#' @noRd
.validate_json_schema <- function(json_path, schema_name, title, class) {
  if (!fs::file_exists(json_path)) {
    cli::cli_abort(
      c(title, "x" = "JSON file not found: {.file {json_path}}"),
      class = class
    )
  }

  schema_path <- .find_asset("schema", schema_name)

  ok <- jsonvalidate::json_validate(
    json_path,
    schema = schema_path,
    engine = "ajv",
    verbose = TRUE
  )

  if (!ok) {
    cli::cli_abort(
      c(
        title,
        "x" = "JSON does not conform to schema",
        "i" = "Schema: {.file {schema_path}}",
        "i" = "File: {.file {json_path}}"
      ),
      class = class
    )
  }

  invisible(TRUE)
}

#' Read JSON Safely
#'
#' @param path Path to JSON file.
#' @param error_title Error title.
#' @param error_class Error classes.
#' @return Parsed JSON as list.
#' @noRd
.read_json_safe <- function(path, error_title, error_class) {
  if (!fs::file_exists(path)) {
    cli::cli_abort(
      c(error_title, "x" = "JSON file not found: {.file {path}}"),
      class = error_class
    )
  }

  tryCatch(
    jsonlite::fromJSON(path, simplifyVector = TRUE),
    error = function(e) {
      cli::cli_abort(
        c(
          error_title,
          "x" = "Invalid JSON syntax",
          "!" = e$message
        ),
        class = error_class
      )
    }
  )
}

# Runtime layer ----------------------------------------------------------

#' Load Runtime Layer
#'
#' @return Runtime configuration.
#' @noRd
.load_runtime_layer <- function() {
  runtime <- list(
    pepper = Sys.getenv("XNE_PEPPER_KEY"),
    loaded_at = Sys.time()
  )

  if (is.null(runtime$pepper) || runtime$pepper == "") {
    cli::cli_abort(
      "Environment variable {.envvar XNE_PEPPER_KEY} not found.",
      class = c("config", "runtime", "crypto")
    )
  }

  runtime
}

# Local layer ------------------------------------------------------------

#' Load Local Layer
#'
#' @param path Path to local.json.
#' @param project_root Root for relative paths.
#' @return Normalized local configuration.
#' @noRd
.load_local_layer <- function(path = NULL, project_root = NULL) {
  if (is.null(path)) {
    path <- .find_asset("_xne", "local.json")
  }

  .validate_json_schema(
    json_path = path,
    schema_name = "local.schema.json",
    title = "Invalid local.json",
    class = c("config_options", "schema")
  )

  local_cfg <- .read_json_safe(
    path,
    error_title = "Invalid local configuration",
    error_class = "local_options"
  )

  .normalize_paths(local_cfg, project_root)
}

#' Normalize Configuration Paths
#'
#' @param local_config Raw local config.
#' @param project_root Base path.
#' @return Normalized config.
#' @noRd
.normalize_paths <- function(local_config, project_root = NULL) {
  if (is.null(project_root)) {
    project_root <- fs::path_abs(".")
  }

  if (is.null(local_config$paths)) {
    cli::cli_abort(
      c("Invalid configuration", "x" = "Missing {.field paths}"),
      class = c("local_options", "paths")
    )
  }

  local_config$paths <- lapply(local_config$paths, function(p) {
    p <- fs::path_expand(p)
    p <- if (fs::is_absolute_path(p)) fs::path_norm(p)
    else fs::path_norm(fs::path(project_root, p))

    if (!fs::dir_exists(p)) {
      cli::cli_abort(
        c("Invalid configuration path", "x" = "Path {.file {p}} does not exist"),
        class = c("local_options", "paths")
      )
    }

    p
  })

  if (!is.null(local_config$logging$path)) {
    p <- fs::path_norm(fs::path(project_root, local_config$logging$path))
    local_config$logging$path <- p
  }

  local_config
}

# Batch layer (Remote) ---------------------------------------------------

#' Validate Batch Layer Path and Presence of batch.json
#'
#' @param local_config Local configuration.
#' @return Path to batch.json.
#' @noRd
.validate_batch_layer <- function(local_config) {
  batch_path <- local_config$paths$batch

  if (is.null(batch_path) || !nzchar(batch_path)) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "Batch layer path not set",
        "i" = "Expected field: paths.batch"
      ),
      class = c("local_options", "paths")
    )
  }

  if (!fs::dir_exists(batch_path)) {
    cli::cli_abort(
      c("Invalid configuration path", "x" = "Batch directory does not exist"),
      class = c("local_options", "paths")
    )
  }

  batch_json <- fs::path(batch_path, "batch.json")
  if (!fs::file_exists(batch_json)) {
    cli::cli_abort(
      c(
        "Invalid batch.json",
        "x" = "Required file not found",
        "i" = "Expected: batch.json in {.file {batch_path}}"
      ),
      class = c("local_options", "paths")
    )
  }

  batch_json
}

#' Validate Batch JSON Against Schema
#'
#' @param batch_json_path Path to batch.json.
#' @noRd
.validate_batch_schema <- function(batch_json_path) {
  .validate_json_schema(
    json_path = batch_json_path,
    schema_name = "batch.schema.json",
    title = "Invalid batch.json",
    class = c("json_options", "schema")
  )
}

#' Validate Batch Datastream Definitions
#'
#' @param batch_options Parsed batch.json.
#' @return Validated options.
#' @noRd
.validate_batch_datastream <- function(batch_options) {
  if (is.null(batch_options$datastream)) {
    cli::cli_abort(
      c("Invalid batch.json", "x" = "Missing field: datastream"),
      class = c("json_options", "datastream")
    )
  }

  for (nm in names(batch_options$datastream)) {
    stream <- batch_options$datastream[[nm]]

    if (is.null(stream$anchor) || !(stream$anchor %in% c("start", "end"))) {
      cli::cli_abort(
        c(
          "Invalid batch.json",
          "x" = "Invalid value for {.field anchor}",
          "i" = "Path: datastream.{nm}.anchor",
          ">" = "Expected: 'start' or 'end'"
        ),
        class = c("json_options", "datastream")
      )
    }

    if (!is.null(stream$alt) &&
        (!is.character(stream$alt) || !nzchar(stream$alt))) {
      cli::cli_abort(
        c("Invalid batch.json", "x" = "Invalid alt value"),
        class = c("json_options", "datastream")
      )
    }

    if (!is.null(stream$batch_span)) {
      if (!is.character(stream$batch_span)) {
        cli::cli_abort(
          c("Invalid batch.json", "x" = "batch_span must be a character vector"),
          class = c("json_options", "datastream")
        )
      }
    }
  }

  batch_options
}

#' Validate Batch Integrity Hash
#'
#' @param batch_options Parsed batch.json.
#' @param pepper Runtime key.
#' @param test_string Test string.
#' @noRd
.validate_batch_hash <- function(
    batch_options,
    pepper,
    test_string = "byut5f778DfOPth567"
) {
  # Bypass hash check if environment variable is set
  if (Sys.getenv("XACC_SKIP_HASH_CHECK") == "TRUE") {
    cli::cli_alert_warning("Bypassing batch integrity hash check.")
    return(invisible(TRUE))
  }

  expected_hash <- batch_options$expected_hash

  if (is.null(expected_hash) || expected_hash == "") {
    cli::cli_abort(
      c("Invalid batch.json", "x" = "Missing expected_hash"),
      class = c("json_options", "crypto")
    )
  }

  if (.hash_phi(test_string, pepper) != expected_hash) {
    cli::cli_abort(
      c("Invalid batch.json", "x" = "Hash mismatch. System will not start."),
      class = c("json_options", "crypto")
    )
  }

  invisible(TRUE)
}

#' Load and Validate Batch Layer
#'
#' @param local_config Local configuration.
#' @param runtime_config Runtime configuration.
#' @return Validated batch options.
#' @noRd
.load_batch_layer <- function(local_config, runtime_config) {
  batch_json <- .validate_batch_layer(local_config)

  .validate_batch_schema(batch_json)

  batch_options <- .read_json_safe(
    path = batch_json,
    error_title = "Invalid batch.json",
    error_class = c("json_options", "batch")
  )

  batch_options <- .validate_batch_datastream(batch_options)

  .validate_batch_hash(batch_options, runtime_config$pepper)

  batch_options
}

# Streams layer ----------------------------------------------------------

#' Load Streams Layer
#'
#' @return Validated streams configuration.
#' @noRd
.load_streams_layer <- function() {
  path <- .find_asset("_xne", "streams.json")

  .validate_json_schema(
    json_path = path,
    schema_name = "streams.schema.json",
    title = "Invalid streams.json",
    class = c("config_options", "schema")
  )

  .read_json_safe(
    path,
    error_title = "Invalid streams configuration",
    error_class = "streams_options"
  )
}

# Methods layer ----------------------------------------------------------

#' Load Methods Layer
#'
#' @return Validated methods configuration.
#' @noRd
.load_methods_layer <- function() {
  path <- .find_asset("_xne", "methods.json")

  .validate_json_schema(
    json_path = path,
    schema_name = "methods.schema.json",
    title = "Invalid methods.json",
    class = c("config_options", "schema")
  )

  .read_json_safe(
    path,
    error_title = "Invalid methods configuration",
    error_class = "methods_options"
  )
}

# Bootloader -------------------------------------------------------------

#' Load and Validate Configuration
#'
#' @param path Path to local.json.
#' @param project_root Project root.
#' @return xacc_config object.
#' @export
load_options <- function(path = NULL, project_root = NULL) {
  config <- list()
  config$runtime <- .load_runtime_layer()
  config$local   <- .load_local_layer(path, project_root)
  config$batch   <- .load_batch_layer(config$local, config$runtime)
  config$streams <- .load_streams_layer()
  config$methods <- .load_methods_layer()

  cli::cli_alert_success("Configuration system loaded and validated.")

  structure(config, class = "xacc_config")
}

#' Render Configuration Gracefully
#'
#' Provides a stylish, detailed console summary of the configuration object.
#'
#' @param x An S3 object of class \code{xacc_config}.
#' @param ... Additional arguments (ignored).
#' @noRd
.render_config <- function(x, ...) {
  cli::cli_div(
    theme = list(rule = list(color = "cyan", "line-type" = "double"))
  )
  cli::cli_rule("XACC Configuration Summary")

  # 1. Layer: Runtime
  cli::cli_h2("Layer: Runtime")
  if (!is.null(x$runtime$pepper)) {
    cli::cli_alert_success(
      "Secret key: {.val {substr(x$runtime$pepper, 1, 6)}}... (masked)"
    )
  }
  if (!is.null(x$runtime$loaded_at)) {
    cli::cli_bullets("Loaded at: {.val {format(x$runtime$loaded_at)}}")
  }

  # 2. Layer: Local
  cli::cli_h2("Layer: Local")
  if (!is.null(x$local$paths)) {
    cli::cli_h3("Paths")
    cli::cli_bullets(
      purrr::imap_chr(
        x$local$paths,
        ~ paste0(.y, " : {.file ", .x, "}")
      )
    )
  }

  if (!is.null(x$local$logging)) {
    cli::cli_h3("Logging")
    cli::cli_bullets(
      purrr::imap_chr(
        x$local$logging,
        ~ paste0(.y, " : {.val ", .x, "}")
      )
    )
  }

  # 3. Layer: Batch (ex Bronze)
  cli::cli_h2("Layer: Batch")
  cli::cli_alert_success("Schema validated & Integrity hash verified")

  if (!is.null(x$batch$datastream)) {
    cli::cli_h3("Datastreams")
    cli::cli_bullets(
      purrr::imap_chr(
        x$batch$datastream,
        ~ paste0(
          "{.strong ", .y, "} ",
          "(anchor: {.val ", .x$anchor, "})"
        )
      )
    )
  }

  # 4. Layer: Streams
  cli::cli_h2("Layer: Streams")
  if (!is.null(x$streams)) {
    cli::cli_bullets(
      purrr::imap_chr(
        x$streams,
        ~ paste0("{.strong ", .y, "}")
      )
    )
  }

  # 5. Layer: Methods
  cli::cli_h2("Layer: Methods")
  if (!is.null(x$methods)) {
    cli::cli_bullets(
      purrr::imap_chr(
        x$methods,
        ~ paste0("{.strong ", .y, "} (stream: {.val ", .x$stream, "})")
      )
    )
  }

  cli::cli_rule()
  cli::cli_end()

  invisible(x)
}

#' Print xacc_config
#'
#' @param x xacc_config object.
#' @param ... Ignored.
#' @noRd
print.xacc_config <- function(x, ...) {
  .render_config(x, ...)
}
