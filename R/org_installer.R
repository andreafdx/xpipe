# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# org_installer.R
#
# Optional installer for XNE organizational registry templates.
#
# The organizational registry is a curated shared XNE resource, not a core
# control-plane contract and not a medallion data layer. For this reason,
# org registry installation is handled separately from init_xne_project().
#
# This module installs template CSV files under:
# <xne_root>/data/shared/org/
#
# Public API:  init_xne_org_registry()
# Internals:   .confirm_org_overwrite()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Error Class Taxonomy --------------------------------------------------------
#
# All errors in this file inherit from `xpipe_error` through
# `xpipe_installer_error`, because org registry installation is still an
# installer operation even if it is optional and separated from core project
# initialization.
#
# Hierarchy:
#
#   xpipe_error
#   └── xpipe_installer_error
#       ├── xpipe_installer_path       # invalid project path, missing root, or existing files without overwrite
#       ├── xpipe_installer_cancelled  # user declined overwrite confirmation
#       └── xpipe_org_installer_error  # organizational registry template install failure
#
# Notes:
#   - Existing org registry files are never overwritten unless explicitly
#     requested with overwrite = TRUE.
#   - Org overwrite confirmation is separate from core XNE overwrite
#     confirmation because org files may contain curated local master data.

# Public API ------------------------------------------------------------------

#' Initialize XNE Organizational Registry Templates
#'
#' Installs example organizational registry CSV files into:
#' <xne_root>/data/shared/org/
#'
#' This is optional and separate from init_xne_project() because organizational
#' registries are curated XNE resources and should not be overwritten as part
#' of general project reinstallation.
#'
#' @param path Character scalar. Path to the XNE project root.
#' @param overwrite Logical scalar. Whether to overwrite existing org registry files.
#' @param confirm Logical scalar. Whether to ask for confirmation before overwriting.
#'
#' @return Invisibly TRUE.
#' @export
init_xne_org_registry <- function(
  path,
  overwrite = FALSE,
  confirm = interactive()
) {
  rlang::check_required(path)
  checkmate::assert_string(path, min.chars = 1)
  checkmate::assert_flag(overwrite)
  checkmate::assert_flag(confirm)

  target_root <- fs::path_abs(path)
  org_dir <- fs::path(target_root, "data", "shared", "org")

  if (!fs::dir_exists(target_root)) {
    cli::cli_abort(
      c(
        "Cannot initialize organizational registry",
        "x" = "Project root {.file {target_root}} does not exist."
      ),
      class = c("xpipe_installer_path", "xpipe_installer_error", "xpipe_error")
    )
  }

  fs::dir_create(org_dir)

  org_files <- c(
    "organizations.csv",
    "structures.csv",
    "facilities.csv",
    "departments.csv",
    "units.csv",
    "unit_codes.csv"
  )

  dest_files <- fs::path(org_dir, org_files)
  existing_files <- dest_files[fs::file_exists(dest_files)]

  if (length(existing_files) > 0 && !overwrite) {
    cli::cli_abort(
      c(
        "Cannot initialize organizational registry",
        "x" = "Some registry files already exist.",
        "i" = "Existing files: {.file {existing_files}}",
        "i" = "Set {.code overwrite = TRUE} to overwrite them."
      ),
      class = c("xpipe_installer_path", "xpipe_installer_error", "xpipe_error")
    )
  }

  if (length(existing_files) > 0 && overwrite && confirm) {
    .confirm_org_overwrite(existing_files)
  }

  for (of in org_files) {
    src_file <- .find_asset("templates", "shared", "org", of)
    dest_file <- fs::path(org_dir, of)

    if (!fs::file_exists(dest_file) || overwrite) {
      fs::file_copy(src_file, dest_file, overwrite = TRUE)
    }
  }

  cli::cli_alert_success(
    "Organizational registry templates initialized at {.file {org_dir}}."
  )

  invisible(TRUE)
}


# Internal API ----------------------------------------------------------------

#' Confirm Organizational Registry Overwrite Interactively
#'
#' @param files Character vector of files that would be overwritten.
#' @return Invisibly TRUE.
#' @noRd
.confirm_org_overwrite <- function(files) {
  if (interactive()) {
    cli::cli_div(
      theme = list(rule = list(color = "red", "line-type" = "double"))
    )
    cli::cli_rule(
      cli::format_inline("{.strong ORG REGISTRY OVERWRITE WARNING}"),
      right = "xpipe"
    )

    cli::cli_alert_danger(
      "You are about to overwrite existing organizational registry files."
    )

    cli::cli_bullets(c(
      "!" = "These files may contain curated local master data.",
      "!" = "Departments, units, and unit code mappings may be permanently replaced by templates.",
      "!" = "This operation is separate from core XNE project installation."
    ))

    cli::cli_bullets(stats::setNames(
      paste0("{.file ", files, "}"),
      rep("x", length(files))
    ))

    cli::cli_rule()
    cli::cli_end()

    response <- readline(
      prompt = "Type exact word 'org' to confirm and proceed: "
    )
    clean_response <- trimws(tolower(response))

    if (!identical(clean_response, "org")) {
      cli::cli_abort(
        c(
          "Organizational registry initialization cancelled",
          "x" = "Confirmation answer was {.val {response}} instead of {.val org}.",
          "i" = "No org registry files were modified."
        ),
        class = c(
          "xpipe_installer_cancelled",
          "xpipe_installer_error",
          "xpipe_error"
        )
      )
    }
  }

  invisible(TRUE)
}
