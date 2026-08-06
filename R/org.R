# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# org.R
#
# Shared organizational registry loading and validation.
#
# These files are shared XNE resources, not package-owned data and not
# medallion layers. They describe organizational master data used for
# enrichment and analytical reporting.
#
# Public API:  load_departments(), load_units(), load_unit_codes(),
#              validate_org_registry()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Error Class Taxonomy --------------------------------------------------------
#
#   ├── xpipe_org_error                # shared organizational registry errors
#   │   ├── xpipe_org_missing          # registry file missing
#   │   ├── xpipe_org_parse            # CSV parsing failure
#   │   ├── xpipe_org_departments      # invalid departments.csv
#   │   ├── xpipe_org_units            # invalid units.csv
#   │   └── xpipe_org_unit_codes       # invalid unit_codes.csv

# Public API ------------------------------------------------------------------

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
    .validate_departments(departments)
  }

  departments
}

#' Load Units Registry
#'
#' Loads the shared units registry from the active XNE project.
#'
#' Expected path:
#' <xne_root>/data/shared/org/units.csv
#'
#' @param validate Logical. If TRUE, validate the registry after loading.
#' @return A tibble with unit metadata.
#' @export
load_units <- function(validate = TRUE) {
  checkmate::assert_flag(validate)

  cfg <- get_xpipe_config()
  path <- fs::path(cfg$xne$paths$shared, "org", "units.csv")

  if (!fs::file_exists(path)) {
    cli::cli_abort(
      c(
        "Units registry not found",
        "x" = "Expected file: {.file {path}}"
      ),
      class = c("xpipe_org_missing", "xpipe_org_error", "xpipe_error")
    )
  }

  units <- rlang::try_fetch(
    readr::read_csv(
      file = path,
      col_types = readr::cols(
        uo_id = readr::col_integer(),
        uo_name = readr::col_character(),
        uo_type = readr::col_character(),
        department_id = readr::col_integer(),
        valid_from = readr::col_date(),
        valid_to = readr::col_date()
      ),
      show_col_types = FALSE
    ),
    error = function(e) {
      cli::cli_abort(
        c(
          "Failed to read units registry",
          "x" = "File {.file {path}} could not be parsed as CSV."
        ),
        parent = e,
        class = c("xpipe_org_parse", "xpipe_org_error", "xpipe_error")
      )
    }
  )

  if (isTRUE(validate)) {
    .validate_units(units)
  }

  units
}

#' Load Unit Codes Registry
#'
#' Loads the shared unit codes registry from the active XNE project.
#'
#' Expected path:
#' <xne_root>/data/shared/org/unit_codes.csv
#'
#' @param validate Logical. If TRUE, validate the registry after loading.
#' @return A tibble with unit code metadata.
#' @export
load_unit_codes <- function(validate = TRUE) {
  checkmate::assert_flag(validate)

  cfg <- get_xpipe_config()
  path <- fs::path(cfg$xne$paths$shared, "org", "unit_codes.csv")

  if (!fs::file_exists(path)) {
    cli::cli_abort(
      c(
        "Unit codes registry not found",
        "x" = "Expected file: {.file {path}}"
      ),
      class = c("xpipe_org_missing", "xpipe_org_error", "xpipe_error")
    )
  }

  unit_codes <- rlang::try_fetch(
    readr::read_csv(
      file = path,
      col_types = readr::cols(
        unit_code = readr::col_character(),
        short_name = readr::col_character(),
        uo_id = readr::col_integer(),
        parent_unit_code = readr::col_character(),
        is_external = readr::col_logical(),
        in_week = readr::col_logical(),
        valid_from = readr::col_date(),
        valid_to = readr::col_date()
      ),
      na = c("", "NA"),
      show_col_types = FALSE
    ),
    error = function(e) {
      cli::cli_abort(
        c(
          "Failed to read unit codes registry",
          "x" = "File {.file {path}} could not be parsed as CSV."
        ),
        parent = e,
        class = c("xpipe_org_parse", "xpipe_org_error", "xpipe_error")
      )
    }
  )

  if (isTRUE(validate)) {
    .validate_unit_codes(unit_codes)
  }

  unit_codes
}


#' Validate Full Organizational Registry
#'
#' Validates shared organizational registries available in the XNE project.
#'
#' Currently validates:
#' - departments.csv
#' - units.csv
#' - unit_codes.csv
#'
#' @return Invisibly TRUE.
#' @export
validate_org_registry <- function() {
  departments <- load_departments(validate = FALSE)
  .validate_departments(departments)

  units <- load_units(validate = FALSE)
  .validate_units(units, departments = departments)

  unit_codes <- load_unit_codes(validate = FALSE)
  .validate_unit_codes(unit_codes, units = units)

  cli::cli_alert_success("Organizational registry validated.")

  invisible(TRUE)
}

# Internal Helpers ---------------------------------------------------------

#' Validate Departments Registry
#'
#' Validates the departments shared registry.
#'
#' @param departments A data frame loaded from departments.csv.
#' @return Invisibly TRUE.
#' @noRd
.validate_departments <- function(departments) {
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

#' Validate Units Registry
#'
#' Validates the units shared registry.
#'
#' @param units A data frame loaded from units.csv.
#' @param departments Optional departments data frame. If NULL, departments are loaded.
#' @return Invisibly TRUE.
#' @noRd
.validate_units <- function(units, departments = NULL) {
  checkmate::assert_data_frame(units)

  required_cols <- c(
    "uo_id",
    "uo_name",
    "uo_type",
    "department_id",
    "valid_from",
    "valid_to"
  )

  missing_cols <- setdiff(required_cols, names(units))

  if (length(missing_cols) > 0) {
    cli::cli_abort(
      c(
        "Invalid units registry",
        "x" = "Missing required columns: {.val {missing_cols}}"
      ),
      class = c("xpipe_org_units", "xpipe_org_error", "xpipe_error")
    )
  }

  if (nrow(units) == 0) {
    cli::cli_abort(
      c(
        "Invalid units registry",
        "x" = "Registry is empty."
      ),
      class = c("xpipe_org_units", "xpipe_org_error", "xpipe_error")
    )
  }

  if (any(is.na(units$uo_id))) {
    cli::cli_abort(
      c(
        "Invalid units registry",
        "x" = "Column {.field uo_id} contains missing values."
      ),
      class = c("xpipe_org_units", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_name <- is.na(units$uo_name) | trimws(units$uo_name) == ""

  if (any(bad_name)) {
    cli::cli_abort(
      c(
        "Invalid units registry",
        "x" = "Column {.field uo_name} contains missing or empty values."
      ),
      class = c("xpipe_org_units", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_type <- is.na(units$uo_type) |
    !(units$uo_type %in% c("UOC", "UOSD"))

  if (any(bad_type)) {
    cli::cli_abort(
      c(
        "Invalid units registry",
        "x" = "Column {.field uo_type} contains invalid values.",
        "i" = "Allowed values: {.val UOC}, {.val UOSD}"
      ),
      class = c("xpipe_org_units", "xpipe_org_error", "xpipe_error")
    )
  }

  if (any(is.na(units$department_id))) {
    cli::cli_abort(
      c(
        "Invalid units registry",
        "x" = "Column {.field department_id} contains missing values."
      ),
      class = c("xpipe_org_units", "xpipe_org_error", "xpipe_error")
    )
  }

  if (any(is.na(units$valid_from))) {
    cli::cli_abort(
      c(
        "Invalid units registry",
        "x" = "Column {.field valid_from} contains missing or invalid dates."
      ),
      class = c("xpipe_org_units", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_valid_to <- !is.na(units$valid_to) &
    units$valid_to < units$valid_from

  if (any(bad_valid_to)) {
    cli::cli_abort(
      c(
        "Invalid units registry",
        "x" = "Some {.field valid_to} values are earlier than {.field valid_from}."
      ),
      class = c("xpipe_org_units", "xpipe_org_error", "xpipe_error")
    )
  }

  if (is.null(departments)) {
    departments <- load_departments(validate = FALSE)
  }

  unknown_department_ids <- setdiff(
    unique(units$department_id),
    unique(departments$department_id)
  )

  if (length(unknown_department_ids) > 0) {
    cli::cli_abort(
      c(
        "Invalid units registry",
        "x" = "Unknown department_id values found: {.val {unknown_department_ids}}"
      ),
      class = c("xpipe_org_units", "xpipe_org_error", "xpipe_error")
    )
  }

  .validate_no_unit_period_overlap(units)

  invisible(TRUE)
}

#' Validate Unit Codes Registry
#'
#' Validates the unit codes shared registry.
#'
#' @param unit_codes A data frame loaded from unit_codes.csv.
#' @param units Optional units registry. If NULL, units are loaded.
#' @return Invisibly TRUE.
#' @noRd
.validate_unit_codes <- function(unit_codes, units = NULL) {
  checkmate::assert_data_frame(unit_codes)

  required_cols <- c(
    "unit_code",
    "short_name",
    "uo_id",
    "parent_unit_code",
    "is_external",
    "in_week",
    "valid_from",
    "valid_to"
  )

  missing_cols <- setdiff(required_cols, names(unit_codes))

  if (length(missing_cols) > 0) {
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Missing required columns: {.val {missing_cols}}"
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  if (nrow(unit_codes) == 0) {
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Registry is empty."
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_code <- is.na(unit_codes$unit_code) |
    trimws(unit_codes$unit_code) == ""

  if (any(bad_code)) {
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Column {.field unit_code} contains missing or empty values."
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_code_format <- !grepl("^[0-9]{4}$", unit_codes$unit_code)

  if (any(bad_code_format)) {
    bad_codes <- unique(unit_codes$unit_code[bad_code_format])

    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Invalid unit_code format found: {.val {bad_codes}}",
        "i" = "Expected 4-character numeric codes, preserving leading zeroes."
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_name <- is.na(unit_codes$short_name) |
    trimws(unit_codes$short_name) == ""

  if (any(bad_name)) {
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Column {.field short_name} contains missing or empty values."
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  if (any(is.na(unit_codes$uo_id))) {
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Column {.field uo_id} contains missing values."
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  if (any(is.na(unit_codes$is_external))) {
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Column {.field is_external} contains missing values."
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  if (any(is.na(unit_codes$valid_from))) {
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Column {.field valid_from} contains missing or invalid dates."
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_valid_to <- !is.na(unit_codes$valid_to) &
    unit_codes$valid_to < unit_codes$valid_from

  if (any(bad_valid_to)) {
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Some {.field valid_to} values are earlier than {.field valid_from}."
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  if (is.null(units)) {
    units <- load_units(validate = FALSE)
  }

  unknown_uo_ids <- setdiff(
    unique(unit_codes$uo_id),
    unique(units$uo_id)
  )

  if (length(unknown_uo_ids) > 0) {
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Unknown uo_id values found: {.val {unknown_uo_ids}}"
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  parent_codes <- stats::na.omit(unit_codes$parent_unit_code)

  unknown_parent_codes <- setdiff(
    unique(parent_codes),
    unique(unit_codes$unit_code)
  )

  if (length(unknown_parent_codes) > 0) {
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Unknown parent_unit_code values found: {.val {unknown_parent_codes}}"
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  self_reference <- !is.na(unit_codes$parent_unit_code) &
    unit_codes$parent_unit_code == unit_codes$unit_code

  if (any(self_reference)) {
    bad_codes <- unit_codes$unit_code[self_reference]

    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Self-referencing parent_unit_code found for unit_code: {.val {bad_codes}}"
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  parent_lookup <- unit_codes |>
    dplyr::select(
      parent_unit_code = "unit_code",
      parent_uo_id = "uo_id",
      parent_is_external = "is_external",
      parent_valid_from = "valid_from",
      parent_valid_to = "valid_to"
    )

  child_parent_check <- unit_codes |>
    dplyr::filter(!is.na(.data$parent_unit_code)) |>
    dplyr::mutate(child_row_id = dplyr::row_number()) |>
    dplyr::left_join(parent_lookup, by = "parent_unit_code")

  bad_parent_uo <- child_parent_check |>
    dplyr::filter(.data$uo_id != .data$parent_uo_id)

  if (nrow(bad_parent_uo) > 0) {
    bad_codes <- unique(bad_parent_uo$unit_code)

    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Child unit codes with different uo_id from parent found: {.val {bad_codes}}"
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_parent_external <- child_parent_check |>
    dplyr::filter(!.data$parent_is_external)

  if (nrow(bad_parent_external) > 0) {
    bad_codes <- unique(bad_parent_external$unit_code)

    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Child unit codes referencing non-external parent codes found: {.val {bad_codes}}"
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  child_parent_validity <- child_parent_check |>
    dplyr::mutate(
      child_valid_to_check = dplyr::coalesce(
        .data$valid_to,
        as.Date("9999-12-31")
      ),
      parent_valid_to_check = dplyr::coalesce(
        .data$parent_valid_to,
        as.Date("9999-12-31")
      ),
      validity_contained = .data$valid_from >= .data$parent_valid_from &
        .data$child_valid_to_check <= .data$parent_valid_to_check
    ) |>
    dplyr::group_by(.data$child_row_id, .data$unit_code) |>
    dplyr::summarise(
      has_containing_parent_window = any(.data$validity_contained),
      .groups = "drop"
    )

  bad_parent_validity <- child_parent_validity |>
    dplyr::filter(!.data$has_containing_parent_window)

  if (nrow(bad_parent_validity) > 0) {
    bad_codes <- unique(bad_parent_validity$unit_code)

    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Child unit codes with validity window outside parent validity window found: {.val {bad_codes}}"
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  missing_parent_for_internal <- !unit_codes$is_external &
    is.na(unit_codes$parent_unit_code)

  if (any(missing_parent_for_internal)) {
    bad_codes <- unit_codes$unit_code[missing_parent_for_internal]

    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Internal unit codes without parent_unit_code found: {.val {bad_codes}}"
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  .validate_no_unit_code_period_overlap(unit_codes)

  invisible(TRUE)
}

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


#' Validate No Overlapping Unit Validity Periods
#'
#' @param units Units registry.
#' @return Invisibly TRUE.
#' @noRd
.validate_no_unit_period_overlap <- function(units) {
  x <- units |>
    dplyr::mutate(
      valid_to_check = dplyr::coalesce(
        .data$valid_to,
        as.Date("9999-12-31")
      )
    ) |>
    dplyr::arrange(.data$uo_id, .data$valid_from, .data$valid_to_check) |>
    dplyr::group_by(.data$uo_id) |>
    dplyr::mutate(
      previous_valid_to = dplyr::lag(.data$valid_to_check),
      overlaps_previous = !is.na(.data$previous_valid_to) &
        .data$valid_from <= .data$previous_valid_to
    ) |>
    dplyr::ungroup()

  overlaps <- x |>
    dplyr::filter(.data$overlaps_previous)

  if (nrow(overlaps) > 0) {
    bad_ids <- sort(unique(overlaps$uo_id))

    cli::cli_abort(
      c(
        "Invalid units registry",
        "x" = "Overlapping validity periods found for uo_id: {.val {bad_ids}}"
      ),
      class = c("xpipe_org_units", "xpipe_org_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}


#' Validate No Overlapping Unit Code Validity Periods
#'
#' @param unit_codes Unit codes registry.
#' @return Invisibly TRUE.
#' @noRd
.validate_no_unit_code_period_overlap <- function(unit_codes) {
  x <- unit_codes |>
    dplyr::mutate(
      valid_to_check = dplyr::coalesce(
        .data$valid_to,
        as.Date("9999-12-31")
      )
    ) |>
    dplyr::arrange(
      .data$unit_code,
      .data$valid_from,
      .data$valid_to_check
    ) |>
    dplyr::group_by(.data$unit_code) |>
    dplyr::mutate(
      previous_valid_to = dplyr::lag(.data$valid_to_check),
      overlaps_previous = !is.na(.data$previous_valid_to) &
        .data$valid_from <= .data$previous_valid_to
    ) |>
    dplyr::ungroup()

  overlaps <- x |>
    dplyr::filter(.data$overlaps_previous)

  if (nrow(overlaps) > 0) {
    bad_codes <- sort(unique(overlaps$unit_code))

    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Overlapping validity periods found for unit_code: {.val {bad_codes}}"
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}
