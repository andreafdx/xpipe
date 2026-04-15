# ======================================================================= #
# FILE: src/fnc/config.R
#
# System configuration and options loading
#
# ======================================================================= #

box::use(
  yaml[read_yaml],
  fs,
  . / crypto[.hash_phi]
)



# YAML options ------------------------------------------------------------

#' Read YAML Configuration
#'
#' Safely reads a YAML file and converts it to a list. Throws a classed
#' error if the file is missing or contains invalid YAML syntax.
#'
#' @param path Character scalar. Path to the YAML file.
#' @return A named list.
#' @keywords internal
.load_yaml <- function(path = "inst/_xne/xacc.yml") {
  if (!fs::file_exists(path)) {
    cli::cli_abort(
      c(
        "Invalid YAML configuration",
        "x" = "YAML options file not found: {.file {path}}"
      ),
      class = "yaml_options"
    )
  }

  config <- tryCatch(
    read_yaml(path),
    error = function(e) {
      cli::cli_abort(
        c(
          "Invalid YAML configuration",
          "x" = "Invalid YAML in config file {.file {path}}",
          "!" = e$message
        ),
        class = "yaml_options"
      )
    }
  )

  config
}


#' Normalize Configuration Paths
#'
#' Processes the configuration list to ensure all filesystem paths are
#' absolute and normalized.
#'
#' Key operations:
#' \itemize{
#'   \item Resolves relative paths against \code{project_root}.
#'   \item Validates that required paths exist (aborts if not).
#'   \item Emits warnings for optional paths not yet present.
#' }
#'
#' @param config List. The raw configuration from \code{.load_yaml()}.
#' @param project_root Character scalar. Base path for relative resolution.
#' @return The normalized configuration list.
#'
#' @keywords internal
.normalize_paths <- function(config, project_root = NULL) {

  if (is.null(project_root)) {
    project_root <- fs::path_abs(".")
  }

  if (is.null(config$paths)) {
    cli::cli_abort(
      c(
        "Invalid YAML configuration",
        "x" = "Required section {.field paths} not set"
      ),
      class = c("yaml_options", "paths")
    )
  }

  config$paths <- lapply(config$paths, function(p) {
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
        class = c("yaml_options", "paths")
      )
    }

    p
  })

  # Normalize logging path (non-fatal)
  if (!is.null(config$logging$path)) {
    p <- fs::path_norm(fs::path(project_root, config$logging$path))

    if (!fs::dir_exists(p)) {
      cli::cli_alert_warning(
        c(
          "YAML warning",
          "Path {.file {p}} does not exist yet",
          "i" = "It may be created later during the import process"
        ),
        class = c("yaml_options", "logging")
      )
    }

    config$logging$path <- p
  }

  config
}



# Bronze options ----------------------------------------------------------

#' Validate Bronze Layer Path and Presence of bronze.json
#'
#' @param config List. Normalized YAML configuration.
#' @return Character scalar. Full path to bronze.json.
#' @keywords internal
.validate_bronze_layer <- function(config) {

  bronze_path <- config$paths$bronze

  if (is.null(bronze_path)) {
    cli::cli_abort(
      c(
        "Invalid YAML configuration",
        "x" = "Bronze layer path not set",
        "i" = "Expected field: paths.bronze"
      ),
      class = c("yaml_options", "paths")
    )
  }

  if (!is.character(bronze_path) || length(bronze_path) != 1 || !nzchar(bronze_path)) {
    cli::cli_abort(
      c(
        "Invalid YAML configuration",
        "x" = "paths.bronze must be a non-empty string",
        "!" = "Found: {.val {bronze_path}}"
      ),
      class = c("yaml_options", "paths")
    )
  }

  if (!fs::dir_exists(bronze_path)) {
    cli::cli_abort(
      c(
        "Invalid configuration path",
        "x" = "Bronze directory does not exist",
        "i" = "Path: {.file {bronze_path}}"
      ),
      class = c("yaml_options", "paths")
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
      class = c("yaml_options", "paths")
    )
  }

  bronze_json
}


#' Validate Bronze JSON Against Schema
#'
#' @param bronze_json_path Character scalar. Path to bronze.json.
#' @keywords internal
.validate_bronze_schema <- function(bronze_json_path) {


  schema_path <- fs::path(
    "inst",
    "schema",
    "bronze.schema.json"
  )



  #schema_path <- system.file(
  #  "schema",
  #  "bronze.schema.json",
  #  package = utils::packageName()
  #)

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


#' Load Bronze JSON Options
#'
#' @param bronze_json_path Character scalar. Path to bronze.json.
#' @return List. Parsed JSON options.
#' @keywords internal
.load_bronze_json <- function(bronze_json_path) {

  tryCatch(
    jsonlite::fromJSON(bronze_json_path),
    error = function(e) {
      cli::cli_abort(
        c(
          "Invalid bronze.json",
          "x" = "File is not valid JSON",
          "i" = "Path: {.file {bronze_json_path}}",
          "!" = e$message
        ),
        class = c("json_options", "bronze")
      )
    }
  )
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
    if (!is.null(alt_val) &&
        (!is.character(alt_val) || length(alt_val) != 1 || !nzchar(alt_val))) {
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
.validate_bronze_hash <- function(bronze_options,
                                  pepper,
                                  test_string = "byut5f778DfOPth567") {

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
#' @param config List. Normalized YAML configuration.
#' @return Updated configuration with validated bronze options attached.
#' @keywords internal
.load_bronze_layer <- function(config) {

  bronze_json <- .validate_bronze_layer(config)

  .validate_bronze_schema(bronze_json)

  bronze_options <- .load_bronze_json(bronze_json)

  bronze_options <- .validate_bronze_datastream(bronze_options)

  .validate_bronze_hash(
    bronze_options,
    pepper = config$runtime$pepper
  )

  config$bronze <- bronze_options
  config
}



# Bootloader --------------------------------------------------------------

#' Load and Validate Configuration
#'
#' Orchestrates the full loading process: reading YAML, injecting runtime
#' variables, normalizing paths, and loading validated medallion layer
#' options.
#'
#' @param path Character scalar. Path to the YAML file.
#' @param project_root Character scalar. Base path for relative resolution.
#' @return The fully validated configuration list.
#' @keywords internal
.load_options <- function(
    path = "inst/_xne/xacc.yml",
    project_root = NULL
) {
  cli::cli_alert_info("Loading configuration...")

  config <- .load_yaml(path)
  #cli::cli_alert_success("YAML options loaded.")

  config$runtime <- list()
  config$runtime$pepper <- Sys.getenv("XNE_PEPPER_KEY")

  if (is.null(config$runtime$pepper) || config$runtime$pepper == "") {
    cli::cli_abort(
      "{.envvar XNE_PEPPER_KEY} not found in .Renviron.",
      class = c("config", "runtime", "crypto")
    )
  }
  cli::cli_alert_success("Cryptographic key loaded from environment.")

  config <- .normalize_paths(config, project_root)
  cli::cli_alert_success("YAML options loaded and validated.")

  config <- .load_bronze_layer(config)
  cli::cli_alert_success("Bronze layer loaded and validated.")

  config
}
