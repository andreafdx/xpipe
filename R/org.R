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

  if (
    any(is.na(orgs$organization_name) | trimws(orgs$organization_name) == "")
  ) {
    cli::cli_abort(
      c(
        "Invalid organizations registry",
        "x" = "Column {.field organization_name} contains missing or empty values."
      ),
      class = c("xpipe_org_organizations", "xpipe_org_error", "xpipe_error")
    )
  }

  .validate_validity_window(
    x = orgs,
    registry_name = "organizations",
    error_class = "xpipe_org_organizations"
  )

  .validate_no_period_overlap(
    x = orgs,
    key_cols = "organization_uid",
    registry_name = "organizations",
    error_class = "xpipe_org_organizations"
  )

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

  if (
    any(is.na(structs$structure_name) | trimws(structs$structure_name) == "")
  ) {
    cli::cli_abort(
      c(
        "Invalid structures registry",
        "x" = "Column {.field structure_name} contains missing or empty values."
      ),
      class = c("xpipe_org_structures", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_code <- is.na(structs$structure_code) |
    !grepl("^[0-9]{6}$", structs$structure_code)

  if (any(bad_code)) {
    cli::cli_abort(
      c(
        "Invalid structures registry",
        "x" = "Invalid structure_code format. Expected 6 numeric characters."
      ),
      class = c("xpipe_org_structures", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_region <- is.na(structs$region_code) |
    !grepl("^[0-9]{3}$", structs$region_code)

  if (any(bad_region)) {
    cli::cli_abort(
      c(
        "Invalid structures registry",
        "x" = "Invalid region_code format. Expected 3 numeric characters."
      ),
      class = c("xpipe_org_structures", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_asl <- is.na(structs$asl_code) |
    !grepl("^[0-9]{3}$", structs$asl_code)

  if (any(bad_asl)) {
    cli::cli_abort(
      c(
        "Invalid structures registry",
        "x" = "Invalid asl_code format. Expected 3 numeric characters."
      ),
      class = c("xpipe_org_structures", "xpipe_org_error", "xpipe_error")
    )
  }

  .validate_validity_window(
    x = structs,
    registry_name = "structures",
    error_class = "xpipe_org_structures"
  )

  if (is.null(organizations)) {
    organizations <- load_organizations(validate = FALSE)
  }

  .validate_fk(
    child = structs,
    child_col = "organization_uid",
    parent = organizations,
    parent_col = "organization_uid",
    registry_name = "structures",
    error_class = "xpipe_org_structures"
  )
  .validate_child_period_containment(
    child = structs,
    child_parent_col = "organization_uid",
    parent = organizations,
    parent_col = "organization_uid",
    child_key_cols = "structure_code",
    registry_name = "structures",
    parent_registry_name = "organizations",
    error_class = "xpipe_org_structures"
  )

  .validate_no_period_overlap(
    x = structs,
    key_cols = "structure_code",
    registry_name = "structures",
    error_class = "xpipe_org_structures"
  )


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

  bad_code <- is.na(facs$facility_code) |
    !grepl("^[0-9]{8}$", facs$facility_code)

  if (any(bad_code)) {
    cli::cli_abort(
      c(
        "Invalid facilities registry",
        "x" = "Invalid facility_code format. Expected 8 numeric characters."
      ),
      class = c("xpipe_org_facilities", "xpipe_org_error", "xpipe_error")
    )
  }

  if (any(is.na(facs$facility_name) | trimws(facs$facility_name) == "")) {
    cli::cli_abort(
      c(
        "Invalid facilities registry",
        "x" = "Column {.field facility_name} contains missing or empty values."
      ),
      class = c("xpipe_org_facilities", "xpipe_org_error", "xpipe_error")
    )
  }

  .validate_validity_window(
    x = facs,
    registry_name = "facilities",
    error_class = "xpipe_org_facilities"
  )

  if (is.null(structures)) {
    structures <- load_structures(validate = FALSE)
  }

  .validate_fk(
    child = facs,
    child_col = "structure_code",
    parent = structures,
    parent_col = "structure_code",
    registry_name = "facilities",
    error_class = "xpipe_org_facilities"
  )

  .validate_child_period_containment(
    child = facs,
    child_parent_col = "structure_code",
    parent = structures,
    parent_col = "structure_code",
    child_key_cols = "facility_code",
    registry_name = "facilities",
    parent_registry_name = "structures",
    error_class = "xpipe_org_facilities"
  )

  .validate_no_period_overlap(
    x = facs,
    key_cols = "facility_code",
    registry_name = "facilities",
    error_class = "xpipe_org_facilities"
  )


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

  if (
    any(
      is.na(departments$department_uid) |
        trimws(departments$department_uid) == ""
    )
  ) {
    cli::cli_abort(
      c(
        "Invalid departments registry",
        "x" = "Column {.field department_uid} contains missing or empty values."
      ),
      class = c("xpipe_org_departments", "xpipe_org_error", "xpipe_error")
    )
  }

  if (
    any(
      is.na(departments$department_name) |
        trimws(departments$department_name) == ""
    )
  ) {
    cli::cli_abort(
      c(
        "Invalid departments registry",
        "x" = "Column {.field department_name} contains missing or empty values."
      ),
      class = c("xpipe_org_departments", "xpipe_org_error", "xpipe_error")
    )
  }

  .validate_validity_window(
    x = departments,
    registry_name = "departments",
    error_class = "xpipe_org_departments"
  )

  if (is.null(organizations)) {
    organizations <- load_organizations(validate = FALSE)
  }

  .validate_fk(
    child = departments,
    child_col = "organization_uid",
    parent = organizations,
    parent_col = "organization_uid",
    registry_name = "departments",
    error_class = "xpipe_org_departments"
  )

  .validate_child_period_containment(
    child = departments,
    child_parent_col = "organization_uid",
    parent = organizations,
    parent_col = "organization_uid",
    child_key_cols = "department_uid",
    registry_name = "departments",
    parent_registry_name = "organizations",
    error_class = "xpipe_org_departments"
  )

  .validate_no_period_overlap(
    x = departments,
    key_cols = "department_uid",
    registry_name = "departments",
    error_class = "xpipe_org_departments"
  )

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

  if (any(is.na(units$uo_name) | trimws(units$uo_name) == "")) {
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

  .validate_validity_window(
    x = units,
    registry_name = "units",
    error_class = "xpipe_org_units"
  )

  if (is.null(departments)) {
    departments <- load_departments(validate = FALSE)
  }

  .validate_fk(
    child = units,
    child_col = "department_uid",
    parent = departments,
    parent_col = "department_uid",
    registry_name = "units",
    error_class = "xpipe_org_units"
  )

  .validate_child_period_containment(
    child = units,
    child_parent_col = "department_uid",
    parent = departments,
    parent_col = "department_uid",
    child_key_cols = "uo_uid",
    registry_name = "units",
    parent_registry_name = "departments",
    error_class = "xpipe_org_units"
  )

  .validate_no_period_overlap(
    x = units,
    key_cols = "uo_uid",
    registry_name = "units",
    error_class = "xpipe_org_units"
  )

  invisible(TRUE)
}

#' Validate Unit Codes Registry
#' @noRd
.validate_unit_codes <- function(unit_codes, units = NULL, facilities = NULL) {
  checkmate::assert_data_frame(unit_codes)

  required_cols <- c(
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

  bad_facility_code <- is.na(unit_codes$facility_code) |
    !grepl("^[0-9]{8}$", unit_codes$facility_code)

  if (any(bad_facility_code)) {
    bad_values <- unique(unit_codes$facility_code[bad_facility_code])
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Invalid facility_code format found: {.val {bad_values}}",
        "i" = "Expected 8-character numeric facility codes, preserving leading zeroes."
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_code_format <- is.na(unit_codes$unit_code) |
    !grepl("^[0-9]{4}$", unit_codes$unit_code)

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

  if (any(is.na(unit_codes$short_name) | trimws(unit_codes$short_name) == "")) {
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Column {.field short_name} contains missing or empty values."
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  if (any(is.na(unit_codes$is_external))) {
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Column {.field is_external} contains missing or invalid logical values."
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  .validate_validity_window(
    x = unit_codes,
    registry_name = "unit codes",
    error_class = "xpipe_org_unit_codes"
  )

  if (is.null(units)) {
    units <- load_units(validate = FALSE)
  }

  if (is.null(facilities)) {
    facilities <- load_facilities(validate = FALSE)
  }

  .validate_fk(
    child = unit_codes,
    child_col = "uo_uid",
    parent = units,
    parent_col = "uo_uid",
    registry_name = "unit codes",
    error_class = "xpipe_org_unit_codes"
  )

  .validate_fk(
    child = unit_codes,
    child_col = "facility_code",
    parent = facilities,
    parent_col = "facility_code",
    registry_name = "unit codes",
    error_class = "xpipe_org_unit_codes"
  )

  .validate_child_period_containment(
    child = unit_codes,
    child_parent_col = "uo_uid",
    parent = units,
    parent_col = "uo_uid",
    child_key_cols = c("facility_code", "unit_code"),
    registry_name = "unit codes",
    parent_registry_name = "units",
    error_class = "xpipe_org_unit_codes"
  )

  .validate_child_period_containment(
    child = unit_codes,
    child_parent_col = "facility_code",
    parent = facilities,
    parent_col = "facility_code",
    child_key_cols = c("facility_code", "unit_code"),
    registry_name = "unit codes",
    parent_registry_name = "facilities",
    error_class = "xpipe_org_unit_codes"
  )

  internal_rows <- !unit_codes$is_external

  missing_parent <- internal_rows &
    (is.na(unit_codes$parent_unit_code) |
      trimws(unit_codes$parent_unit_code) == "")

  if (any(missing_parent)) {
    bad_codes <- unique(unit_codes$unit_code[missing_parent])
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Internal unit codes require parent_unit_code. Problematic unit_code values: {.val {bad_codes}}"
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  bad_parent_format <- internal_rows &
    !is.na(unit_codes$parent_unit_code) &
    trimws(unit_codes$parent_unit_code) != "" &
    !grepl("^[0-9]{4}$", unit_codes$parent_unit_code)

  if (any(bad_parent_format)) {
    bad_parents <- unique(unit_codes$parent_unit_code[bad_parent_format])
    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Invalid parent_unit_code format found: {.val {bad_parents}}",
        "i" = "Expected 4-character numeric codes, preserving leading zeroes."
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  external_keys <- unit_codes |>
    dplyr::filter(.data$is_external) |>
    dplyr::transmute(
      parent_key = paste0(.data$facility_code, "::", .data$unit_code)
    ) |>
    dplyr::pull(.data$parent_key)

  internal_parent_keys <- unit_codes |>
    dplyr::filter(!.data$is_external) |>
    dplyr::transmute(
      unit_code = .data$unit_code,
      parent_unit_code = .data$parent_unit_code,
      parent_key = paste0(.data$facility_code, "::", .data$parent_unit_code)
    )

  missing_external_parent <- internal_parent_keys |>
    dplyr::filter(!(.data$parent_key %in% external_keys))

  if (nrow(missing_external_parent) > 0) {
    bad_pairs <- paste0(
      missing_external_parent$unit_code,
      " -> ",
      missing_external_parent$parent_unit_code
    )

    cli::cli_abort(
      c(
        "Invalid unit codes registry",
        "x" = "Internal unit codes reference missing or non-external parent_unit_code values: {.val {bad_pairs}}"
      ),
      class = c("xpipe_org_unit_codes", "xpipe_org_error", "xpipe_error")
    )
  }

  .validate_no_period_overlap(
    x = unit_codes,
    key_cols = c(
      "facility_code",
      "unit_code"
    ),
    registry_name = "unit codes",
    error_class = "xpipe_org_unit_codes"
  )

  invisible(TRUE)
}


#' Validate No Period Overlap
#' @noRd
.validate_no_period_overlap <- function(
  x,
  key_cols,
  registry_name,
  error_class
) {
  x_chk <- x |>
    dplyr::mutate(
      valid_to_check = dplyr::coalesce(
        .data$valid_to,
        as.Date("9999-12-31")
      )
    ) |>
    dplyr::arrange(
      dplyr::across(dplyr::all_of(key_cols)),
      .data$valid_from,
      .data$valid_to_check
    ) |>
    dplyr::group_by(
      dplyr::across(dplyr::all_of(key_cols))
    ) |>
    dplyr::mutate(
      previous_valid_to = dplyr::lag(.data$valid_to_check),
      overlaps_previous = !is.na(.data$previous_valid_to) &
        .data$valid_from <= .data$previous_valid_to
    ) |>
    dplyr::ungroup()

  overlaps <- x_chk |>
    dplyr::filter(.data$overlaps_previous)

  if (nrow(overlaps) > 0) {
    cli::cli_abort(
      c(
        paste0("Invalid ", registry_name, " registry"),
        "x" = "Overlapping validity periods detected."
      ),
      class = c(error_class, "xpipe_org_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}


#' Validate Foreign Key Relationship
#' @noRd
.validate_fk <- function(
  child,
  child_col,
  parent,
  parent_col,
  registry_name,
  error_class,
  allow_missing = FALSE
) {
  child_raw <- child[[child_col]]

  missing_child <- is.na(child_raw) | trimws(child_raw) == ""

  if (!allow_missing && any(missing_child)) {
    cli::cli_abort(
      c(
        paste0("Invalid ", registry_name, " registry"),
        "x" = "Column {.field {child_col}} contains missing or empty values."
      ),
      class = c(error_class, "xpipe_org_error", "xpipe_error")
    )
  }

  child_values <- unique(child_raw[!missing_child])
  parent_values <- unique(stats::na.omit(parent[[parent_col]]))

  unknown_values <- setdiff(child_values, parent_values)

  if (length(unknown_values) > 0) {
    cli::cli_abort(
      c(
        paste0("Invalid ", registry_name, " registry"),
        "x" = paste0(
          "Unknown ",
          child_col,
          " values found: {.val {unknown_values}}"
        )
      ),
      class = c(error_class, "xpipe_org_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}


#' Validate Validity Window Columns
#' @noRd
.validate_validity_window <- function(
  x,
  registry_name,
  error_class
) {
  if (any(is.na(x$valid_from))) {
    cli::cli_abort(
      c(
        paste0("Invalid ", registry_name, " registry"),
        "x" = "Column {.field valid_from} contains missing or invalid dates."
      ),
      class = c(error_class, "xpipe_org_error", "xpipe_error")
    )
  }

  bad_valid_to <- !is.na(x$valid_to) &
    x$valid_to < x$valid_from

  if (any(bad_valid_to)) {
    cli::cli_abort(
      c(
        paste0("Invalid ", registry_name, " registry"),
        "x" = "Some {.field valid_to} values are earlier than {.field valid_from}."
      ),
      class = c(error_class, "xpipe_org_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}


#' Validate Child Validity Window Is Contained in Parent Window
#' @noRd
.validate_child_period_containment <- function(
    child,
    child_parent_col,
    parent,
    parent_col,
    child_key_cols,
    registry_name,
    parent_registry_name,
    error_class
) {

  child_valid_to <- dplyr::coalesce(
    child$valid_to,
    as.Date("9999-12-31")
  )

  parent_valid_to <- dplyr::coalesce(
    parent$valid_to,
    as.Date("9999-12-31")
  )

  bad_rows <- logical(nrow(child))

  for (i in seq_len(nrow(child))) {
    parent_value <- child[[child_parent_col]][[i]]

    matches <- which(parent[[parent_col]] == parent_value)

    if (length(matches) == 0) {
      next
    }

    contained <- any(
      child$valid_from[[i]] >= parent$valid_from[matches] &
        child_valid_to[[i]] <= parent_valid_to[matches]
    )

    bad_rows[[i]] <- !contained
  }

  if (any(bad_rows)) {
    bad_keys <- child[bad_rows, child_key_cols, drop = FALSE]

    bad_labels <- apply(
      bad_keys,
      1,
      function(row) {
        paste(
          paste0(names(row), "=", row),
          collapse = ", "
        )
      }
    )

    cli::cli_abort(
      c(
        paste0("Invalid ", registry_name, " registry"),
        "x" = paste0(
          "Some child validity windows are not contained within the matching ",
          parent_registry_name,
          " validity window."
        ),
        "i" = "Problematic keys: {.val {bad_labels}}"
      ),
      class = c(error_class, "xpipe_org_error", "xpipe_error")
    )
  }

  invisible(TRUE)
}
