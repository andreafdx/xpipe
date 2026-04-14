# ======================================================================= #
# FILE: src/fnc/config.R
#
# System configuration and YAML options
#
# ======================================================================= #

box::use(
  yaml[read_yaml],
  fs,
  . / crypto[.hash_phi]
)


#' Read YAML Configuration
#'
#' Safely reads a YAML file and converts it to a list. Throws a classed
#' error if the file is missing or contains invalid YAML syntax.
#'
#' @param path Character scalar. Path to the YAML file.
#' @return A named list.
#' @keywords internal
.read_yaml <- function(path = "inst/_xne/xacc.yml") {
  if (!fs::file_exists(path)) {
    cli::cli_abort("Config file not found: {.file {path}}")
  }

  config <- tryCatch(
    yaml::read_yaml(path),
    error = function(e) {
      cli::cli_abort(
        "Invalid YAML in config file {.file {path}}\n{e$message}"
      )
    }
  )

  return(config)
}

#' Normalize Configuration Paths
#'
#' Processes the configuration list to ensure all filesystem paths are
#' absolute and normalized.
#'
#' Key operations:
#' \itemize{
#'   \item Resolves relative paths against \code{project_root}.
#'   \item Validates that medallion root folders exist (aborts if not).
#'   \item Checks existence of other paths (warns if not).
#' }
#'
#' @param config List. The raw configuration from \code{.read_yaml()}.
#' @param project_root Character scalar. Base path for relative resolution.
#' @return The normalized configuration list.
#'
#' @section Conditions:
#' Signals conditions with the class \code{yaml_options} (and sub-classes
#' like \code{paths}, \code{medallion}, or \code{logging}).
#'
#' @keywords internal
.normalize_paths <- function(config, project_root = NULL) {
  if (is.null(project_root)) {
    project_root <- fs::path_abs(".") # current working directory
  }

  # paths in the YAML file don't really need normalization
  # as long they are under project root folder, but it's ok
  # to normalize them anyway, just in case I need this in the future
  # This is mostly an exercise to get familiar with fs package.

  if (!is.null(config$paths)) {
    config$paths <- lapply(config$paths, function(p) {
      p <- fs::path_expand(p) # expand tilde (~) and environment variables
      if (fs::is_absolute_path(p)) {
        p <- fs::path_norm(p)
      } else {
        p <- fs::path_norm(fs::path(project_root, p))
      }

      if (!fs::dir_exists(p)) {
        cli::cli_alert_warning(
          "Path {.file {p}} does not exist yet.",
          class = c("yaml_options", "paths")
        )
      }
      return(p)
    })
  }

  # Medallion paths are different because I expect to have them
  # on a different folder than project root, mostly on Sharepoint,
  # so I gave the option to define a root folder for medallion data
  # and a folder specifier for medallion layers (bronze, silver, gold)
  if (!is.null(config$medallion)) {
    root <- fs::path_norm(
      fs::path_expand(config$medallion$root)
    )
    if (!fs::dir_exists(root)) {
      cli::cli_abort(
        "Root medallion path {.file {root}} does not exist.",
        class = c("yaml_options", "medallion")
      )
    }
    config$medallion$root <- root

    for (nm in setdiff(names(config$medallion), "root")) {
      p <- fs::path_norm(fs::path(root, config$medallion[[nm]]))
      if (!fs::dir_exists(p)) {
        cli::cli_alert_warning(
          "Path {.file {p}} does not exist yet.",
          class = c("yaml_options", "medallion")
        )
      }
      config$medallion[[nm]] <- p
    }
  }

  # Normalize pahs for logging too, because why not
  if (!is.null(config$logging$path)) {
    p <- fs::path_norm(
      fs::path(project_root, config$logging$path)
    )
    if (!fs::dir_exists(p)) {
      cli::cli_alert_warning(
        "Path {.file {p}} does not exist yet.",
        class = c("yaml_options", "logging")
      )
    }
    config$logging$path <- p
  }

  return(config)
}

#' Validate Datastream Logic
#'
#' Checks that the logical properties of each datastream (like 'alt' and
#' 'time_block') adhere to the expected schemas.
#'
#' Validation rules:
#' \itemize{
#'   \item \code{alt} must be either TRUE or FALSE.
#'   \item \code{time_block} must be either 'y' (yearly) or 'q' (quarterly).
#' }
#'
#' @param config List. The configuration list.
#' @return The configuration list.
#'
#' @section Conditions:
#' Signals \code{yaml_options} errors of class \code{datastream} if
#' validation fails.
#'
#' @keywords internal
.validate_datastream <- function(config) {
  if (!is.null(config$datastream)) {
    for (nm in names(config$datastream)) {
      alt_val <- config$datastream[[nm]]$alt
      if (is.null(alt_val) || !is.logical(alt_val)) {
        cli::cli_abort(
          c(
            "Invalid value for {.field alt} in datastream {.val {nm}}",
            "x" = "Value must be TRUE or FALSE, but found {.val {alt_val}}."
          ),
          class = c("yaml_options", "datastream")
        )
      }
      time_block_val <- config$datastream[[nm]]$time_block
      if (is.null(time_block_val) || !(time_block_val %in% c("y", "q"))) {
        cli::cli_abort(
          c(
            "Invalid value for {.field time_block} in datastream {.val {nm}}",
            "x" = "Value must be 'y' or 'q', but found {.val {time_block_val}}"
          ),
          class = c("yaml_options", "datastream")
        )
      }
    }
  }

  return(config)
}

#' Validate Cryptographic Hash
#'
#' Verifies the system integrity by hashing a test string with the pepper
#' and comparing it against an expected value in the configuration.
#'
#' @param config List. The configuration list (must have runtime$pepper).
#' @param test_string Character scalar. The string to hash for testing.
#' @return None. Aborts if verification fails.
#' @keywords internal
.validate_hash <- function(config, test_string = "byut5f778DfOPth567") {
  if (
    is.null(config$crypto$expected_hash) || config$crypto$expected_hash == ""
  ) {
    cli::cli_abort(
      "Expected hash not found. Impossible to start the system without the hash.",
      class = c("yaml_options", "crypto")
    )
  }
  hash <- .hash_phi(test_string, config$runtime$pepper)
  if (hash != config$crypto$expected_hash) {
    cli::cli_abort(
      "Hash mismatch. The system will not start.",
      class = c("yaml_options", "crypto")
    )
  }
}

#' Load and Validate Configuration
#'
#' Orchestrates the full loading process: reading YAML, injecting runtime
#' variables, normalizing paths, and validating business logic and integrity.
#'
#' @param path Character scalar. Path to the YAML file.
#' @param project_root Character scalar. Base path for relative resolution.
#' @return The fully validated configuration list.
#'
#' @keywords internal
.load_options <- function(
  path = "inst/_xne/xacc.yml",
  project_root = NULL
) {
  cli::cli_alert_info("Loading configuration...")

  # 1. Read YAML
  config <- .read_yaml(path)
  cli::cli_alert_success("Configuration YAML loaded.")

  # 2. Inject Pepper & Validate Integrity
  config$runtime <- list()
  config$runtime$pepper <- Sys.getenv("XNE_PEPPER_KEY")
  if (config$runtime$pepper == "" || is.null(config$runtime$pepper)) {
    cli::cli_abort(
      "{.envvar XNE_PEPPER_KEY} not found in .Renviron.
      Impossible to start the system without the encryption key.",
      class = c("config", "runtime", "crypto")
    )
  }
  .validate_hash(config)
  cli::cli_alert_success("Encryption key (Pepper) and integrity hash verified.")

  # 3. Normalize paths
  config <- .normalize_paths(config, project_root)
  cli::cli_alert_success("Paths normalized and checked.")

  # 4. Validate Logic
  config <- .validate_datastream(config)
  cli::cli_alert_success("Datastream validation completed.")

  return(config)
}
