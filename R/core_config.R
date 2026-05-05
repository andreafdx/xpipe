# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# core_config.R
#
# Configuration and options loading for the xpipe control plane.
#
# Approach: Parses and validates JSON configurations and schema files,
# manages runtime context (like the pepper key), and normalizes paths.
# It ensures that local infrastructure and remote layer configurations
# are properly structured before any pipeline tasks occur.
#
# Public API:  load_xpipe_config()
# Internals:   .find_asset(), .validate_json_schema(), .read_json_safe(),
#              .load_runtime_context(), .load_local_config(), .normalize_paths(),
#              .validate_batch_layer(), .validate_batch_hash(), .load_batch_layer(),
#              .load_streams_contract(), .load_methods_contract()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


# Internal Environment ----------------------------------------------------
#
# This is to hold package state
.xpipe_env <- new.env(parent = emptyenv())

# Error Class Taxonomy --------------------------------------------------------
#
# All errors in this file inherit from `xpipe_error` (package base class),
# allowing callers to catch any xpipe error at a single level if needed.
#
# Hierarchy (specific → domain → base):
#
#   xpipe_error                        # catch-all for the package
#   ├── xpipe_runtime_error
#   │   └── xpipe_runtime_pepper       # XNE_PEPPER_KEY missing or empty
#   ├── xpipe_config_error
#   │   ├── xpipe_config_missing       # load_xpipe_config() not yet called
#   │   └── xpipe_config_schema_domain # method references unknown stream domain
#   ├── xpipe_local_error
#   │   └── xpipe_local_paths          # missing or non-existent path in local.json
#   ├── xpipe_batch_error
#   │   ├── xpipe_batch_paths          # batch directory missing or not configured
#   │   ├── xpipe_batch_metadata       # layer.json missing or invalid
#   │   └── xpipe_batch_hash           # HMAC integrity check failed
#   ├── xpipe_streams_error
#   │   ├── xpipe_streams_metadata     # _meta block missing or invalid type
#   │   └── xpipe_streams_definition   # stream missing fields or invalid anchor
#   ├── xpipe_methods_error            # methods contract load or schema failure
#   ├── xpipe_json_error               # (composed into domain errors via error_class)
#   │   ├── xpipe_json_not_found       # file does not exist
#   │   ├── xpipe_json_schema          # file fails schema validation
#   │   └── xpipe_json_invalid         # file is not valid JSON
#   └── xpipe_asset_error
#       └── xpipe_asset_not_found      # internal inst/ asset not locatable
#
# Usage in tryCatch / try_fetch:
#   rlang::try_fetch(expr, xpipe_error = function(e) ...)   # catch anything
#   rlang::try_fetch(expr, xpipe_batch_error = function(e) ...) # catch batch only

# Public API ---------------------------------------------------------------

#' Load and Validate Configuration
#'
#' Loads the full xpipe control-plane configuration, including:
#' - runtime context
#' - local infrastructure configuration
#' - batch layer metadata
#' - streams contract (domain semantics)
#' - methods contract (ingestion mechanics)
#'
#' @param path Path to local.json.
#' @param project_root Project root.
#' @return xpipe_config object.
#' @export
load_xpipe_config <- function(path = NULL, project_root = NULL) {
  checkmate::assert_string(path, null.ok = TRUE)
  checkmate::assert_string(project_root, null.ok = TRUE)

  config <- list()

  config$runtime <- .config_step("initialize runtime context",
                                 .load_runtime_context()
  )
  config$local   <- .config_step("load local configuration",
                                 .load_local_config(path, project_root)
  )
  config$batch   <- .config_step("load Batch layer",
                                 .load_batch_layer(config$local, config$runtime)
  )

  streams_contract <- .config_step("load Streams contract",
                                   .load_streams_contract(config$local)
  )
  config$streams_meta <- streams_contract$meta
  config$streams      <- streams_contract$streams

  config$methods <- .config_step("load Methods contract",
                                 .load_methods_contract(config$local)
  )

  # Validate schema domains consistency
  stream_domains  <- unique(vapply(config$streams, `[[`, "", "schema_domain"))
  method_domains  <- unique(vapply(config$methods, `[[`, "", "schema_domain"))

  unknown_domains <- setdiff(method_domains, stream_domains)

  if (length(unknown_domains) > 0) {
    cli::cli_abort(
      c(
        "Invalid configuration",
        "x" = "Methods reference unknown schema_domain(s): {.val {unknown_domains}}",
        "i" = "Defined stream domains: {.val {stream_domains}}"
      ),
      class = c("xpipe_config_schema_domain", "xpipe_config_error", "xpipe_error")
    )
  }

  cli::cli_alert_success("Configuration system loaded and validated.")

  config_obj <- structure(config, class = "xpipe_config")
  .xpipe_env$config <- config_obj

  invisible(config_obj)
}


# Internal API ------------------------------------------------------------


#' Retrieve Active xpipe Configuration
#'
#' @return An xpipe_config object.
#' @keywords internal
get_xpipe_config <- function() {
  if (is.null(.xpipe_env$config)) {
    cli::cli_abort(
      c(
        "Configuration not loaded",
        "x" = "No active configuration found in the package environment.",
        "i" = "Call {.code load_xpipe_config()} before running pipeline tasks."
      ),
      class = c("xpipe_config_missing", "xpipe_config_error", "xpipe_error")
    )
  }
  .xpipe_env$config
}



# Main Helpers (steps) --------------------------------------------------------

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
    tool = list(
      name    = "xpipe",
      version =
        if (requireNamespace("xpipe", quietly = TRUE)) {
          as.character(utils::packageVersion("xpipe"))
        } else {
          "dev"
        }
    ),
    pepper = Sys.getenv("XNE_PEPPER_KEY", unset = NA_character_),
    loaded_at = Sys.time()
  )

  if (!checkmate::test_string(runtime$pepper, min.chars = 1)) {
    cli::cli_abort(
      "Environment variable {.envvar XNE_PEPPER_KEY} not found.",
      class = c("xpipe_runtime_pepper", "xpipe_runtime_error", "xpipe_error")
    )
  }

  runtime
}

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
    error_title = "Invalid local.json",
    error_class = "xpipe_local_error"
  )

  local_cfg <- .read_json_safe(
    path,
    error_title = "Invalid local configuration",
    error_class = "xpipe_local_error"
  )

  .normalize_paths(local_cfg, project_root)
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

  layer_options <- .read_json_safe(
    path = layer_json,
    error_title = "Invalid Batch layer metadata",
    error_class = "xpipe_batch_metadata"
  )

  .validate_batch_hash(layer_options, runtime_config$pepper)

  layer_options
}
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
    error_title = "Invalid streams.json",
    error_class = "xpipe_streams_error"
  )

  raw <- .read_json_safe(
    path,
    error_title = "Invalid streams contract",
    error_class = "xpipe_streams_error"
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
      class = c("xpipe_streams_metadata", "xpipe_streams_error", "xpipe_error")
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
      class = c("xpipe_streams_definition", "xpipe_streams_error", "xpipe_error")
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
        class = c("xpipe_streams_definition", "xpipe_streams_error", "xpipe_error")
      )
    }

    if (!(s$anchor %in% c("start", "end"))) {
      cli::cli_abort(
        c(
          "Invalid stream definition",
          "x" = "Stream {.val {nm}} has invalid anchor: {.val {s$anchor}}",
          "i" = "Allowed: 'start', 'end'"
        ),
        class = c("xpipe_streams_definition", "xpipe_streams_error", "xpipe_error")
      )
    }
  }

  list(
    meta    = meta,
    streams = streams
  )
}

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
    error_title = "Invalid methods.json",
    error_class = "xpipe_methods_error"
  )

  .read_json_safe(
    path,
    error_title = "Invalid methods contract",
    error_class = "xpipe_methods_error"
  )
}





# Sub-helpers --------------------------------------------------------

#' Wrap a Configuration Boot Step with Contextual Error Handling
#'
#' Executes a single configuration loading step and catches any
#' `xpipe_error` condition, rethrowing it as `xpipe_config_error`
#' with a step-level label prepended to the message chain.
#'
#' The original error is preserved as the parent condition and
#' rendered by cli as a "Caused by" line, so no diagnostic
#' information is lost.
#'
#' @param label A string describing the step, used in the outer
#'   error message as "Failed to {label}". Should complete the
#'   sentence naturally, e.g. `"load Batch layer"`.
#' @param expr A single expression to evaluate — typically one
#'   internal helper call. Eagerly evaluated, so multi-line
#'   blocks must be wrapped in `{}`.
#'
#' @return The result of `expr` if it succeeds.
#'
#' @section Error handling:
#'   Catches: any condition inheriting from `xpipe_error`.
#'   Throws:  `c("xpipe_config_error", "xpipe_error")`.
#'   Intermediate class handlers (e.g. `xpipe_batch_error`) are
#'   not needed here because all throws in this codebase use
#'   leaf-level classes, all of which inherit from `xpipe_error`.
#'
#' @noRd
.config_step <- function(label, expr) {
  rlang::try_fetch(
    expr,
    xpipe_error = function(e) cli::cli_abort(
      "Failed to {label}",
      parent = e,
      call = NULL,
      class = c("xpipe_config_error", "xpipe_error")
    )
  )
}

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

  pkg_path <- system.file(..., package = "xpipe")
  if (pkg_path != "") {
    return(pkg_path)
  }

  cli::cli_abort(
    c(
      "Internal asset not found",
      "x" = "Could not locate {.file {fs::path(...)}}"
    ),
    class = c("xpipe_asset_not_found", "xpipe_asset_error", "xpipe_error")
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
.validate_json_schema <- function(json_path, schema_name, error_title, error_class) {
  rlang::check_string(json_path)
  rlang::check_string(schema_name)
  rlang::check_string(error_title)
  rlang::check_string(error_class)


  if (!fs::file_exists(json_path)) {
    cli::cli_abort(
      c(error_title, "x" = "JSON file not found: {.file {json_path}}"),
      class = c(error_class, "xpipe_json_not_found", "xpipe_json_error", "xpipe_error")
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
        error_title,
        "x" = "JSON does not conform to schema",
        "i" = "Schema: {.file {schema_path}}",
        "i" = "File: {.file {json_path}}"
      ),
      class = c(error_class, "xpipe_json_schema", "xpipe_json_error", "xpipe_error")
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
  rlang::check_string(path)
  rlang::check_string(error_title)
  rlang::check_string(error_class)

  if (!fs::file_exists(path)) {
    cli::cli_abort(
      c(error_title, "x" = "JSON file not found: {.file {path}}"),
      class = c(error_class, "xpipe_json_not_found", "xpipe_json_error", "xpipe_error")
    )
  }

  rlang::try_fetch(
    jsonlite::fromJSON(path, simplifyVector = TRUE),
    error = function(e) cli::cli_abort(
      c(error_title, "x" = "Invalid JSON syntax"),
      parent = e,
      class = c(error_class, "xpipe_json_invalid", "xpipe_json_error", "xpipe_error")
    )
  )
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
    cli::cli_abort(
      c("Invalid configuration", "x" = "Missing {.field paths}"),
      class = c("xpipe_local_paths", "xpipe_local_error", "xpipe_error")
    )
  }

  local_config$paths <- lapply(local_config$paths, function(p) {
    p <- fs::path_expand(p)
    p <- if (fs::is_absolute_path(p)) fs::path_norm(p)
    else fs::path_norm(fs::path(project_root, p))

    if (!fs::dir_exists(p)) {
      cli::cli_abort(
        c("Invalid configuration path", "x" = "Path {.file {p}} does not exist"),
        class = c("xpipe_local_paths", "xpipe_local_error", "xpipe_error")
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

  if (!checkmate::test_string(batch_path, min.chars = 1)) {
    cli::cli_abort(
      c("Invalid configuration", "x" = "Batch layer path not set", "i" = "Expected field: paths.batch"),
      class = c("xpipe_batch_paths", "xpipe_batch_error", "xpipe_error")
    )
  }

  if (!fs::dir_exists(batch_path)) {
    cli::cli_abort(
      c(
        "Invalid Batch layer",
        "x" = "Batch layer directory does not exist",
        "i" = "Path: {.file {batch_path}}"
      ),
      class = c("xpipe_batch_paths", "xpipe_batch_error", "xpipe_error")
    )
  }

  layer_json <- fs::path(batch_path, "layer.json")
  if (!fs::file_exists(layer_json)) {
    cli::cli_abort(
      c(
        "Invalid Batch layer metadata",
        "x" = "Required file {.file layer.json} not found",
        "i" = "Expected: layer.json in {.file {batch_path}}"
      ),
      class = c("xpipe_batch_metadata", "xpipe_batch_error", "xpipe_error")
    )
  }

  .validate_json_schema(
    json_path   = layer_json,
    schema_name = "batch_layer.schema.json",
    error_title = "Invalid Batch layer metadata",
    error_class = "xpipe_batch_metadata"
  )

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
  if (Sys.getenv("XPIPE_SKIP_HASH_CHECK") == "TRUE") {
    cli::cli_alert_warning("Bypassing Batch layer integrity hash check.")
    return(invisible(TRUE))
  }

  expected_hash <- layer_options$expected_hash

  if (!checkmate::test_string(expected_hash, min.chars = 1)) {
    cli::cli_abort(
      c("Invalid Batch layer metadata", "x" = "Missing {.field expected_hash} in layer.json"),
      class = c("xpipe_batch_metadata", "xpipe_batch_error", "xpipe_error")
    )
  }

  if (hash_phi(test_string, pepper) != expected_hash) {
    cli::cli_abort(
      c(
        "Invalid Batch layer metadata",
        "x" = "Hash mismatch. System will not start."
      ),
      class = c("xpipe_batch_hash", "xpipe_batch_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}



#' Conditionally print debug information based on local.json
#' @param text The string to print (supports cli formatting)
#' @param .envir The environment to evaluate the string in
#' @keywords internal
#' @noRd
.log_debug <- function(text, .envir = parent.frame()) {
  # 1. Check for manual script overrides first
  is_verbose <- getOption("xpipe.verbose")

  # 2. If no manual override, read from the loaded local.json
  if (is.null(is_verbose)) {
    # Safely retrieve the active config from the package environment
    cfg <- tryCatch(get_xpipe_config(), error = function(e) NULL)

    # Check if the JSON level is explicitly set to "debug"
    is_verbose <- !is.null(cfg) && identical(cfg$local$logging$level, "debug")
  }

  # 3. Print only if debug is enabled
  if (isTRUE(is_verbose)) {
    msg <- c("[DEBUG] ", text)
    cli::cli_inform(msg, .envir = .envir)
  }
}


# S3 Print Methods --------------------------------------------------------------

#' Render Configuration Gracefully
#'
#' Provides a structured console summary of the active control-plane
#' configuration.
#'
#' @param x An S3 object of class \code{xpipe_config}.
#' @param ... Additional arguments (ignored).
#' @noRd
.render_config <- function(x, ...) {
  cli::cli_div(
    theme = list(
      rule = list(color = "cyan", "line-type" = "double")
    )
  )
  cli::cli_rule("Configuration", right = "xpipe")

  pad_nbsp <- function(x, w) gsub(" ", "\u00a0", format(x, width = w))

  # 1. RUNTIME CONTEXT
  cli::cli_h2("Runtime Context")


  cli::cli_bullets(c(
    "{pad_nbsp('Loaded at', 10)}: {.field {format(x$runtime$loaded_at)}}",
    "{pad_nbsp('Security', 10)}: HMAC-SHA256 (Masked Pepper: {.envvar {substr(x$runtime$pepper, 1, 4)}}...)"
  ))


  # 2. LOCAL INFRASTRUCTURE
  cli::cli_h2("Local Infrastructure")
  if (!is.null(x$local$paths)) {
    cli::cli_bullets(
      purrr::imap_chr(
        x$local$paths,
        ~ paste0("{pad_nbsp('", .y, "', 10)}: {.file ", .x, "}")
      )
    )
  }

  # 3. STREAMS CONTRACT (Semantic Truth)
  cli::cli_h2("Streams Contract")
  if (!is.null(x$streams_meta)) {
    cli::cli_bullets(c(
      "{pad_nbsp('Contract type', 13)}: {.field {x$streams_meta$type}}",
      "{pad_nbsp('Version', 13)}: {.field {x$streams_meta$version}}",
      "{pad_nbsp('Maintainer', 13)}: {.field {x$streams_meta$maintainer}}",
      "{pad_nbsp('Last updated', 13)}: {.field {x$streams_meta$last_updated}}"
    ))
  }



  if (!is.null(x$streams)) {
    nms <- names(x$streams)
    labels <- purrr::map_chr(x$streams, "label")
    domains <- purrr::map_chr(x$streams, "schema_domain")
    anchors <- purrr::map_chr(x$streams, "anchor")
    parts <- purrr::map_chr(x$streams, "partition_granularity")

    w_nm  <- max(nchar(nms), nchar("STREAM"))
    w_lbl <- max(nchar(labels), nchar("LABEL"))
    w_dom <- max(nchar(domains), nchar("DOMAIN"))
    w_anc <- max(nchar(anchors), nchar("ANCHOR"))

    # 1. Format the header with ANSI styling via inline formatting
    header <- cli::format_inline(
      "{.strong {format('STREAM', width = w_nm)}   {format('LABEL', width = w_lbl)}   {format('DOMAIN', width = w_dom)}   {format('ANCHOR', width = w_anc)}   PARTITION}"
    )

    # 2. Build the unstyled rows
    table_rows <- purrr::pmap_chr(
      list(nms, labels, domains, anchors, parts),
      function(nm, lbl, dom, anc, part) {
        paste(
          format(nm, width = w_nm),
          format(lbl, width = w_lbl),
          format(dom, width = w_dom),
          format(anc, width = w_anc),
          part,
          sep = "   "
        )
      }
    )

    # 3. Combine and print inside a box
    # cat_boxx handles the printing automatically
    cli::cat_boxx(
      c(header, table_rows),
      header = "Streams",
      border_style = "round",
      padding = c(top = 0, right = 2, bottom = 0, left = 2),
      float = "left",
      border_col = "cyan" # Optional: color the box border itself
    )
  }



  # 4. METHODS CONTRACT (Ingestion Mechanics)
  cli::cli_h2("Methods Contract")
  if (!is.null(x$methods)) {
    nms <- names(x$methods)
    domains <- purrr::map_chr(x$methods, "schema_domain")
    types <- purrr::map_chr(x$methods, "type")

    w_nm  <- max(nchar(nms), nchar("METHOD"))
    w_dom <- max(nchar(domains), nchar("DOMAIN"))

    header <- cli::format_inline(
      "{.strong {format('METHOD', width = w_nm)}   {format('DOMAIN', width = w_dom)}   TYPE}"
    )

    table_rows <- purrr::pmap_chr(
      list(nms, domains, types),
      function(nm, dom, type) {
        paste(
          format(nm, width = w_nm),
          format(dom, width = w_dom),
          type, # Dropping the brackets '[' and ']' since the column header makes it clear
          sep = "   "
        )
      }
    )

    cli::cat_boxx(
      c(header, table_rows),
      header = "Methods",
      border_style = "round",
      padding = c(top = 0, right = 2, bottom = 0, left = 2),
      float = "left",
      border_col = "cyan"
    )
  }

  # 5. BATCH LAYER STATUS
  cli::cli_alert_success("Batch layer metadata validated and trusted.")

  cli::cli_rule()
  cli::cli_end()

  invisible(x)
}

#' Print xpipe_config
#'
#' @param x xpipe_config object.
#' @param ... Ignored.
#' @noRd
print.xpipe_config <- function(x, ...) {
  .render_config(x, ...)
}

