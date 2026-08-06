# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# core_org.R
#
# Shared organizational registry loading and validation.
#
# These files are shared XNE resources, not package-owned data and not
# medallion layers. They describe organizational master data used for
# enrichment and analytical reporting.
#
# Public API:  load_departments(), validate_departments(),
#              validate_org_registry()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Error Class Taxonomy --------------------------------------------------------
#
#   ├── xpipe_org_error                # shared organizational registry errors
#   │   ├── xpipe_org_missing          # registry file missing
#   │   ├── xpipe_org_parse            # CSV parsing failure
#   │   └── xpipe_org_departments      # invalid departments.csv

# Public API ---------------------------------------------------------------

#' Load Departments Registry
#'
#' Loads the shared departments registry from the active XNE project.
#'
#' Expected path:
#' `<xne_root>/data/shared/org/departments.csv`
#'
#' @param validate Logical. If TRUE, validate the registry after loading.
#' @return A tibble with departments metadata.
#' @export
load_departments <- function(validate = TRUE) {
  checkmate::assert_flag(validate)

  cfg <- get_xpipe_config()
  path <- fs::path(cfg$xne$paths$shared, "org", "departments.csv")

  if (!fs::file_exists(path)) {
    cli::cli_abort(
      c(
        "Departments registry not found",
        "x" = "Expected file: {.file {path}}"
      ),
      class = c("xpipe_org_missing", "xpipe_org_error", "xpipe_error")
    )
  }

  departments <- rlang::try_fetch(
    readr::read_csv(
      file = path,
      col_types = readr::cols(
        department_id = readr::col_integer(),
        department_name = readr::col_character(),
        valid_from = readr::col_date(),
        valid_to = readr::col_date()
      ),
      show_col_types = FALSE
    ),
    error = function(e) {
      cli::cli_abort(
        c(
          "Failed to read departments registry",
          "x" = "File {.file {path}} could not be parsed as CSV."
        ),
        parent = e,
        class = c("xpipe_org_parse", "xpipe_org_error", "xpipe_error")
      )
    }
  )

  if (isTRUE(validate)) {
    validate_departments(departments)
  }

  departments
}


#' Validate Departments Registry
#'
#' Validates the departments shared registry.
#'
#' @param departments A data frame loaded from departments.csv.
#' @return Invisibly TRUE.
#' @export
validate_departments <- function(departments) {
  checkmate::assert_data_frame(departments)

  required_cols <- c(
    "department_id",
    "department_name",
    "valid_from",
    "valid_to"
  )

  missing_cols <- setdiff(required_cols, names(departments))

  if (length(missing_cols) > 0) {
    cli::cli_abort(
      c(
        "Invalid departments registry",
        "x" = "Missing required columns: {.val {missing_cols}}"
      ),
      class = c("xpipe_org_departments", "xpipe_org_error", "xpipe_error")
    )
  }

  if (nrow(departments) == 0) {
    cli::cli_abort(
      c(
        "Invalid departments registry",
        "x" = "Registry is empty."
      ),
      class = c("xpipe_org_departments", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_id <- is.na(departments$department_id)

  if (any(bad_id)) {
    cli::cli_abort(
      c(
        "Invalid departments registry",
        "x" = "Column {.field department_id} contains missing values."
      ),
      class = c("xpipe_org_departments", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_name <- is.na(departments$department_name) |
    trimws(departments$department_name) == ""

  if (any(bad_name)) {
    cli::cli_abort(
      c(
        "Invalid departments registry",
        "x" = "Column {.field department_name} contains missing or empty values."
      ),
      class = c("xpipe_org_departments", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_valid_from <- is.na(departments$valid_from)

  if (any(bad_valid_from)) {
    cli::cli_abort(
      c(
        "Invalid departments registry",
        "x" = "Column {.field valid_from} contains missing or invalid dates."
      ),
      class = c("xpipe_org_departments", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_valid_to <- !is.na(departments$valid_to) &
    departments$valid_to < departments$valid_from

  if (any(bad_valid_to)) {
    cli::cli_abort(
      c(
        "Invalid departments registry",
        "x" = "Some {.field valid_to} values are earlier than {.field valid_from}."
      ),
      class = c("xpipe_org_departments", "xpipe_org_error", "xpipe_error")
    )
  }

  .validate_no_department_period_overlap(departments)

  invisible(TRUE)
}


#' Validate Full Organizational Registry
#'
#' Validates shared organizational registries available in the XNE project.
#'
#' Currently validates:
#' - departments.csv
#'
#' @return Invisibly TRUE.
#' @export
validate_org_registry <- function() {
  departments <- load_departments(validate = FALSE)
  validate_departments(departments)

  cli::cli_alert_success("Organizational registry validated.")

  invisible(TRUE)
}


# Internal Helpers ---------------------------------------------------------

#' Validate No Overlapping Department Validity Periods
#'
#' @param departments Departments registry.
#' @return Invisibly TRUE.
#' @noRd
.validate_no_department_period_overlap <- function(departments) {
  x <- departments |>
    dplyr::mutate(
      valid_to_check = dplyr::coalesce(
        .data$valid_to,
        as.Date("9999-12-31")
      )
    ) |>
    dplyr::arrange(
      .data$department_id,
      .data$valid_from,
      .data$valid_to_check
    ) |>
    dplyr::group_by(.data$department_id) |>
    dplyr::mutate(
      previous_valid_to = dplyr::lag(.data$valid_to_check),
      overlaps_previous = !is.na(.data$previous_valid_to) &
        .data$valid_from <= .data$previous_valid_to
    ) |>
    dplyr::ungroup()

  overlaps <- x |>
    dplyr::filter(.data$overlaps_previous)

  if (nrow(overlaps) > 0) {
    bad_ids <- sort(unique(overlaps$department_id))

    cli::cli_abort(
      c(
        "Invalid departments registry",
        "x" = "Overlapping validity periods found for department_id: {.val {bad_ids}}"
      ),
      class = c("xpipe_org_departments", "xpipe_org_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}
