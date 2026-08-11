# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# org.R
#
# Shared organizational registry loading and validation.
#
# These files are shared XNE resources, not package-owned data and not
# medallion layers. They describe organizational master data used for
# enrichment and analytical reporting.
#
# Public API:  load_organizations(), load_structures(), load_facilities(),
#              load_departments(), load_units(), load_unit_codes(),
#              validate_org_registry()
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Error Class Taxonomy --------------------------------------------------------
#
#   ├── xpipe_org_error                # shared organizational registry errors
#   │   ├── xpipe_org_missing          # registry file missing
#   │   ├── xpipe_org_parse            # CSV parsing failure
#   │   ├── xpipe_org_organizations    # invalid organizations.csv
#   │   ├── xpipe_org_structures       # invalid structures.csv
#   │   ├── xpipe_org_facilities       # invalid facilities.csv
#   │   ├── xpipe_org_departments      # invalid departments.csv
#   │   ├── xpipe_org_units            # invalid units.csv
#   │   └── xpipe_org_unit_codes       # invalid unit_codes.csv

# Public API ------------------------------------------------------------------

#' Load Organizations Registry
#'
#' Loads the shared organizations registry from the active XNE project.
#'
#' Expected path:
#' `<xne_root>/data/shared/org/organizations.csv`
#'
#' @param validate Logical. If TRUE, validate the registry after loading.
#' @return A tibble with organization metadata.
#' @export
load_organizations <- function(validate = TRUE) {
  checkmate::assert_flag(validate)

  cfg <- get_xpipe_config()
  path <- fs::path(cfg$xne$paths$shared, "org", "organizations.csv")

  if (!fs::file_exists(path)) {
    cli::cli_abort(
      c(
        "Organizations registry not found",
        "x" = "Expected file: {.file {path}}"
      ),
      class = c("xpipe_org_missing", "xpipe_org_error", "xpipe_error")
    )
  }

  orgs <- rlang::try_fetch(
    readr::read_csv(
      file = path,
      col_types = readr::cols(
        organization_uid = readr::col_character(),
        organization_name = readr::col_character(),
        valid_from = readr::col_date(),
        valid_to = readr::col_date()
      ),
      na = c("", "NA"),
      show_col_types = FALSE
    ),
    error = function(e) {
      cli::cli_abort(
        c(
          "Failed to read organizations registry",
          "x" = "File {.file {path}} could not be parsed as CSV."
        ),
        parent = e,
        class = c("xpipe_org_parse", "xpipe_org_error", "xpipe_error")
      )
    }
  )

  if (isTRUE(validate)) {
    .validate_organizations(orgs)
  }

  orgs
}

#' Load Structures Registry
#'
#' Loads the shared structures registry from the active XNE project.
#'
#' Expected path:
#' `<xne_root>/data/shared/org/structures.csv`
#'
#' @param validate Logical. If TRUE, validate the registry after loading.
#' @return A tibble with structure metadata.
#' @export
load_structures <- function(validate = TRUE) {
  checkmate::assert_flag(validate)

  cfg <- get_xpipe_config()
  path <- fs::path(cfg$xne$paths$shared, "org", "structures.csv")

  if (!fs::file_exists(path)) {
    cli::cli_abort(
      c(
        "Structures registry not found",
        "x" = "Expected file: {.file {path}}"
      ),
      class = c("xpipe_org_missing", "xpipe_org_error", "xpipe_error")
    )
  }

  structs <- rlang::try_fetch(
    readr::read_csv(
      file = path,
      col_types = readr::cols(
        structure_code = readr::col_character(),
        structure_name = readr::col_character(),
        region_code = readr::col_character(),
        asl_code = readr::col_character(),
        organization_uid = readr::col_character(),
        valid_from = readr::col_date(),
        valid_to = readr::col_date()
      ),
      na = c("", "NA"),
      show_col_types = FALSE
    ),
    error = function(e) {
      cli::cli_abort(
        c(
          "Failed to read structures registry",
          "x" = "File {.file {path}} could not be parsed as CSV."
        ),
        parent = e,
        class = c("xpipe_org_parse", "xpipe_org_error", "xpipe_error")
      )
    }
  )

  if (isTRUE(validate)) {
    .validate_structures(structs)
  }

  structs
}

#' Load Facilities Registry
#'
#' Loads the shared facilities registry from the active XNE project.
#'
#' Expected path:
#' `<xne_root>/data/shared/org/facilities.csv`
#'
#' @param validate Logical. If TRUE, validate the registry after loading.
#' @return A tibble with facility metadata.
#' @export
load_facilities <- function(validate = TRUE) {
  checkmate::assert_flag(validate)

  cfg <- get_xpipe_config()
  path <- fs::path(cfg$xne$paths$shared, "org", "facilities.csv")

  if (!fs::file_exists(path)) {
    cli::cli_abort(
      c(
        "Facilities registry not found",
        "x" = "Expected file: {.file {path}}"
      ),
      class = c("xpipe_org_missing", "xpipe_org_error", "xpipe_error")
    )
  }

  facs <- rlang::try_fetch(
    readr::read_csv(
      file = path,
      col_types = readr::cols(
        facility_code = readr::col_character(),
        facility_name = readr::col_character(),
        structure_code = readr::col_character(),
        valid_from = readr::col_date(),
        valid_to = readr::col_date()
      ),
      na = c("", "NA"),
      show_col_types = FALSE
    ),
    error = function(e) {
      cli::cli_abort(
        c(
          "Failed to read facilities registry",
          "x" = "File {.file {path}} could not be parsed as CSV."
        ),
        parent = e,
        class = c("xpipe_org_parse", "xpipe_org_error", "xpipe_error")
      )
    }
  )

  if (isTRUE(validate)) {
    .validate_facilities(facs)
  }

  facs
}

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
        department_uid = readr::col_character(),
        department_name = readr::col_character(),
        organization_uid = readr::col_character(),
        valid_from = readr::col_date(),
        valid_to = readr::col_date()
      ),
      na = c("", "NA"),
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
#' `<xne_root>/data/shared/org/units.csv`
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
        uo_uid = readr::col_character(),
        uo_name = readr::col_character(),
        uo_type = readr::col_character(),
        department_uid = readr::col_character(),
        valid_from = readr::col_date(),
        valid_to = readr::col_date()
      ),
      na = c("", "NA"),
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
#' `<xne_root>/data/shared/org/unit_codes.csv`
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
        region_code = readr::col_character(),
        structure_code = readr::col_character(),
        facility_code = readr::col_character(),
        unit_code = readr::col_character(),
        short_name = readr::col_character(),
        uo_uid = readr::col_character(),
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
#' - organizations.csv
#' - structures.csv
#' - facilities.csv
#' - departments.csv
#' - units.csv
#' - unit_codes.csv
#'
#' @return Invisibly TRUE.
#' @export
validate_org_registry <- function() {
  orgs <- load_organizations(validate = FALSE)
  .validate_organizations(orgs)

  structs <- load_structures(validate = FALSE)
  .validate_structures(structs, organizations = orgs)

  facs <- load_facilities(validate = FALSE)
  .validate_facilities(facs, structures = structs)

  departments <- load_departments(validate = FALSE)
  .validate_departments(departments, organizations = orgs)

  units <- load_units(validate = FALSE)
  .validate_units(units, departments = departments)

  unit_codes <- load_unit_codes(validate = FALSE)
  .validate_unit_codes(unit_codes, units = units, facilities = facs)

  cli::cli_alert_success("Organizational registry validated.")

  invisible(TRUE)
}

# Internal Helpers ---------------------------------------------------------

#' Validate Organizations Registry
#' @noRd
.validate_organizations <- function(orgs) {
  checkmate::assert_data_frame(orgs)

  required_cols <- c(
    "organization_uid",
    "organization_name",
    "valid_from",
    "valid_to"
  )

  missing_cols <- setdiff(required_cols, names(orgs))
  if (length(missing_cols) > 0) {
    cli::cli_abort(
      c(
        "Invalid organizations registry",
        "x" = "Missing required columns: {.val {missing_cols}}"
      ),
      class = c("xpipe_org_organizations", "xpipe_org_error", "xpipe_error")
    )
  }

  if (nrow(orgs) == 0) {
    cli::cli_abort(
      c(
        "Invalid organizations registry",
        "x" = "Registry is empty."
      ),
      class = c("xpipe_org_organizations", "xpipe_org_error", "xpipe_error")
    )
  }

  if (any(is.na(orgs$organization_uid) | trimws(orgs$organization_uid) == "")) {
    cli::cli_abort(
      c(
        "Invalid organizations registry",
        "x" = "Column {.field organization_uid} contains missing or empty values."
      ),
      class = c("xpipe_org_organizations", "xpipe_org_error", "xpipe_error")
    )
  }

  if (any(is.na(orgs$organization_name) | trimws(orgs$organization_name) == "")) {
    cli::cli_abort(
      c(
        "Invalid organizations registry",
        "x" = "Column {.field organization_name} contains missing or empty values."
      ),
      class = c("xpipe_org_organizations", "xpipe_org_error", "xpipe_error")
    )
  }

  if (any(is.na(orgs$valid_from))) {
    cli::cli_abort(
      c(
        "Invalid organizations registry",
        "x" = "Column {.field valid_from} contains missing or invalid dates."
      ),
      class = c("xpipe_org_organizations", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_valid_to <- !is.na(orgs$valid_to) & orgs$valid_to < orgs$valid_from
  if (any(bad_valid_to)) {
    cli::cli_abort(
      c(
        "Invalid organizations registry",
        "x" = "Some {.field valid_to} values are earlier than {.field valid_from}."
      ),
      class = c("xpipe_org_organizations", "xpipe_org_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}

#' Validate Structures Registry
#' @noRd
.validate_structures <- function(structs, organizations = NULL) {
  checkmate::assert_data_frame(structs)

  required_cols <- c(
    "structure_code",
    "structure_name",
    "region_code",
    "asl_code",
    "organization_uid",
    "valid_from",
    "valid_to"
  )

  missing_cols <- setdiff(required_cols, names(structs))
  if (length(missing_cols) > 0) {
    cli::cli_abort(
      c(
        "Invalid structures registry",
        "x" = "Missing required columns: {.val {missing_cols}}"
      ),
      class = c("xpipe_org_structures", "xpipe_org_error", "xpipe_error")
    )
  }

  if (nrow(structs) == 0) {
    cli::cli_abort(
      c(
        "Invalid structures registry",
        "x" = "Registry is empty."
      ),
      class = c("xpipe_org_structures", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_code <- is.na(structs$structure_code) | !grepl("^[0-9]{6}$", structs$structure_code)
  if (any(bad_code)) {
    cli::cli_abort(
      c(
        "Invalid structures registry",
        "x" = "Invalid structure_code format. Expected 6 numeric characters."
      ),
      class = c("xpipe_org_structures", "xpipe_org_error", "xpipe_error")
    )
  }

  if (is.null(organizations)) {
    organizations <- load_organizations(validate = FALSE)
  }

  unknown_orgs <- setdiff(unique(structs$organization_uid), unique(organizations$organization_uid))
  if (length(unknown_orgs) > 0) {
    cli::cli_abort(
      c(
        "Invalid structures registry",
        "x" = "Unknown organization_uid values found: {.val {unknown_orgs}}"
      ),
      class = c("xpipe_org_structures", "xpipe_org_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}

#' Validate Facilities Registry
#' @noRd
.validate_facilities <- function(facs, structures = NULL) {
  checkmate::assert_data_frame(facs)

  required_cols <- c(
    "facility_code",
    "facility_name",
    "structure_code",
    "valid_from",
    "valid_to"
  )

  missing_cols <- setdiff(required_cols, names(facs))
  if (length(missing_cols) > 0) {
    cli::cli_abort(
      c(
        "Invalid facilities registry",
        "x" = "Missing required columns: {.val {missing_cols}}"
      ),
      class = c("xpipe_org_facilities", "xpipe_org_error", "xpipe_error")
    )
  }

  if (nrow(facs) == 0) {
    cli::cli_abort(
      c(
        "Invalid facilities registry",
        "x" = "Registry is empty."
      ),
      class = c("xpipe_org_facilities", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_code <- is.na(facs$facility_code) | !grepl("^[0-9]{8}$", facs$facility_code)
  if (any(bad_code)) {
    cli::cli_abort(
      c(
        "Invalid facilities registry",
        "x" = "Invalid facility_code format. Expected 8 numeric characters."
      ),
      class = c("xpipe_org_facilities", "xpipe_org_error", "xpipe_error")
    )
  }

  if (is.null(structures)) {
    structures <- load_structures(validate = FALSE)
  }

  unknown_structs <- setdiff(unique(facs$structure_code), unique(structures$structure_code))
  if (length(unknown_structs) > 0) {
    cli::cli_abort(
      c(
        "Invalid facilities registry",
        "x" = "Unknown structure_code values found: {.val {unknown_structs}}"
      ),
      class = c("xpipe_org_facilities", "xpipe_org_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}

#' Validate Departments Registry
#' @noRd
.validate_departments <- function(departments, organizations = NULL) {
  checkmate::assert_data_frame(departments)

  required_cols <- c(
    "department_uid",
    "organization_uid",
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

  if (is.null(organizations)) {
    organizations <- load_organizations(validate = FALSE)
  }

  unknown_org_ids <- setdiff(
    unique(departments$organization_uid),
    unique(organizations$organization_uid)
  )

  if (length(unknown_org_ids) > 0) {
    cli::cli_abort(
      c(
        "Invalid departments registry",
        "x" = "Unknown organization_uid values found: {.val {unknown_org_ids}}"
      ),
      class = c("xpipe_org_departments", "xpipe_org_error", "xpipe_error")
    )
  }

  if (any(is.na(departments$department_uid) | trimws(departments$department_uid) == "")) {
    cli::cli_abort(
      c(
        "Invalid departments registry",
        "x" = "Column {.field department_uid} contains missing or empty values."
      ),
      class = c("xpipe_org_departments", "xpipe_org_error", "xpipe_error")
    )
  }

  .validate_no_department_period_overlap(departments)

  invisible(TRUE)
}

#' Validate Units Registry
#' @noRd
.validate_units <- function(units, departments = NULL) {
  checkmate::assert_data_frame(units)

  required_cols <- c(
    "uo_uid",
    "uo_name",
    "uo_type",
    "department_uid",
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

  if (any(is.na(units$uo_uid) | trimws(units$uo_uid) == "")) {
    cli::cli_abort(
      c(
        "Invalid units registry",
        "x" = "Column {.field uo_uid} contains missing or empty values."
      ),
      class = c("xpipe_org_units", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_type <- is.na(units$uo_type) | !(units$uo_type %in% c("UOC", "UOSD"))

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

  if (is.null(departments)) {
    departments <- load_departments(validate = FALSE)
  }

  unknown_department_ids <- setdiff(
    unique(units$department_uid),
    unique(departments$department_uid)
  )

  if (length(unknown_department_ids) > 0) {
    cli::cli_abort(
      c(
        "Invalid units registry",
        "x" = "Unknown department_uid values found: {.val {unknown_department_ids}}"
      ),
      class = c("xpipe_org_units", "xpipe_org_error", "xpipe_error")
    )
  }

  .validate_no_unit_period_overlap(units)

  invisible(TRUE)
}

#' Validate Unit Codes Registry
#' @noRd
.validate_unit_codes <- function(unit_codes, units = NULL, facilities = NULL) {
  checkmate::assert_data_frame(unit_codes)

  required_cols <- c(
    "region_code",
    "structure_code",
    "facility_code",
    "unit_code",
    "short_name",
    "uo_uid",
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

  if (is.null(units)) {
    units <- load_units(validate = FALSE)
  }

  unknown_uo_ids <- setdiff(
    unique(unit_codes$uo_uid),
    unique(units$uo_uid)
  )

  if (length(unknown_uo_ids) > 0) {
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Unknown uo_uid values found: {.val {unknown_uo_ids}}"
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  .validate_no_unit_code_period_overlap(unit_codes)

  invisible(TRUE)
}

.validate_no_department_period_overlap <- function(departments) {
  x <- departments |>
    dplyr::mutate(
      valid_to_check = dplyr::coalesce(.data$valid_to, as.Date("9999-12-31"))
    ) |>
    dplyr::arrange(.data$department_uid, .data$valid_from, .data$valid_to_check) |>
    dplyr::group_by(.data$department_uid) |>
    dplyr::mutate(
      previous_valid_to = dplyr::lag(.data$valid_to_check),
      overlaps_previous = !is.na(.data$previous_valid_to) &
        .data$valid_from <= .data$previous_valid_to
    ) |>
    dplyr::ungroup()

  overlaps <- x |> dplyr::filter(.data$overlaps_previous)

  if (nrow(overlaps) > 0) {
    bad_ids <- sort(unique(overlaps$department_uid))
    cli::cli_abort(
      c(
        "Invalid departments registry",
        "x" = "Overlapping validity periods found for department_uid: {.val {bad_ids}}"
      ),
      class = c("xpipe_org_departments", "xpipe_org_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}

.validate_no_unit_period_overlap <- function(units) {
  x <- units |>
    dplyr::mutate(
      valid_to_check = dplyr::coalesce(.data$valid_to, as.Date("9999-12-31"))
    ) |>
    dplyr::arrange(.data$uo_uid, .data$valid_from, .data$valid_to_check) |>
    dplyr::group_by(.data$uo_uid) |>
    dplyr::mutate(
      previous_valid_to = dplyr::lag(.data$valid_to_check),
      overlaps_previous = !is.na(.data$previous_valid_to) &
        .data$valid_from <= .data$previous_valid_to
    ) |>
    dplyr::ungroup()

  overlaps <- x |> dplyr::filter(.data$overlaps_previous)

  if (nrow(overlaps) > 0) {
    bad_ids <- sort(unique(overlaps$uo_uid))
    cli::cli_abort(
      c(
        "Invalid units registry",
        "x" = "Overlapping validity periods found for uo_uid: {.val {bad_ids}}"
      ),
      class = c("xpipe_org_units", "xpipe_org_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}

.validate_no_unit_code_period_overlap <- function(unit_codes) {
  x <- unit_codes |>
    dplyr::mutate(
      valid_to_check = dplyr::coalesce(.data$valid_to, as.Date("9999-12-31"))
    ) |>
    dplyr::arrange(
      .data$region_code,
      .data$structure_code,
      .data$facility_code,
      .data$unit_code,
      .data$valid_from,
      .data$valid_to_check
    ) |>
    dplyr::group_by(
      .data$region_code,
      .data$structure_code,
      .data$facility_code,
      .data$unit_code
    ) |>
    dplyr::mutate(
      previous_valid_to = dplyr::lag(.data$valid_to_check),
      overlaps_previous = !is.na(.data$previous_valid_to) &
        .data$valid_from <= .data$previous_valid_to
    ) |>
    dplyr::ungroup()

  overlaps <- x |> dplyr::filter(.data$overlaps_previous)

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
