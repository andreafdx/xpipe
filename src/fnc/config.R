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
#' development mode (local paths) and package mode (system.file).
#'
#' @param ... Character strings defining the subpath within 'inst'.
#' @return Character scalar. The absolute path to the asset.
#' @keywords internal
.find_asset <- function(...) {
  # 1. Try development path (search for inst/ in parent directories)
  # This allows the function to work from the project root or subfolders
  search_paths <- c(".", "..", "../..")

  for (base in search_paths) {
    dev_path <- fs::path_abs(fs::path(base, "inst", ...))
    if (fs::file_exists(dev_path) || fs::dir_exists(dev_path)) {
      return(dev_path)
    }
  }

  # 2. Try package path (when installed)
  pkg_path <- system.file(..., package = "xacc")

  if (pkg_path != "") {
    return(pkg_path)
  }

  # 3. Fail gracefully
  cli::cli_abort(
    c(
      "Internal asset not found",
      "x" = "Could not locate {.file {fs::path(...)}} in dev or package mode"
    ),
    class = "asset_not_found"
  )
}


#' Validate JSON File Against Internal Schema
#'
#' @param json_path Character scalar. Path to the JSON file.
#' @param schema_name Character scalar. Schema file name (e.g. "local.schema.json").
#' @param title Character scalar. Error title.
#' @param class Character vector. Error classes.
#' @return Logical. Invisibly returns TRUE if successful (otherwise aborts).
#' @keywords internal
.validate_json_schema <- function(
  json_path,
  schema_name,
  title,
  class
) {
  if (!fs::file_exists(json_path)) {
    cli::cli_abort(
      c(
        title,
        "x" = "JSON file not found: {.file {json_path}}"
      ),
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
#' Safely reads any JSON configuration and converts it to a list. Throws
#' a classed error if the file is missing or contains invalid JSON syntax.
#'
#' @param path Character scalar. Path to the JSON file.
#' @param error_title Character scalar. Title to use in `cli_abort` on failure.
#' @param error_class Character vector. Error class array for `cli_abort`.
#' @return A named list.
#' @keywords internal
.read_json_safe <- function(path, error_title, error_class) {
  if (!fs::file_exists(path)) {
    cli::cli_abort(
      c(
        error_title,
        "x" = "JSON file not found: {.file {path}}"
      ),
      class = error_class
    )
  }

  tryCatch(
    jsonlite::fromJSON(path, simplifyVector = TRUE),
    error = function(e) {
      cli::cli_abort(
        c(
          error_title,
          "x" = "Invalid JSON syntax in {.file {path}}",
          "!" = e$message
        ),
        class = error_class
      )
    }
  )
}

# Bootloader Layers (Internal) --------------------------------------------

#' Load Runtime Layer
#'
#' Retrieves and validates required runtime environment variables.
#'
#' @return List of runtime settings.
#' @keywords internal
.load_runtime_layer <- function() {
  runtime <- list()
  runtime$pepper <- Sys.getenv("XNE_PEPPER_KEY")
  runtime$loaded_at <- Sys.time()

  if (is.null(runtime$pepper) || runtime$pepper == "") {
    cli::cli_abort(
      "Environment variable {.envvar XNE_PEPPER_KEY} not found.",
      class = c("config", "runtime", "crypto")
    )
  }

  runtime
}

#' Load Local Layer
#'
#' @param path Character scalar. Path to the local JSON file.
#' @param project_root Character scalar. Base path for relative resolution.
#' @return List of normalized local configuration paths and settings.
#' @keywords internal
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

  local_config <- .read_json_safe(
    path = path,
    error_title = "Invalid local configuration",
    error_class = "local_options"
  )

  .normalize_paths(local_config, project_root)
}


#' Normalize Configuration Paths
#'
#' Processes the local configuration to ensure all filesystem paths are
#' absolute and normalized.
#'
#' @param local_config List. The raw configuration from \code{.load_local_config()}.
#' @param project_root Character scalar. Base path for relative resolution.
#' @return The normalized local configuration list.
#' @keywords internal
.normalize_paths <- function(local_config, project_root = NULL) {
  if (is.null(project_root)) {
    project_root <- fs::path_abs(".")
  }

  if (is.null(local_config$paths)) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "Required section {.field paths} not set"
      ),
      class = c("local_options", "paths")
    )
  }

  local_config$paths <- lapply(local_config$paths, function(p) {
    p <- fs::path_expand(p)

    p <- if (fs::is_absolute_path(p)) {
      fs::path_norm(p)
    } else {
      fs::path_norm(fs::path(project_root, p))
    }

    if (!fs::dir_exists(p)) {
      cli::cli_abort(
        c(
          "Invalid configuration path",
          "x" = "Path {.file {p}} does not exist"
        ),
        class = c("local_options", "paths")
      )
    }

    p
  })

  # Normalize logging path (non-fatal)
  if (!is.null(local_config$logging$path)) {
    p <- fs::path_norm(fs::path(project_root, local_config$logging$path))

    if (!fs::dir_exists(fs::path_dir(p))) {
      cli::cli_alert_warning(
        c(
          "Config warning",
          "Logging directory does not exist yet",
          "i" = "It may be created later during the import process"
        )
      )
    }

    local_config$logging$path <- p
  }

  local_config
}


# Bronze options ----------------------------------------------------------

#' Validate Bronze Layer Path and Presence of bronze.json
#'
#' @param config List. Normalized YAML configuration.
#' @return Character scalar. Full path to bronze.json.
#' @keywords internal
.validate_bronze_layer <- function(local_config) {
  bronze_path <- local_config$paths$bronze

  if (is.null(bronze_path)) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "Bronze layer path not set",
        "i" = "Expected field: paths.bronze"
      ),
      class = c("local_options", "paths")
    )
  }

  if (
    !is.character(bronze_path) ||
      length(bronze_path) != 1 ||
      !nzchar(bronze_path)
  ) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "paths.bronze must be a non-empty string",
        "!" = "Found: {.val {bronze_path}}"
      ),
      class = c("local_options", "paths")
    )
  }

  if (!fs::dir_exists(bronze_path)) {
    cli::cli_abort(
      c(
        "Invalid configuration path",
        "x" = "Bronze directory does not exist",
        "i" = "Path: {.file {bronze_path}}"
      ),
      class = c("local_options", "paths")
    )
  }

  bronze_json <- fs::path(bronze_path, "bronze.json")

  if (!fs::file_exists(bronze_json)) {
    cli::cli_abort(
      c(
        "Invalid bronze.json",
        "x" = "Required file not found",
        "i" = "Expected: bronze.json in {.file {bronze_path}}"
      ),
      class = c("local_options", "paths")
    )
  }

  bronze_json
}


#' Validate Bronze JSON Against Schema
#'
#' @param bronze_json_path Character scalar. Path to bronze.json.
#' @keywords internal
.validate_bronze_schema <- function(bronze_json_path) {
  schema_path <- .find_asset("schema", "bronze.schema.json")

  if (schema_path == "") {
    cli::cli_abort(
      c(
        "Internal configuration error",
        "x" = "Bronze JSON schema not found"
      ),
      class = c("json_options", "schema")
    )
  }

  ok <- jsonvalidate::json_validate(
    bronze_json_path,
    schema = schema_path,
    engine = "ajv",
    verbose = TRUE
  )

  if (!ok) {
    cli::cli_abort(
      c(
        "Invalid bronze.json",
        "x" = "JSON does not conform to schema",
        "i" = "Schema: {.file {schema_path}}"
      ),
      class = c("json_options", "schema")
    )
  }

  invisible(TRUE)
}


#' Validate Bronze Datastream Options
#'
#' @param bronze_options List. Parsed bronze.json options.
#' @return The validated options.
#' @keywords internal
.validate_bronze_datastream <- function(bronze_options) {
  if (is.null(bronze_options$datastream)) {
    cli::cli_abort(
      c(
        "Invalid bronze.json",
        "x" = "Missing required field: datastream"
      ),
      class = c("json_options", "datastream")
    )
  }

  for (nm in names(bronze_options$datastream)) {
    stream <- bronze_options$datastream[[nm]]

    alt_val <- stream$alt
    if (
      !is.null(alt_val) &&
        (!is.character(alt_val) || length(alt_val) != 1 || !nzchar(alt_val))
    ) {
      cli::cli_abort(
        c(
          "Invalid bronze.json",
          "x" = "Invalid value for {.field alt}",
          "i" = "Path: datastream.{nm}.alt",
          ">" = "Expected: non-empty string"
        ),
        class = c("json_options", "datastream")
      )
    }

    time_block_val <- stream$time_block
    if (is.null(time_block_val) || !(time_block_val %in% c("y", "q"))) {
      cli::cli_abort(
        c(
          "Invalid bronze.json",
          "x" = "Invalid value for {.field time_block}",
          "i" = "Path: datastream.{nm}.time_block",
          ">" = "Expected: 'y' or 'q'",
          "!" = "Found: {.val {time_block_val}}"
        ),
        class = c("json_options", "datastream")
      )
    }
  }

  bronze_options
}


#' Validate Bronze Integrity Hash
#'
#' @param bronze_options List. Parsed bronze.json options.
#' @param pepper Character scalar. Runtime encryption key.
#' @param test_string Character scalar. Test string for hashing.
#' @keywords internal
.validate_bronze_hash <- function(
  bronze_options,
  pepper,
  test_string = "byut5f778DfOPth567"
) {
  expected_hash <- bronze_options$expected_hash

  if (is.null(expected_hash) || expected_hash == "") {
    cli::cli_abort(
      c(
        "Invalid bronze.json",
        "x" = "Missing expected_hash"
      ),
      class = c("json_options", "crypto")
    )
  }

  hash <- .hash_phi(test_string, pepper)

  if (hash != expected_hash) {
    cli::cli_abort(
      c(
        "Invalid bronze.json",
        "x" = "Hash mismatch. The system will not start."
      ),
      class = c("json_options", "crypto")
    )
  }

  invisible(TRUE)
}


#' Load and Validate Bronze Layer
#'
#' @param local_config List. Normalized local configuration.
#' @param runtime_config List. Runtime environment variables.
#' @return A list containing the validated bronze options.
#' @keywords internal
.load_bronze_layer <- function(local_config, runtime_config) {
  bronze_json <- .validate_bronze_layer(local_config)

  .validate_json_schema(
    json_path = bronze_json,
    schema_name = "bronze.schema.json",
    title = "Invalid bronze.json",
    class = c("json_options", "schema")
  )

  bronze_options <- .read_json_safe(
    path = bronze_json,
    error_title = "Invalid bronze.json",
    error_class = c("json_options", "bronze")
  )

  bronze_options <- .validate_bronze_datastream(bronze_options)

  .validate_bronze_hash(
    bronze_options,
    pepper = runtime_config$pepper
  )

  bronze_options
}


# Bootloader (Public API) -------------------------------------------------

#' Load and Validate Configuration
#'
#' Orchestrates the full loading process: reading local settings,
#' injecting runtime variables, normalizing paths, and loading validated
#' medallion layer options.
#'
#' @param path Character scalar. Path to the local JSON file.
#' @param project_root Character scalar. Base path for relative resolution.
#' @return An S3 object of class \code{xacc_config}.
#' @export
load_options <- function(
  path = NULL,
  project_root = NULL
) {
  cli::cli_alert_info("Loading configuration system...")

  config <- list()

  config$runtime <- .load_runtime_layer()
  config$local <- .load_local_layer(path, project_root)
  config$bronze <- .load_bronze_layer(config$local, config$runtime)

  cli::cli_alert_success("Configuration system loaded and validated.")

  structure(config, class = "xacc_config")
}


#' Render Configuration Gracefully
#'
#' Provides a stylish, detailed console summary of the configuration object.
#'
#' @param x An S3 object of class \code{xacc_config}.
#' @param ... Additional arguments (ignored).
#' @export
render_config <- function(x, ...) {
  cli::cli_div(
    theme = list(rule = list(color = "cyan", "line-type" = "double"))
  )
  cli::cli_rule("XACC Configuration Summary")

  # 1. Layer: Runtime
  cli::cli_h2("Layer: Runtime")
  if (!is.null(x$runtime$pepper)) {
    cli::cli_alert_success(
      "Pepper loaded: {.val {substr(x$runtime$pepper, 1, 6)}}... (masked)"
    )
  }
  if (!is.null(x$runtime$loaded_at)) {
    cli::cli_li("Loaded at: {.val {format(x$runtime$loaded_at)}}")
  }

  # 2. Layer: Local
  cli::cli_h2("Layer: Local")
  if (!is.null(x$local$paths)) {
    cli::cli_h3("Paths")
    cli::cli_bullets(
      imap_chr(x$local$paths, function(v, k) {
        paste0("{.strong ", k, "} : {.file ", v, "}")
      })
    )
  }

  if (!is.null(x$local$logging)) {
    cli::cli_h3("Logging")
    cli::cli_bullets(
      imap_chr(x$local$logging, function(v, k) {
        paste0("{.strong ", k, "} : {.val ", v, "}")
      })
    )
  }

  # 3. Layer: Medallion (Bronze)
  cli::cli_h2("Layer: Medallion (Bronze)")
  cli::cli_alert_success("Schema validated & Integrity hash verified")

  if (!is.null(x$bronze$datastream)) {
    cli::cli_h3("Datastreams")
    cli::cli_bullets(
      imap_chr(x$bronze$datastream, function(v, k) {
        tb <- if (is.null(v$time_block)) "?" else v$time_block
        paste0("{.strong ", k, "} (period: {.val ", tb, "})")
      })
    )
  }

  cli::cli_rule()
  cli::cli_end()

  invisible(x)
}


# S3 Methods --------------------------------------------------------------

#' Print xacc configuration
#'
#' Pretty printer for xacc_config objects.
#'
#' @param x An object of class \code{xacc_config}.
#' @param ... Unused.
#' @export
print.xacc_config <- function(x, ...) {
  render_config(x, ...)
}
