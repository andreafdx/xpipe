# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# core_installer.R
#
# Project initialization and folder structure installer for XNE workspaces.
#
# Approach: Recreates the canonical XNE directory layout, populates configuration
# and contract JSON files from internal package assets, calculates the batch layer
# HMAC integrity hash, and updates creation timestamps.
#
# Public API:  init_xne_project()
# Internals:   .confirm_overwrite(), .write_json_pretty()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Error Class Taxonomy --------------------------------------------------------
#
#   xpipe_error
#   └── xpipe_installer_error
#       ├── xpipe_installer_path      # directory creation or overwrite conflict
#       ├── xpipe_installer_cancelled # user declined overwrite confirmation
#       └── xpipe_installer_pepper    # pepper missing when batch hash required

# Public API ------------------------------------------------------------------

#' Initialize an XNE Project Workspace
#'
#' Recreates the canonical XNE directory structure (`inbox`, `logs`, `data/shared`,
#' `data/batch`, `data/bronze`, `data/silver`), populates configuration and
#' contract JSON files, updates layer creation timestamps, and generates
#' the required Batch layer integrity hash using the runtime pepper.
#'
#' @param path Character scalar. Mandatory path to target directory.
#' @param overwrite Logical scalar. Whether to overwrite existing project files
#'   if they already exist (default `FALSE`).
#' @param pepper Character scalar. HMAC key to compute Batch layer hash. If `NULL`,
#'   the environment variable `XNE_PEPPER_KEY` is used.
#'
#' @return The validated \code{xpipe_config} object invisibly.
#' @export
init_xne_project <- function(path, overwrite = FALSE, pepper = NULL) {
  rlang::check_required(path)
  checkmate::assert_string(path, min.chars = 1)
  checkmate::assert_flag(overwrite)
  checkmate::assert_string(pepper, null.ok = TRUE)

  target_root <- fs::path_abs(path)
  pepper_key <- pepper %||% Sys.getenv("XNE_PEPPER_KEY", unset = NA_character_)

  if (!checkmate::test_string(pepper_key, min.chars = 1)) {
    cli::cli_abort(
      c(
        "Cannot initialize XNE project",
        "x" = "Environment variable {.envvar XNE_PEPPER_KEY} not set and no pepper supplied.",
        "i" = "Provide a valid pepper string or set {.envvar XNE_PEPPER_KEY}."
      ),
      class = c("xpipe_installer_pepper", "xpipe_installer_error", "xpipe_error")
    )
  }

  xne_json_path <- fs::path(target_root, "xne.json")
  if (fs::file_exists(xne_json_path)) {
    if (!overwrite) {
      cli::cli_abort(
        c(
          "Cannot initialize XNE project",
          "x" = "Project file {.file {xne_json_path}} already exists.",
          "i" = "Set {.code overwrite = TRUE} to overwrite existing project files."
        ),
        class = c("xpipe_installer_path", "xpipe_installer_error", "xpipe_error")
      )
    }

    .confirm_overwrite(target_root)
  }

  # 1. Directory Tree Creation
  dirs_to_create <- c(
    fs::path(target_root, "inbox"),
    fs::path(target_root, "logs"),
    fs::path(target_root, "data", "shared"),
    fs::path(target_root, "data", "batch"),
    fs::path(target_root, "data", "bronze"),
    fs::path(target_root, "data", "silver")
  )
  purrr::walk(dirs_to_create, fs::dir_create)

  today <- format(Sys.Date(), "%Y-%m-%d")

  # 2. Root xne.json Creation
  xne_template_path <- .find_asset("xne.local.json")
  xne_cfg <- jsonlite::fromJSON(xne_template_path, simplifyVector = FALSE)
  xne_cfg$meta$created_at <- today
  xne_cfg$meta$last_updated_at <- today
  .write_json_pretty(xne_cfg, xne_json_path)

  # 3. Shared Contracts Population
  shared_dir <- fs::path(target_root, "data", "shared")
  shared_files <- c("streams.json", "methods.json", "silver.json")
  for (sf in shared_files) {
    src_file <- .find_asset("templates", "shared", sf)
    dest_file <- fs::path(shared_dir, sf)
    if (!fs::file_exists(dest_file) || overwrite) {
      fs::file_copy(src_file, dest_file, overwrite = TRUE)
    }
  }

  # 4. Layer Metadata Population
  # Batch Layer
  batch_json_path <- fs::path(target_root, "data", "batch", "layer.json")
  batch_template_path <- .find_asset("templates", "batch_layer.json")
  batch_meta <- jsonlite::fromJSON(batch_template_path, simplifyVector = FALSE)
  batch_meta$created_at <- today
  batch_meta$expected_hash <- hash_phi("byut5f778DfOPth567", pepper_key)
  .write_json_pretty(batch_meta, batch_json_path)

  # Bronze Layer
  bronze_json_path <- fs::path(target_root, "data", "bronze", "layer.json")
  bronze_template_path <- .find_asset("templates", "bronze_layer.json")
  bronze_meta <- jsonlite::fromJSON(bronze_template_path, simplifyVector = FALSE)
  bronze_meta$created_at <- today
  .write_json_pretty(bronze_meta, bronze_json_path)

  # Silver Layer
  silver_json_path <- fs::path(target_root, "data", "silver", "layer.json")
  silver_template_path <- .find_asset("templates", "silver_layer.json")
  silver_meta <- jsonlite::fromJSON(silver_template_path, simplifyVector = FALSE)
  silver_meta$created_at <- today
  .write_json_pretty(silver_meta, silver_json_path)

  cli::cli_alert_success("XNE project structure initialized at {.file {target_root}}.")

  # 5. Config Load Validation
  # Temporarily ensure XNE_PEPPER_KEY is present in env if passed explicitly
  old_env_pepper <- Sys.getenv("XNE_PEPPER_KEY", unset = NA)
  Sys.setenv(XNE_PEPPER_KEY = pepper_key)
  on.exit({
    if (is.na(old_env_pepper)) {
      Sys.unsetenv("XNE_PEPPER_KEY")
    } else {
      Sys.setenv(XNE_PEPPER_KEY = old_env_pepper)
    }
  }, add = TRUE)

  config <- load_xpipe_config(path = xne_json_path, project_root = target_root)
  invisible(config)
}


# Internal API ----------------------------------------------------------------

#' Confirm Project Overwrite Interactively
#'
#' Displays a detailed CLI warning explaining all consequences of overwriting
#' an existing project and prompts the user to type exact word 'yes'.
#'
#' @param target_root Absolute path to project root.
#' @noRd
.confirm_overwrite <- function(target_root) {
  if (interactive()) {
    cli::cli_div(theme = list(rule = list(color = "red", "line-type" = "double")))
    cli::cli_rule(cli::format_inline("{.strong OVERWRITE WARNING}"), right = "xpipe")

    cli::cli_alert_danger(
      "You have selected to overwrite an existing XNE project workspace at {.file {target_root}}."
    )

    cli::cli_bullets(c(
      "!" = "Root configuration file {.file xne.json} will be reset.",
      "!" = "Shared contracts ({.file streams.json}, {.file methods.json}, {.file silver.json}) in {.file data/shared} will be overwritten with default assets.",
      "!" = "Medallion layer metadata ({.file layer.json} in batch, bronze, and silver) will be regenerated.",
      "!" = "Any customized contracts, historical pipeline logs, and layer integrity state will be permanently lost."
    ))

    cli::cli_rule()
    cli::cli_end()

    response <- readline(prompt = "Type exact word 'yes' to confirm and proceed: ")
    clean_response <- trimws(tolower(response))

    if (!identical(clean_response, "yes")) {
      cli::cli_abort(
        c(
          "Project initialization cancelled",
          "x" = "Confirmation answer was {.val {response}} instead of {.val yes}.",
          "i" = "No files were modified."
        ),
        class = c("xpipe_installer_cancelled", "xpipe_installer_error", "xpipe_error")
      )
    }
  }
  invisible(TRUE)
}

#' Write Data Structure to Pretty-Printed JSON
#'
#' @param data R object (list/dict) to serialize.
#' @param path Target file path.
#' @noRd
.write_json_pretty <- function(data, path) {
  jsonlite::write_json(
    data,
    path,
    pretty = TRUE,
    auto_unbox = TRUE
  )
}
