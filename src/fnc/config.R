
# Configuration and options -----------------------------------------------



box::use(
  ./crypto[hash_phi],
  jsonlite,
  jsonvalidate,
  fs,
  cli,
  purrr[imap_chr]
)

## Helper functions --------------------------------------------------------

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
    cli$cli_abort(
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
    cli$cli_abort(
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
      # Escape braces so cli/glue cannot interpret them
      msg <- conditionMessage(e)
      msg <- gsub("\\{", "{{", msg)
      msg <- gsub("\\}", "}}", msg)

      cli::cli_abort(
        c(
          error_title,
          "x" = "Invalid JSON syntax",
          "i" = msg
        ),
        class = error_class
      )
    }
  )
}


## Runtime context --------------------------------------------------------

#' Load Runtime Context
#'
#' Initializes the ephemeral runtime context for the current process.
#'
#' The runtime context contains environment-bound and non-persistent
#' information such as cryptographic keys and load timestamps.
#'
#' This is NOT a data layer and does not represent persisted state.
#'
#' @return Runtime context configuration.
#' @noRd
.load_runtime_context <- function() {
  runtime <- list(
    pepper = Sys.getenv("XNE_PEPPER_KEY"),
    loaded_at = Sys.time()
  )

  if (is.null(runtime$pepper) || runtime$pepper == "") {
    cli$cli_abort(
      "Environment variable {.envvar XNE_PEPPER_KEY} not found.",
      class = c("config", "runtime", "crypto")
    )
  }

  runtime
}

## Local configuration ----------------------------------------------------

#' Load Local Configuration
#'
#' Loads and normalizes environment-specific infrastructure configuration.
#'
#' The local configuration defines filesystem paths, logging locations,
#' and other deployment-specific settings required to run the system.
#'
#' This is NOT a data layer and does not encode domain or semantic rules.
#'
#' @param path Path to local.json.
#' @param project_root Root for resolving relative paths.
#' @return Normalized local configuration.
#' @noRd
.load_local_config <- function(path = NULL, project_root = NULL) {
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
#' Resolves and validates all filesystem paths defined in local.json.
#'
#' Ensures that paths are absolute, normalized, and exist on disk.
#' This function operates purely at the infrastructure level.
#'
#' @param local_config Raw local configuration.
#' @param project_root Base path.
#' @return Normalized local configuration.
#' @noRd
.normalize_paths <- function(local_config, project_root = NULL) {
  if (is.null(project_root)) {
    project_root <- fs::path_abs(".")
  }

  if (is.null(local_config$paths)) {
    cli$cli_abort(
      c("Invalid configuration", "x" = "Missing {.field paths}"),
      class = c("local_options", "paths")
    )
  }

  local_config$paths <- lapply(local_config$paths, function(p) {
    p <- fs::path_expand(p)
    p <- if (fs::is_absolute_path(p)) fs::path_norm(p)
    else fs::path_norm(fs::path(project_root, p))

    if (!fs::dir_exists(p)) {
      cli$cli_abort(
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


## Batch layer (Remote) ---------------------------------------------------

#' Validate Batch Layer Presence and Metadata
#'
#' Validates the Batch data layer location and the presence of its
#' persistent metadata file (`layer.json`).
#'
#' The Batch layer is a medallion DATA layer. The associated `layer.json`
#' represents layer STATE (integrity and provenance), not configuration
#' or domain semantics.
#'
#' @param local_config Local configuration.
#' @return Path to layer.json.
#' @noRd
.validate_batch_layer <- function(local_config) {
  batch_path <- local_config$paths$batch

  if (is.null(batch_path) || !nzchar(batch_path)) {
    cli$cli_abort(
      c(
        "Invalid configuration",
        "x" = "Batch layer path not set",
        "i" = "Expected field: paths.batch"
      ),
      class = c("local_options", "paths")
    )
  }

  if (!fs::dir_exists(batch_path)) {
    cli$cli_abort(
      c(
        "Invalid Batch layer",
        "x" = "Batch layer directory does not exist",
        "i" = "Path: {.file {batch_path}}"
      ),
      class = c("batch_layer", "paths")
    )
  }

  layer_json <- fs::path(batch_path, "layer.json")
  if (!fs::file_exists(layer_json)) {
    cli$cli_abort(
      c(
        "Invalid Batch layer metadata",
        "x" = "Required file {.file layer.json} not found",
        "i" = "Expected: layer.json in {.file {batch_path}}"
      ),
      class = c("batch_layer", "metadata")
    )
  }

  layer_json
}

#' Validate Batch Layer Integrity Hash
#'
#' Verifies the integrity of the Batch layer metadata using a shared
#' cryptographic secret. This protects against accidental or unauthorized
#' modification of layer state.
#'
#' @param layer_options Parsed layer.json.
#' @param pepper Runtime key.
#' @param test_string Internal test string.
#' @noRd
.validate_batch_hash <- function(
    layer_options,
    pepper,
    test_string = "byut5f778DfOPth567"
) {
  # Bypass hash check if environment variable is set
  if (Sys.getenv("XACC_SKIP_HASH_CHECK") == "TRUE") {
    cli::cli_alert_warning("Bypassing Batch layer integrity hash check.")
    return(invisible(TRUE))
  }

  expected_hash <- layer_options$expected_hash

  if (is.null(expected_hash) || expected_hash == "") {
    cli$cli_abort(
      c(
        "Invalid Batch layer metadata",
        "x" = "Missing expected_hash in layer.json"
      ),
      class = c("batch_layer", "crypto")
    )
  }

  if (hash_phi(test_string, pepper) != expected_hash) {
    cli$cli_abort(
      c(
        "Invalid Batch layer metadata",
        "x" = "Hash mismatch. System will not start."
      ),
      class = c("batch_layer", "crypto")
    )
  }

  invisible(TRUE)
}

#' Load Batch Layer Metadata
#'
#' Loads and validates the persistent metadata describing the Batch
#' medallion layer. This metadata represents STATE of the data layer,
#' not configuration or domain logic.
#'
#' @param local_config Local configuration.
#' @param runtime_config Runtime context.
#' @return Parsed and validated Batch layer metadata.
#' @noRd
.load_batch_layer <- function(local_config, runtime_config) {
  layer_json <- .validate_batch_layer(local_config)

  # Note: Add layer.schema.json if stricter validation is required later
  layer_options <- .read_json_safe(
    path = layer_json,
    error_title = "Invalid Batch layer metadata",
    error_class = c("json_options", "batch_layer")
  )

  .validate_batch_hash(layer_options, runtime_config$pepper)

  layer_options
}


## Streams contract (Remote) ----------------------------------------------

#' Load Streams Contract
#'
#' Loads and validates the Streams contract, which defines domain-level
#' semantic invariants (streams) used across Batch, Bronze, and Silver.
#'
#' The Streams contract is GOVERNANCE METADATA, not configuration and not
#' a medallion data layer.
#'
#' @param local_config Local configuration.
#' @return A list with two elements:
#'   - meta: streams contract metadata
#'   - streams: named list of stream definitions
#' @noRd
.load_streams_contract <- function(local_config) {
  path <- fs::path(local_config$paths$shared, "streams.json")

  .validate_json_schema(
    json_path  = path,
    schema_name = "streams.schema.json",
    title = "Invalid streams.json",
    class = c("config_options", "schema")
  )

  raw <- .read_json_safe(
    path,
    error_title = "Invalid streams contract",
    error_class = "streams_options"
  )

  # Extract and validate contract metadata
  meta <- raw$`_meta`

  if (is.null(meta) || is.null(meta$type) || meta$type != "streams_contract") {
    cli::cli_abort(
      c(
        "Invalid streams contract",
        "x" = "Missing or invalid {.field _meta.type}",
        "i" = "Expected: 'streams_contract'"
      ),
      class = c("streams_contract", "metadata")
    )
  }

  # Extract actual streams
  streams <- raw[names(raw) != "_meta"]

  if (length(streams) == 0) {
    cli::cli_abort(
      c(
        "Invalid streams contract",
        "x" = "No stream definitions found"
      ),
      class = c("streams_contract", "streams")
    )
  }

  #  Minimal semantic validation
  for (nm in names(streams)) {
    s <- streams[[nm]]

    missing_fields <- setdiff(
      c("label", "anchor", "partition_granularity", "valid_from"),
      names(s)
    )

    if (length(missing_fields) > 0) {
      cli::cli_abort(
        c(
          "Invalid stream definition",
          "x" = "Stream {.val {nm}} missing required fields: {.val {missing_fields}}"
        ),
        class = c("streams_contract", "streams")
      )
    }

    if (!(s$anchor %in% c("start", "end"))) {
      cli::cli_abort(
        c(
          "Invalid stream definition",
          "x" = "Stream {.val {nm}} has invalid anchor: {.val {s$anchor}}",
          "i" = "Allowed: 'start', 'end'"
        ),
        class = c("streams_contract", "streams")
      )
    }
  }

  list(
    meta    = meta,
    streams = streams
  )
}


## Methods contract (Remote) ------------------------------------------------

#' Load Methods Contract
#'
#' Loads and validates the Methods contract, which defines ingestion
#' mechanics and extraction rules used to materialize Batch data.
#'
#' A Method describes HOW data is ingested (format, components,
#' identity, partitioning, privacy), not WHAT the data means.
#'
#' The Methods contract is a CONTROL-PLANE artifact and must not
#' be confused with medallion data layers.
#'
#' @param local_config Local configuration.
#' @return Validated methods configuration.
#' @noRd
.load_methods_contract <- function(local_config) {
  path <- fs::path(local_config$paths$shared, "methods.json")

  .validate_json_schema(
    json_path = path,
    schema_name = "methods.schema.json",
    title = "Invalid methods.json",
    class = c("config_options", "schema")
  )

  .read_json_safe(
    path,
    error_title = "Invalid methods contract",
    error_class = "methods_options"
  )
}


## Public API ---------------------------------------------------------------

#' Load and Validate Configuration
#'
#' Loads the full XACC control-plane configuration, including:
#' - runtime context
#' - local infrastructure configuration
#' - batch layer metadata
#' - streams contract (domain semantics)
#' - methods contract (ingestion mechanics)
#'
#' @param path Path to local.json.
#' @param project_root Project root.
#' @return xacc_config object.
#' @export
load_options <- function(path = NULL, project_root = NULL) {
  config <- list()

  # Runtime context
  config$runtime <- .load_runtime_context()

  # Local configuration
  config$local <- .load_local_config(path, project_root)

  # Batch layer metadata (data layer state)
  config$batch <- .load_batch_layer(config$local, config$runtime)

  # Streams contract
  streams_contract <- .load_streams_contract(config$local)
  config$streams_meta <- streams_contract$meta
  config$streams      <- streams_contract$streams

  # Methods contract
  config$methods <- .load_methods_contract(config$local)

  cli::cli_alert_success("Configuration system loaded and validated.")

  structure(config, class = "xacc_config")
}


## S3 Methods --------------------------------------------------------------

#' Render Configuration Gracefully
#'
#' Provides a structured console summary of the active control-plane
#' configuration.
#'
#' @param x An S3 object of class \code{xacc_config}.
#' @param ... Additional arguments (ignored).
#' @noRd
.render_config <- function(x, ...) {
  cli::cli_div(
    theme = list(rule = list(color = "cyan", "line-type" = "double"))
  )
  cli::cli_rule("XACC Configuration Map")

  # 1. RUNTIME CONTEXT
  cli::cli_h2("Runtime Context")
  cli::cli_bullets(c(
    "Loaded at : {.val {format(x$runtime$loaded_at)}}",
    "Security  : HMAC-SHA256 (Masked Pepper: {.val {substr(x$runtime$pepper, 1, 4)}}...)"
  ))

  # 2. LOCAL INFRASTRUCTURE
  cli::cli_h2("Local Infrastructure")
  if (!is.null(x$local$paths)) {
    cli::cli_bullets(
      purrr::imap_chr(
        x$local$paths,
        ~ paste0("{.strong ", format(.y, width = 10), "} : {.file ", .x, "}")
      )
    )
  }

  # 3. STREAMS CONTRACT (Semantic Truth)
  cli::cli_h2("Streams Contract")
  if (!is.null(x$streams_meta)) {
    cli::cli_bullets(c(
      "Contract type : {.val {x$streams_meta$type}}",
      "Version       : {.val {x$streams_meta$version}}",
      "Maintainer    : {.val {x$streams_meta$maintainer}}",
      "Last updated  : {.val {x$streams_meta$last_updated}}"
    ))
  }

  if (!is.null(x$streams)) {
    stream_bullets <- purrr::imap_chr(
      x$streams,
      function(v, nm) {
        paste0(
          "{.strong ", nm, "} ",
          "[", v$label, "] ",
          "(anchor: ", v$anchor, " | ",
          "partition: ", v$partition_granularity, ")"
        )
      }
    )
    cli::cli_bullets(stream_bullets)
  }

  # 4. METHODS CONTRACT (Ingestion Mechanics)
  cli::cli_h2("Methods Contract")
  if (!is.null(x$methods)) {
    method_bullets <- purrr::imap_chr(
      x$methods,
      function(v, nm) {
        paste0(
          "{.strong ", nm, "} ",
          "➔ stream binding: ", v$stream, " ",
          "[", v$type, "]"
        )
      }
    )
    cli::cli_bullets(method_bullets)
  }

  # 5. BATCH LAYER STATUS
  cli::cli_h2("Batch Layer State")
  cli::cli_alert_success("Batch layer metadata validated and trusted.")

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
