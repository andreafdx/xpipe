# ======================================================================= #
# FILE: src/fnc/setup.R
#
# System setup
#
# ======================================================================= #

box::use(
  yaml[read_yaml],
  fs
)


#' Load and normalize YAML configuration
#'
#' Reads a YAML configuration file, validates its existence, and normalizes
#' all filesystem paths in a platform-independent way. Relative paths are
#' resolved against the project root, while absolute paths are preserved.
#'
#' The loader ensures:
#' \itemize{
#'   \item clean failure on missing or invalid YAML files
#'   \item normalized paths (Windows / Unix compatible)
#'   \item consistent datastream versions as character vectors
#' }
#'
#' @param path Character scalar. Path to the YAML configuration file.
#' @param project_root Character scalar. Project root used to resolve relative
#'   paths. Defaults to the current working directory.
#'
#' @return A named list containing the parsed and normalized configuration.
#'
#' @details
#' This function performs all path resolution in one place. After calling
#' \code{.load_config()}, the rest of the codebase should only consume the
#' returned paths and never manipulate filesystem paths directly.
#'
#' @examples
#' \dontrun{
#' config <- .load_config("inst/.xne/xacc.yml")
#' config$paths$inbox
#' config$medallion$raw
#' }
#'
#' @keywords internal
.load_config <- function(path, project_root = NULL) {

  # --- file exists
  if (!fs::file_exists(path)) {
    cli::cli_abort("Config file not found: {.file {path}}")
  }

  # --- read yaml
  config <- tryCatch(
    yaml::read_yaml(path),
    error = function(e) {
      cli::cli_abort(
        "Invalid YAML in config file {.file {path}}\n{e$message}"
      )
    }
  )

  # --- project root
  if (is.null(project_root)) {
    project_root <- fs::path_abs(".")
  }

  # --- normalize paths
  if (!is.null(config$paths)) {
    config$paths <- lapply(config$paths, function(p) {
      p <- fs::path_expand(p)
      if (fs::is_absolute_path(p)) {
        fs::path_norm(p)
      } else {
        fs::path_norm(fs::path(project_root, p))
      }
    })
  }

  # --- medallion paths
  if (!is.null(config$medallion)) {

    root <- fs::path_norm(
      fs::path_expand(config$medallion$root)
    )

    config$medallion$root <- root

    for (nm in setdiff(names(config$medallion), "root")) {
      p <- config$medallion[[nm]]
      config$medallion[[nm]] <- fs::path_norm(fs::path(root, p))
    }
  }

  # --- logging path
  if (!is.null(config$logging$path)) {
    p <- config$logging$path
    config$logging$path <- fs::path_norm(
      fs::path(project_root, p)
    )
  }

  # --- datastream: versions always vector
  if (!is.null(config$datastream)) {
    for (nm in names(config$datastream)) {
      v <- config$datastream[[nm]]$versions
      config$datastream[[nm]]$versions <- as.character(v)
    }
  }

  return(config)
}






